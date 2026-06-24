//! claude-relay — relay persistent `claude` CLI sessions to/from Matrix.
//!
//! See `docs/adr/0025-claude-relay-matrix-interface.md`.
//!
//! Slice 01: allowlist-gated bot. Slice 02: send-keys injection + transcript-driven
//! replies via a Stop hook. Slice 03: MSC3381 polls for permission/choice grants.
//! Slice 04 (this): a CONTROL room drives `new <cwd>` / `list` / `kill <name>`; each
//! session gets its own non-federated room; messages/hooks/poll-votes route per
//! session; a concurrency cap bounds it; the session map is persisted.

use anyhow::{ensure, Context, Result};
use matrix_sdk::{
    config::SyncSettings,
    ruma::{
        api::client::room::create_room::v3::{CreationContent, Request as CreateRoomRequest},
        assign,
        events::{
            poll::unstable_response::OriginalSyncUnstablePollResponseEvent,
            room::{
                member::StrippedRoomMemberEvent,
                message::{MessageType, OriginalSyncRoomMessageEvent, RoomMessageEventContent},
            },
        },
        serde::Raw,
        OwnedRoomId, OwnedUserId, UserId,
    },
    Client, Room,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    process::Command,
    sync::Mutex,
};

struct Config {
    homeserver: String,
    user: String,
    password: String,
    allowed_sender: OwnedUserId,
    claude_cmd: String,
    hook_port: u16,
    home: String,
    cap: usize,
}

impl Config {
    fn from_env() -> Result<Self> {
        let allowed = std::env::var("RELAY_ALLOWED_SENDER").context("RELAY_ALLOWED_SENDER")?;
        Ok(Self {
            homeserver: std::env::var("RELAY_HOMESERVER").context("RELAY_HOMESERVER")?,
            user: std::env::var("RELAY_USER").context("RELAY_USER")?,
            password: std::env::var("RELAY_PASSWORD").context("RELAY_PASSWORD")?,
            allowed_sender: UserId::parse(&allowed).context("RELAY_ALLOWED_SENDER is not a MXID")?,
            claude_cmd: std::env::var("RELAY_CLAUDE_CMD").unwrap_or_else(|_| "claude".into()),
            hook_port: std::env::var("RELAY_HOOK_PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(8787),
            home: std::env::var("HOME").context("HOME")?,
            cap: std::env::var("RELAY_MAX_SESSIONS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(2),
        })
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct Session {
    room: OwnedRoomId,
    cwd: String,
    /// claude's own session id, learned from hooks; lets us `claude --resume`.
    #[serde(default)]
    claude_session_id: Option<String>,
    /// Transient: set during reconciliation when the tmux session is gone, so a
    /// poll vote in this room resumes rather than injects. Never persisted.
    #[serde(default, skip)]
    needs_resume: bool,
}

/// Persisted relay state (for slice-05 reconciliation).
#[derive(Default, Serialize, Deserialize)]
struct PersistState {
    control_room: Option<OwnedRoomId>,
    sessions: HashMap<String, Session>,
    counter: u32,
}

struct App {
    client: Client,
    allowed: OwnedUserId,
    claude_cmd: String,
    cap: usize,
    state_file: String,
    control_room: Mutex<Option<OwnedRoomId>>,
    /// tmux session name -> session.
    sessions: Mutex<HashMap<String, Session>>,
    counter: Mutex<u32>,
    /// transcript_path -> JSONL lines already posted.
    processed: Mutex<HashMap<String, usize>>,
}

impl App {
    /// The room hosting a given tmux session, if any.
    async fn session_room(&self, tmux: &str) -> Option<OwnedRoomId> {
        self.sessions.lock().await.get(tmux).map(|s| s.room.clone())
    }
    /// The tmux session a given room hosts, if any.
    async fn session_for_room(&self, room: &OwnedRoomId) -> Option<String> {
        self.sessions
            .lock()
            .await
            .iter()
            .find(|(_, s)| &s.room == room)
            .map(|(name, _)| name.clone())
    }
    async fn snapshot(&self) -> PersistState {
        PersistState {
            control_room: self.control_room.lock().await.clone(),
            sessions: self.sessions.lock().await.clone(),
            counter: *self.counter.lock().await,
        }
    }
}

async fn save_state(app: &Arc<App>) {
    let state = app.snapshot().await;
    if let Ok(bytes) = serde_json::to_vec_pretty(&state) {
        if let Err(e) = tokio::fs::write(&app.state_file, bytes).await {
            tracing::warn!(error = ?e, "failed to persist state");
        }
    }
}

async fn load_state(app: &Arc<App>) {
    let Ok(bytes) = tokio::fs::read(&app.state_file).await else {
        return;
    };
    match serde_json::from_slice::<PersistState>(&bytes) {
        Ok(state) => {
            *app.control_room.lock().await = state.control_room;
            *app.sessions.lock().await = state.sessions;
            *app.counter.lock().await = state.counter;
            tracing::info!("loaded persisted state");
        }
        Err(e) => tracing::warn!(error = ?e, "could not parse state file"),
    }
}

/// On startup, check each persisted session's tmux; for dead ones (e.g. after a
/// reboot) mark needs_resume and post a one-tap resume poll in its room.
async fn reconcile(app: &Arc<App>) {
    let names: Vec<String> = app.sessions.lock().await.keys().cloned().collect();
    for name in names {
        let alive = Command::new("tmux")
            .args(["has-session", "-t", &name])
            .status()
            .await
            .map(|s| s.success())
            .unwrap_or(false);
        if alive {
            continue;
        }
        let room_id = {
            let mut sessions = app.sessions.lock().await;
            sessions.get_mut(&name).map(|s| {
                s.needs_resume = true;
                s.room.clone()
            })
        };
        if let Some(room) = room_id.and_then(|r| app.client.get_room(&r)) {
            let _ = room
                .send_raw("org.matrix.msc3381.poll.start", resume_poll())
                .await;
            tracing::info!(session = %name, "dead on startup; posted resume poll");
        }
    }
}

fn resume_poll() -> Value {
    json!({
        "org.matrix.msc1767.text": "Session ended (host restarted). Vote to resume.",
        "org.matrix.msc3381.poll.start": {
            "kind": "org.matrix.msc3381.poll.undisclosed",
            "max_selections": 1,
            "question": { "org.matrix.msc1767.text": "Session ended — resume?" },
            "answers": [ { "id": "resume", "org.matrix.msc1767.text": "Resume" } ]
        }
    })
}

/// Relaunch a dead session's tmux, resuming claude's prior context if known.
async fn resume_session(app: &Arc<App>, name: &str) {
    let Some(info) = app.sessions.lock().await.get(name).cloned() else {
        return;
    };
    let cmd = match &info.claude_session_id {
        Some(sid) => format!("{} --resume {}", app.claude_cmd, sid),
        None => app.claude_cmd.clone(),
    };
    let ok = Command::new("tmux")
        .args(["new-session", "-d", "-s", name, "-c", &info.cwd, &cmd])
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        tracing::warn!(session = name, "resume tmux new-session failed");
        return;
    }
    if let Some(s) = app.sessions.lock().await.get_mut(name) {
        s.needs_resume = false;
    }
    save_state(app).await;
    if let Some(room) = app.client.get_room(&info.room) {
        let _ = room
            .send(RoomMessageEventContent::text_plain(format!("resumed {name}")))
            .await;
    }
    tracing::info!(session = name, "resumed");
}

/// Record claude's session id for the tmux session a hook came from.
async fn record_session_id(app: &Arc<App>, hook: &Value) {
    let (Some(tmux), Some(sid)) = (
        hook.get("tmux_session").and_then(Value::as_str),
        hook.get("session_id").and_then(Value::as_str),
    ) else {
        return;
    };
    let changed = {
        let mut sessions = app.sessions.lock().await;
        match sessions.get_mut(tmux) {
            Some(s) if s.claude_session_id.as_deref() != Some(sid) => {
                s.claude_session_id = Some(sid.to_string());
                true
            }
            _ => false,
        }
    };
    if changed {
        save_state(app).await;
    }
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
    provision_hook(&config).await.context("provisioning hook")?;

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
        claude_cmd: config.claude_cmd.clone(),
        cap: config.cap,
        state_file: format!("{}/state.json", config.home),
        control_room: Mutex::new(None),
        sessions: Mutex::new(HashMap::new()),
        counter: Mutex::new(0),
        processed: Mutex::new(HashMap::new()),
    });

    tokio::spawn(hook_server(app.clone(), config.hook_port));

    let response = client.sync_once(SyncSettings::default()).await?;
    for room in client.invited_rooms() {
        let _ = room.join().await;
    }

    // Restore prior control room + sessions across restarts.
    load_state(&app).await;

    // Stand up the control room, or reuse the persisted one.
    if app.control_room.lock().await.is_none() {
        let control = create_room(&app, "claude control")
            .await
            .context("creating control room")?;
        *app.control_room.lock().await = Some(control.room_id().to_owned());
        save_state(&app).await;
        tracing::info!(room = %control.room_id(), "control room created");
    } else {
        tracing::info!("reusing persisted control room");
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

    let msg_app = app.clone();
    client.add_event_handler(
        move |ev: OriginalSyncRoomMessageEvent, room: Room, client: Client| {
            let app = msg_app.clone();
            async move {
                if client.user_id().is_some_and(|me| me == ev.sender) || ev.sender != app.allowed {
                    return;
                }
                let MessageType::Text(text) = ev.content.msgtype else {
                    return;
                };
                let body = text.body.trim().to_string();
                let rid = room.room_id().to_owned();
                if app.control_room.lock().await.as_ref() == Some(&rid) {
                    handle_command(&app, &body).await;
                } else if let Some(tmux) = app.session_for_room(&rid).await {
                    inject(&tmux, &body).await;
                }
            }
        },
    );

    // A poll vote types the chosen number into that room's session.
    let poll_app = app.clone();
    client.add_event_handler(
        move |ev: OriginalSyncUnstablePollResponseEvent, room: Room, client: Client| {
            let app = poll_app.clone();
            async move {
                if client.user_id().is_some_and(|me| me == ev.sender) || ev.sender != app.allowed {
                    return;
                }
                let rid = room.room_id().to_owned();
                let Some(tmux) = app.session_for_room(&rid).await else {
                    return;
                };
                let needs_resume = app
                    .sessions
                    .lock()
                    .await
                    .get(&tmux)
                    .is_some_and(|s| s.needs_resume);
                if needs_resume {
                    resume_session(&app, &tmux).await;
                } else if let Some(answer) = ev.content.poll_response.answers.first() {
                    tracing::info!(answer = %answer, "poll vote -> injecting choice");
                    inject(&tmux, answer).await;
                }
            }
        },
    );

    // Offer resume for any persisted session whose tmux didn't survive.
    reconcile(&app).await;

    tracing::info!("entering sync loop");
    client
        .sync(SyncSettings::default().token(response.next_batch))
        .await?;
    Ok(())
}

// ---- control-room commands -------------------------------------------------

async fn handle_command(app: &Arc<App>, body: &str) {
    let mut parts = body.splitn(2, char::is_whitespace);
    let cmd = parts.next().unwrap_or("");
    let arg = parts.next().unwrap_or("").trim();
    match cmd {
        "new" => {
            let cwd = if arg.is_empty() { "." } else { arg };
            if app.sessions.lock().await.len() >= app.cap {
                reply_control(app, &format!("session limit reached ({} max)", app.cap)).await;
                return;
            }
            match create_session(app, cwd).await {
                Ok(name) => reply_control(app, &format!("started {name} in {cwd}")).await,
                Err(e) => reply_control(app, &format!("failed to start session: {e}")).await,
            }
        }
        "list" => {
            let sessions = app.sessions.lock().await;
            let msg = if sessions.is_empty() {
                "no sessions".to_string()
            } else {
                let mut lines: Vec<String> =
                    sessions.iter().map(|(t, s)| format!("{t} — {}", s.cwd)).collect();
                lines.sort();
                lines.join("\n")
            };
            drop(sessions);
            reply_control(app, &msg).await;
        }
        "kill" => {
            if arg.is_empty() {
                reply_control(app, "usage: kill <name>").await;
            } else {
                kill_session(app, arg).await;
            }
        }
        _ => reply_control(app, "commands: new <cwd> | list | kill <name>").await,
    }
}

async fn create_session(app: &Arc<App>, cwd: &str) -> Result<String> {
    let n = {
        let mut c = app.counter.lock().await;
        *c += 1;
        *c
    };
    let name = format!("claude-{n}");
    let status = Command::new("tmux")
        .args(["new-session", "-d", "-s", &name, "-c", cwd, &app.claude_cmd])
        .status()
        .await
        .context("tmux new-session")?;
    ensure!(status.success(), "tmux new-session failed");

    let room = create_room(app, &format!("claude: {cwd}")).await?;
    let room_id = room.room_id().to_owned();
    app.sessions.lock().await.insert(
        name.clone(),
        Session {
            room: room_id,
            cwd: cwd.to_string(),
            claude_session_id: None,
            needs_resume: false,
        },
    );
    save_state(app).await;
    tracing::info!(session = %name, cwd, "session created");
    Ok(name)
}

async fn kill_session(app: &Arc<App>, name: &str) {
    let info = app.sessions.lock().await.remove(name);
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", name])
        .status()
        .await;
    match info {
        Some(info) => {
            if let Some(room) = app.client.get_room(&info.room) {
                let _ = room.leave().await;
            }
            save_state(app).await;
            reply_control(app, &format!("killed {name}")).await;
        }
        None => reply_control(app, &format!("no such session: {name}")).await,
    }
}

/// Create a non-federated room inviting the operator (ADR-0025: rooms never
/// federate, which replaces E2E given the co-located homeserver).
async fn create_room(app: &Arc<App>, name: &str) -> Result<Room> {
    let mut creation = CreationContent::new();
    creation.federate = false;
    let request = assign!(CreateRoomRequest::new(), {
        name: Some(name.to_string()),
        invite: vec![app.allowed.clone()],
        creation_content: Some(Raw::new(&creation)?),
    });
    app.client.create_room(request).await.context("create_room")
}

async fn reply_control(app: &Arc<App>, msg: &str) {
    let Some(room_id) = app.control_room.lock().await.clone() else {
        return;
    };
    if let Some(room) = app.client.get_room(&room_id) {
        let _ = room.send(RoomMessageEventContent::text_plain(msg)).await;
    }
}

// ---- tmux ------------------------------------------------------------------

async fn inject(session: &str, body: &str) {
    match Command::new("tmux")
        .args(["send-keys", "-t", session, "--", body, "Enter"])
        .status()
        .await
    {
        Ok(s) if s.success() => tracing::info!(session, "injected into session"),
        Ok(s) => tracing::warn!(session, ?s, "tmux send-keys non-zero"),
        Err(e) => tracing::warn!(session, error = ?e, "tmux send-keys failed"),
    }
}

// ---- hook provisioning + server --------------------------------------------

/// Write `~/.claude/settings.json` (Stop + Notification hooks) and the hook script.
/// The script tags each POST with its tmux session so the relay can route it.
async fn provision_hook(config: &Config) -> Result<()> {
    let dir = format!("{}/.claude", config.home);
    tokio::fs::create_dir_all(&dir).await?;

    let hook_script = format!("{dir}/relay-hook.sh");
    let script = format!(
        "#!/bin/sh\n\
         sess=$(tmux display-message -p '#S' 2>/dev/null || echo '')\n\
         jq -c --arg s \"$sess\" '. + {{tmux_session:$s}}' \
         | curl -s -X POST \"http://127.0.0.1:{}/hook\" \
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

    let entry = json!([ { "hooks": [ { "type": "command", "command": hook_script } ] } ]);
    let settings = json!({ "hooks": { "Stop": entry, "Notification": entry } });
    tokio::fs::write(
        format!("{dir}/settings.json"),
        serde_json::to_vec_pretty(&settings)?,
    )
    .await?;
    tracing::info!("provisioned ~/.claude/settings.json + hook");
    Ok(())
}

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
            if let Err(e) = handle_conn(&app, stream).await {
                tracing::warn!(error = ?e, "hook connection error");
            }
        });
    }
}

async fn handle_conn(app: &Arc<App>, mut stream: tokio::net::TcpStream) -> Result<()> {
    let body = read_http_body(&mut stream).await?;
    stream
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        .await?;
    if let Ok(json) = serde_json::from_slice::<Value>(&body) {
        on_hook(app, json).await;
    }
    Ok(())
}

async fn read_http_body(stream: &mut tokio::net::TcpStream) -> Result<Vec<u8>> {
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 4096];
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

// ---- hook handlers ---------------------------------------------------------

async fn on_hook(app: &Arc<App>, hook: Value) {
    record_session_id(app, &hook).await;
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

/// The room hosting the session a hook came from (by its tmux_session tag).
async fn hook_room(app: &Arc<App>, hook: &Value) -> Option<OwnedRoomId> {
    let tmux = hook.get("tmux_session").and_then(Value::as_str)?;
    app.session_room(tmux).await
}

async fn on_stop(app: &Arc<App>, hook: Value) {
    let Some(path) = hook.get("transcript_path").and_then(Value::as_str) else {
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
    let Some(room_id) = hook_room(app, &hook).await else {
        tracing::warn!("Stop hook for unknown session");
        return;
    };
    if let Some(room) = app.client.get_room(&room_id) {
        let _ = room.send(RoomMessageEventContent::text_plain(rendered)).await;
    }
}

async fn on_permission(app: &Arc<App>, hook: Value) {
    let question = hook
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("Permission requested")
        .to_string();
    let Some(room_id) = hook_room(app, &hook).await else {
        tracing::warn!("permission prompt for unknown session");
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
