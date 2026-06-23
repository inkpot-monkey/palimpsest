//! claude-relay — relay persistent `claude` CLI sessions to/from Matrix.
//!
//! See `docs/adr/0025-claude-relay-matrix-interface.md`.
//!
//! Slice 01: log in as a bot account, sync, act ONLY on a hard-allowlisted sender.
//! Slice 02 (this): inject the allowlisted sender's text into a `claude` tmux
//! session via `send-keys`, provision the `Stop` hook into `~/.claude/settings.json`,
//! receive the hook on a localhost endpoint, and post the assistant turn (with
//! one-line tool summaries) read from the session transcript back to the room.

use anyhow::{Context, Result};
use matrix_sdk::{
    config::SyncSettings,
    ruma::events::{
        poll::unstable_response::OriginalSyncUnstablePollResponseEvent,
        room::{
            member::StrippedRoomMemberEvent,
            message::{MessageType, OriginalSyncRoomMessageEvent, RoomMessageEventContent},
        },
    },
    ruma::{OwnedRoomId, OwnedUserId, UserId},
    Client, Room,
};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    process::Command,
    sync::Mutex,
};

/// Relay configuration from the environment.
struct Config {
    homeserver: String,
    user: String,
    password: String,
    allowed_sender: OwnedUserId,
    /// tmux session name the relay drives.
    session: String,
    /// Command tmux runs in that session (real `claude`, or a test stub).
    claude_cmd: String,
    /// Localhost port the provisioned hook POSTs to.
    hook_port: u16,
    /// HOME of the relay user (`~/.claude` lives here).
    home: String,
}

impl Config {
    fn from_env() -> Result<Self> {
        let allowed = std::env::var("RELAY_ALLOWED_SENDER").context("RELAY_ALLOWED_SENDER")?;
        Ok(Self {
            homeserver: std::env::var("RELAY_HOMESERVER").context("RELAY_HOMESERVER")?,
            user: std::env::var("RELAY_USER").context("RELAY_USER")?,
            password: std::env::var("RELAY_PASSWORD").context("RELAY_PASSWORD")?,
            allowed_sender: UserId::parse(&allowed).context("RELAY_ALLOWED_SENDER is not a MXID")?,
            session: std::env::var("RELAY_SESSION").unwrap_or_else(|_| "claude".into()),
            claude_cmd: std::env::var("RELAY_CLAUDE_CMD").unwrap_or_else(|_| "claude".into()),
            hook_port: std::env::var("RELAY_HOOK_PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(8787),
            home: std::env::var("HOME").context("HOME")?,
        })
    }
}

/// Shared relay state.
struct App {
    client: Client,
    allowed: OwnedUserId,
    session: String,
    /// The single session's bound room (slice 02 is one session; slice 04 makes
    /// this a session↔room map).
    room: Mutex<Option<OwnedRoomId>>,
    /// transcript_path -> number of JSONL lines already posted, so a `Stop` only
    /// posts the turn(s) appended since the last one.
    processed: Mutex<HashMap<String, usize>>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "claude_relay=info,matrix_sdk=warn".into()),
        )
        .init();

    let config = Config::from_env()?;

    // Provision the claude Stop hook and ensure the tmux session, BEFORE logging in
    // so a session that comes up fast already has somewhere to send keys.
    provision_hook(&config).await.context("provisioning hook")?;
    ensure_session(&config)
        .await
        .context("starting tmux session")?;

    let client = Client::builder()
        .homeserver_url(&config.homeserver)
        .build()
        .await
        .context("building matrix client")?;
    client
        .matrix_auth()
        .login_username(&config.user, &config.password)
        .initial_device_display_name("claude-relay")
        .await
        .context("login failed")?;
    tracing::info!(user = %config.user, allowed = %config.allowed_sender, "logged in");

    let app = Arc::new(App {
        client: client.clone(),
        allowed: config.allowed_sender.clone(),
        session: config.session.clone(),
        room: Mutex::new(None),
        processed: Mutex::new(HashMap::new()),
    });

    // Receive `Stop` hooks on localhost and post the new transcript turn(s).
    tokio::spawn(hook_server(app.clone(), config.hook_port));

    // Consume backlog without handlers, then join pending invites.
    let response = client.sync_once(SyncSettings::default()).await?;
    for room in client.invited_rooms() {
        let _ = room.join().await;
    }

    client.add_event_handler(
        |ev: StrippedRoomMemberEvent, room: Room, client: Client| async move {
            if client.user_id().is_some_and(|me| ev.state_key == me) {
                if let Err(e) = room.join().await {
                    tracing::warn!(error = ?e, "join on invite failed");
                }
            }
        },
    );

    let handler_app = app.clone();
    client.add_event_handler(
        move |ev: OriginalSyncRoomMessageEvent, room: Room, client: Client| {
            let app = handler_app.clone();
            async move {
                if client.user_id().is_some_and(|me| me == ev.sender) {
                    return;
                }
                if ev.sender != app.allowed {
                    tracing::info!(sender = %ev.sender, "ignoring non-allowlisted sender");
                    return;
                }
                let MessageType::Text(text) = ev.content.msgtype else {
                    return;
                };
                // Bind the single session to the first room we hear from.
                {
                    let mut bound = app.room.lock().await;
                    if bound.is_none() {
                        *bound = Some(room.room_id().to_owned());
                        tracing::info!(room = %room.room_id(), "bound session to room");
                    }
                }
                inject(&app.session, &text.body).await;
            }
        },
    );

    // A vote on a grant/choice poll types the chosen number into the session.
    let poll_app = app.clone();
    client.add_event_handler(
        move |ev: OriginalSyncUnstablePollResponseEvent, _room: Room, client: Client| {
            let app = poll_app.clone();
            async move {
                if client.user_id().is_some_and(|me| me == ev.sender) {
                    return;
                }
                if ev.sender != app.allowed {
                    return;
                }
                if let Some(answer) = ev.content.poll_response.answers.first() {
                    tracing::info!(answer = %answer, "poll vote -> injecting choice");
                    inject(&app.session, answer).await;
                }
            }
        },
    );

    tracing::info!("entering sync loop");
    client
        .sync(SyncSettings::default().token(response.next_batch))
        .await?;
    Ok(())
}

/// Write `~/.claude/settings.json` (a `Stop` hook) and the hook script that POSTs
/// to the relay. The hook stays dumb: it forwards the hook JSON verbatim.
async fn provision_hook(config: &Config) -> Result<()> {
    let dir = format!("{}/.claude", config.home);
    tokio::fs::create_dir_all(&dir).await?;

    let hook_script = format!("{dir}/relay-hook.sh");
    let script = format!(
        "#!/bin/sh\nexec curl -s -X POST \"http://127.0.0.1:{}/hook\" \
         -H 'content-type: application/json' --data-binary @-\n",
        config.hook_port
    );
    tokio::fs::write(&hook_script, script).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = tokio::fs::metadata(&hook_script).await?.permissions();
        perms.set_mode(0o755);
        tokio::fs::set_permissions(&hook_script, perms).await?;
    }

    let hook_entry = json!([ { "hooks": [ { "type": "command", "command": hook_script } ] } ]);
    let settings = json!({
        "hooks": { "Stop": hook_entry, "Notification": hook_entry }
    });
    tokio::fs::write(
        format!("{dir}/settings.json"),
        serde_json::to_vec_pretty(&settings)?,
    )
    .await?;
    tracing::info!("provisioned ~/.claude/settings.json + hook");
    Ok(())
}

/// Ensure a detached tmux session running the claude command exists.
async fn ensure_session(config: &Config) -> Result<()> {
    // Reset any stale session from a prior run, then create fresh.
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", &config.session])
        .status()
        .await;
    let status = Command::new("tmux")
        .args(["new-session", "-d", "-s", &config.session, &config.claude_cmd])
        .status()
        .await
        .context("tmux new-session")?;
    anyhow::ensure!(status.success(), "tmux new-session failed");
    tracing::info!(session = %config.session, "tmux session started");
    Ok(())
}

/// Type a line into the session, followed by Enter.
async fn inject(session: &str, body: &str) {
    match Command::new("tmux")
        .args(["send-keys", "-t", session, "--", body, "Enter"])
        .status()
        .await
    {
        Ok(s) if s.success() => tracing::info!("injected message into session"),
        Ok(s) => tracing::warn!(?s, "tmux send-keys non-zero"),
        Err(e) => tracing::warn!(error = ?e, "tmux send-keys failed"),
    }
}

/// Minimal localhost HTTP server: accept a single POST per connection, hand the
/// JSON body to `on_stop`, reply 200.
async fn hook_server(app: Arc<App>, port: u16) {
    let listener = match TcpListener::bind(("127.0.0.1", port)).await {
        Ok(l) => l,
        Err(e) => {
            tracing::error!(error = ?e, port, "hook server bind failed");
            return;
        }
    };
    tracing::info!(port, "hook server listening");
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
        let app = app.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_conn(app, stream).await {
                tracing::warn!(error = ?e, "hook connection error");
            }
        });
    }
}

async fn handle_conn(app: Arc<App>, mut stream: tokio::net::TcpStream) -> Result<()> {
    let body = read_http_body(&mut stream).await?;
    stream
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        .await?;
    if let Ok(json) = serde_json::from_slice::<Value>(&body) {
        on_hook(app, json).await;
    }
    Ok(())
}

/// Dispatch a claude hook by event name: `Stop` posts the transcript turn;
/// `Notification(permission_prompt)` posts a grant poll.
async fn on_hook(app: Arc<App>, hook: Value) {
    match hook.get("hook_event_name").and_then(Value::as_str) {
        Some("Stop") => on_stop(app, hook).await,
        Some("Notification") => {
            if hook.get("notification_type").and_then(Value::as_str) == Some("permission_prompt") {
                on_permission(app, hook).await;
            }
        }
        other => tracing::debug!(?other, "ignoring hook event"),
    }
}

/// Post an MSC3381 poll asking the operator to grant/deny. Answer ids are the
/// literal keystrokes (`1`/`2`/`3`) typed back into the session on a vote.
async fn on_permission(app: Arc<App>, hook: Value) {
    let question = hook
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("Permission requested")
        .to_string();
    let Some(room_id) = app.room.lock().await.clone() else {
        tracing::warn!("permission prompt but no bound room");
        return;
    };
    let Some(room) = app.client.get_room(&room_id) else {
        return;
    };
    let content = json!({
        "org.matrix.msc1767.text":
            format!("{question}\n1) Yes   2) Yes, don't ask again   3) No"),
        "org.matrix.msc3381.poll.start": {
            "kind": "org.matrix.msc3381.poll.undisclosed",
            "max_selections": 1,
            "question": { "org.matrix.msc1767.text": question },
            "answers": [
                { "id": "1", "org.matrix.msc1767.text": "Yes" },
                { "id": "2", "org.matrix.msc1767.text": "Yes, don't ask again" },
                { "id": "3", "org.matrix.msc1767.text": "No" }
            ]
        }
    });
    match room.send_raw("org.matrix.msc3381.poll.start", content).await {
        Ok(_) => tracing::info!("posted permission poll"),
        Err(e) => tracing::warn!(error = ?e, "failed to post poll"),
    }
}

/// Read an HTTP request and return the body, honouring Content-Length.
async fn read_http_body(stream: &mut tokio::net::TcpStream) -> Result<Vec<u8>> {
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 4096];
    // Read until headers complete.
    let header_end = loop {
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            anyhow::bail!("connection closed before headers");
        }
        buf.extend_from_slice(&tmp[..n]);
        if let Some(pos) = find_subslice(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
    };
    let headers = String::from_utf8_lossy(&buf[..header_end]).to_lowercase();
    let content_length = headers
        .lines()
        .find_map(|l| l.strip_prefix("content-length:"))
        .and_then(|v| v.trim().parse::<usize>().ok())
        .unwrap_or(0);
    while buf.len() < header_end + content_length {
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
    }
    Ok(buf[header_end..].to_vec())
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// Handle a `Stop` hook: read the transcript, render the turn(s) appended since
/// last time, and post them to the bound room.
async fn on_stop(app: Arc<App>, hook: Value) {
    let Some(path) = hook.get("transcript_path").and_then(Value::as_str) else {
        tracing::warn!("hook missing transcript_path");
        return;
    };
    let Ok(contents) = tokio::fs::read_to_string(path).await else {
        tracing::warn!(path, "could not read transcript");
        return;
    };
    let lines: Vec<&str> = contents.lines().collect();

    let start = {
        let mut processed = app.processed.lock().await;
        let seen = processed.entry(path.to_string()).or_insert(0);
        let start = *seen;
        *seen = lines.len();
        start
    };

    let rendered = render_turn(&lines[start.min(lines.len())..]);
    if rendered.trim().is_empty() {
        return;
    }

    let room_id = app.room.lock().await.clone();
    let Some(room_id) = room_id else {
        tracing::warn!("Stop hook but no bound room yet");
        return;
    };
    if let Some(room) = app.client.get_room(&room_id) {
        if let Err(e) = room.send(RoomMessageEventContent::text_plain(rendered)).await {
            tracing::warn!(error = ?e, "failed to post assistant turn");
        }
    }
}

/// Render assistant content from new transcript lines: text verbatim, tool calls
/// as one-line summaries.
fn render_turn(lines: &[&str]) -> String {
    let mut out: Vec<String> = Vec::new();
    for line in lines {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if v.get("type").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let content = v
            .pointer("/message/content")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for item in content {
            match item.get("type").and_then(Value::as_str) {
                Some("text") => {
                    if let Some(t) = item.get("text").and_then(Value::as_str) {
                        out.push(t.to_string());
                    }
                }
                Some("tool_use") => {
                    let name = item.get("name").and_then(Value::as_str).unwrap_or("tool");
                    out.push(format!("⚙ {name}"));
                }
                _ => {}
            }
        }
    }
    out.join("\n")
}
