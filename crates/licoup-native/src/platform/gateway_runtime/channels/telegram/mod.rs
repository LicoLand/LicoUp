//! Telegram Communication Channel (Bot API → local conversation lane).

mod binding;
mod bridge;
mod control;
mod credentials;
mod inbound;
mod runtime;
mod transport;

pub use binding::{
    BindingStore, ChatBinding, PairingRecord, approve_pairing, list_pairings, revoke_pairing,
};
pub use bridge::{list_agents, list_sessions, open_session, send_turn};
pub use control::{ControlCommand, ControlOutcome, parse_control_command};
pub use credentials::{
    clear_bot_token, credentials_status, load_bot_token, set_bot_token, token_configured,
};
pub use inbound::{InboundKind, InboundMessage, MediaRef, ReplyRef};
pub use runtime::{RuntimeConfig, run_channel_loop};
pub use transport::{
    BotIdentity, BotTransport, LiveBotTransport, MockBotTransport, TelegramApiError, Update,
    bot_commands,
};

use crate::platform::file_security::{
    atomic_write_private_text, ensure_private_dir, read_private_text_bounded,
    remove_private_state_marker,
};
use crate::platform::paths;
use anyhow::Result;
use serde_json::{Value, json};
use std::path::PathBuf;

const CHANNEL_STATE: &str = "telegram-gateway";
const READY_FILE: &str = "channel.ready";

fn ready_path() -> Result<PathBuf> {
    let root = paths::portable_data_dir()?.join(CHANNEL_STATE);
    ensure_private_dir(&root)?;
    Ok(root.join(READY_FILE))
}

pub fn mark_ready(bot_username: &str) -> Result<()> {
    let username = bot_username.trim_start_matches('@');
    atomic_write_private_text(
        &ready_path()?,
        &serde_json::to_string(&json!({
            "channelId": "telegram",
            "state": "running",
            "botUsername": username,
        }))?,
    )
}

pub fn clear_ready() -> Result<()> {
    let _ = remove_private_state_marker(&ready_path()?)?;
    Ok(())
}

pub fn channel_status() -> Result<Value> {
    let credentials = credentials_status()?;
    let configured = credentials
        .get("configured")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let ready = read_private_text_bounded(&ready_path()?, 1024)?
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok());
    let state = if let Some(ready) = ready.as_ref() {
        ready
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or("running")
    } else if configured {
        "configured"
    } else {
        "unconfigured"
    };
    Ok(json!({
        "ok": true,
        "schemaVersion": "licoup.gateway-channel-telegram.v1",
        "channelId": "telegram",
        "layer": "communication-channel",
        "state": state,
        "configured": configured,
        "token": credentials.get("token").cloned().unwrap_or(json!("missing")),
        "tokenSource": credentials.get("tokenSource").cloned().unwrap_or(json!("none")),
        "botUsername": ready.as_ref().and_then(|value| value.get("botUsername").cloned()),
    }))
}
