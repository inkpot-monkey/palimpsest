//! claude-relay — relay persistent `claude` CLI sessions to/from Matrix.
//!
//! See `docs/adr/0025-claude-relay-matrix-interface.md`. This is slice 01: the
//! skeleton — log in as a bot account, sync, and act ONLY on messages from a
//! single hard-allowlisted sender MXID (the load-bearing security gate). For now
//! "act" means echo; later slices add tmux `send-keys`, transcript-driven
//! replies, polls, and session lifecycle.

use anyhow::{Context, Result};
use matrix_sdk::{
    config::SyncSettings,
    ruma::events::room::{
        member::StrippedRoomMemberEvent,
        message::{MessageType, OriginalSyncRoomMessageEvent, RoomMessageEventContent},
    },
    ruma::{OwnedUserId, UserId},
    Client, Room,
};
use std::env;

/// Relay configuration, read from the environment (the systemd unit / VM test
/// sets these). Kept tiny for slice 01; grows with later slices.
struct Config {
    homeserver: String,
    user: String,
    password: String,
    /// The ONLY sender whose messages the relay will act on. Enforced in-process
    /// (not via room ACLs) per ADR-0025 — a federated room's power levels do not
    /// fully gate spoofing.
    allowed_sender: OwnedUserId,
}

impl Config {
    fn from_env() -> Result<Self> {
        let allowed = env::var("RELAY_ALLOWED_SENDER").context("RELAY_ALLOWED_SENDER not set")?;
        Ok(Self {
            homeserver: env::var("RELAY_HOMESERVER").context("RELAY_HOMESERVER not set")?,
            user: env::var("RELAY_USER").context("RELAY_USER not set")?,
            password: env::var("RELAY_PASSWORD").context("RELAY_PASSWORD not set")?,
            allowed_sender: UserId::parse(&allowed)
                .context("RELAY_ALLOWED_SENDER must be a valid MXID")?,
        })
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
    let allowed = config.allowed_sender.clone();

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

    tracing::info!(user = %config.user, allowed = %allowed, "logged in; performing initial sync");

    // Consume existing history WITHOUT handlers so we never act on backlog (e.g.
    // echo our own past messages). Handlers added afterwards fire only for events
    // that arrive after this point.
    let response = client
        .sync_once(SyncSettings::default())
        .await
        .context("initial sync")?;

    // Join any invites that were already pending at startup (the invite handler
    // below only catches invites that arrive while syncing).
    for room in client.invited_rooms() {
        if let Err(e) = room.join().await {
            tracing::warn!(room = %room.room_id(), error = ?e, "failed to join pending invite");
        } else {
            tracing::info!(room = %room.room_id(), "joined pending invite");
        }
    }

    // Auto-join rooms we are invited to (so the operator can start a chat with the
    // relay bot). Only act on invites addressed to us.
    client.add_event_handler(
        |ev: StrippedRoomMemberEvent, room: Room, client: Client| async move {
            let Some(me) = client.user_id() else {
                return;
            };
            if ev.state_key != me {
                return;
            }
            match room.join().await {
                Ok(_) => tracing::info!(room = %room.room_id(), "joined on invite"),
                Err(e) => tracing::warn!(room = %room.room_id(), error = ?e, "join failed"),
            }
        },
    );

    // The security gate + slice-01 behaviour: echo text messages, but ONLY from the
    // allowlisted sender, and never our own.
    client.add_event_handler(
        move |ev: OriginalSyncRoomMessageEvent, room: Room, client: Client| {
            let allowed = allowed.clone();
            async move {
                // Never react to our own messages (would loop).
                if client.user_id().is_some_and(|me| me == ev.sender) {
                    return;
                }
                // Hard allowlist: ignore everyone else.
                if ev.sender != allowed {
                    tracing::info!(sender = %ev.sender, "ignoring message from non-allowlisted sender");
                    return;
                }
                let MessageType::Text(text) = ev.content.msgtype else {
                    return;
                };
                tracing::info!(sender = %ev.sender, "echoing allowlisted message");
                let reply = RoomMessageEventContent::text_plain(format!("echo: {}", text.body));
                if let Err(e) = room.send(reply).await {
                    tracing::warn!(error = ?e, "failed to send echo");
                }
            }
        },
    );

    tracing::info!("entering sync loop");
    client
        .sync(SyncSettings::default().token(response.next_batch))
        .await
        .context("sync loop")?;
    Ok(())
}
