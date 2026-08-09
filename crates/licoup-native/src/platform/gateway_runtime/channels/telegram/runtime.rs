//! Long-polling gateway loop and inbound message handling.

use super::binding::BindingStore;
use super::bridge::{
    ensure_known_agent, format_agent_list, format_session_list, list_agents, list_sessions,
    open_session, resolve_session_selector, send_turn,
};
use super::control::{
    ControlCommand, ControlOutcome, commands_text, help_text, parse_control_command,
};
use super::transport::{BotIdentity, BotTransport, InboundMessage, bot_commands};
use anyhow::{Result, anyhow};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

pub struct RuntimeConfig {
    pub poll_timeout_secs: u64,
    pub stop: Arc<AtomicBool>,
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            poll_timeout_secs: 25,
            stop: Arc::new(AtomicBool::new(false)),
        }
    }
}

pub fn run_channel_loop<T: BotTransport>(
    mut transport: T,
    mut store: BindingStore,
    config: RuntimeConfig,
) -> Result<BotIdentity> {
    let identity = transport
        .get_me()
        .map_err(|error| anyhow!("{}: {}", error.code, error.message))?;
    let _ = super::mark_ready(&identity.username);
    transport
        .delete_webhook()
        .map_err(|error| anyhow!("{}: {}", error.code, error.message))?;
    transport
        .set_my_commands(&bot_commands())
        .map_err(|error| anyhow!("{}: {}", error.code, error.message))?;

    let mut offset: i64 = 0;
    while !config.stop.load(Ordering::SeqCst) {
        let updates = match transport.get_updates(offset, config.poll_timeout_secs) {
            Ok(updates) => updates,
            Err(error) if error.code == "telegram_gateway_conflict" => {
                return Err(anyhow!("{}: {}", error.code, error.message));
            }
            Err(error) if error.code == "telegram_gateway_unauthorized" => {
                return Err(anyhow!("{}: {}", error.code, error.message));
            }
            Err(_) => {
                // Recoverable network blip: brief backoff then continue.
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
        };
        for update in updates {
            offset = update.update_id + 1;
            let Some(message) = update.message else {
                continue;
            };
            if let Err(error) = handle_inbound(&mut transport, &mut store, &identity, &message) {
                let _ = transport.send_message(
                    message.chat_id,
                    &format!("Error: {}", error),
                    Some(message.message_id),
                );
            }
        }
    }
    Ok(identity)
}

fn handle_inbound<T: BotTransport>(
    transport: &mut T,
    store: &mut BindingStore,
    identity: &BotIdentity,
    message: &InboundMessage,
) -> Result<()> {
    if !message.is_private {
        // MVP is DM-only.
        return Ok(());
    }
    match parse_control_command(&message.control_text()) {
        ControlOutcome::Command(command) => {
            handle_command(transport, store, identity, message, command)
        }
        ControlOutcome::OrdinaryText(_) => {
            let body = message.agent_text();
            if body.trim().is_empty() {
                return Ok(());
            }
            handle_ordinary(transport, store, message, &body)
        }
    }
}

fn send_reply<T: BotTransport>(
    transport: &mut T,
    message: &InboundMessage,
    text: &str,
) -> Result<()> {
    transport
        .send_message(message.chat_id, text, Some(message.message_id))
        .map_err(api_err)
}

fn handle_command<T: BotTransport>(
    transport: &mut T,
    store: &mut BindingStore,
    identity: &BotIdentity,
    message: &InboundMessage,
    command: ControlCommand,
) -> Result<()> {
    match command {
        ControlCommand::Help => {
            send_reply(transport, message, &help_text(&identity.username))?;
        }
        ControlCommand::Commands => {
            send_reply(transport, message, &commands_text())?;
        }
        ControlCommand::Start | ControlCommand::Pair => {
            handle_pair_request(transport, store, identity, message)?;
        }
        ControlCommand::Whoami => {
            send_reply(transport, message, &whoami_text(message))?;
        }
        ControlCommand::Unpair => {
            let revoked = store.revoke(message.chat_id)?;
            send_reply(
                transport,
                message,
                if revoked {
                    "Pairing revoked for this chat. Send /start to pair again."
                } else {
                    "No pairing found for this chat."
                },
            )?;
        }
        ControlCommand::Status => {
            if !store.is_paired(message.chat_id, message.user_id) {
                send_reply(
                    transport,
                    message,
                    "Not paired. Send /start to request a pairing code.",
                )?;
            } else {
                send_reply(
                    transport,
                    message,
                    &status_text(store, identity, message.chat_id),
                )?;
            }
        }
        ControlCommand::Agent { agent_id: None } => {
            require_paired(store, message)?;
            let agents = list_agents().map_err(|error| anyhow!(error.to_string()))?;
            send_reply(transport, message, &format_agent_list(&agents))?;
        }
        ControlCommand::Agent {
            agent_id: Some(agent_id),
        } => {
            require_paired(store, message)?;
            ensure_known_agent(&agent_id).map_err(|error| anyhow!(error.to_string()))?;
            let binding = store.set_agent(message.chat_id, Some(agent_id.clone()))?;
            send_reply(
                transport,
                message,
                &format!(
                    "Bound agent: {}.\nSession cleared. Use /session or /new, then send a message.",
                    binding.agent_id.unwrap_or(agent_id)
                ),
            )?;
        }
        ControlCommand::Session { selector: None } => {
            require_paired(store, message)?;
            let agent_id = require_agent(store, message.chat_id)?;
            let sessions = list_sessions(&agent_id).map_err(|error| anyhow!(error.to_string()))?;
            send_reply(transport, message, &format_session_list(&sessions))?;
        }
        ControlCommand::Session {
            selector: Some(selector),
        } => {
            require_paired(store, message)?;
            let agent_id = require_agent(store, message.chat_id)?;
            let sessions = list_sessions(&agent_id).map_err(|error| anyhow!(error.to_string()))?;
            let selected = resolve_session_selector(&sessions, &selector)
                .map_err(|error| anyhow!(error.to_string()))?;
            let opened = open_session(&agent_id, Some(&selected.id))
                .map_err(|error| anyhow!(error.to_string()))?;
            let session_id = if opened.is_empty() {
                selected.id.clone()
            } else {
                opened
            };
            store.set_session(message.chat_id, Some(session_id.clone()))?;
            send_reply(transport, message, &format!("Bound session: {session_id}"))?;
        }
        ControlCommand::New | ControlCommand::Reset => {
            require_paired(store, message)?;
            let agent_id = require_agent(store, message.chat_id)?;
            let opened =
                open_session(&agent_id, None).map_err(|error| anyhow!(error.to_string()))?;
            store.set_session(
                message.chat_id,
                if opened.is_empty() {
                    None
                } else {
                    Some(opened.clone())
                },
            )?;
            send_reply(
                transport,
                message,
                &format!(
                    "Started a new conversation{}.",
                    if opened.is_empty() {
                        String::new()
                    } else {
                        format!(": {opened}")
                    }
                ),
            )?;
        }
        ControlCommand::Stop => {
            send_reply(
                transport,
                message,
                "This channel processes one turn at a time. There is no separate in-flight interrupt yet; wait for the current reply, or use /new for a fresh conversation.",
            )?;
        }
        ControlCommand::Unknown { name } => {
            send_reply(
                transport,
                message,
                &format!("Unknown command /{name}. Use /commands for the catalog."),
            )?;
        }
    }
    Ok(())
}

fn handle_pair_request<T: BotTransport>(
    transport: &mut T,
    store: &mut BindingStore,
    identity: &BotIdentity,
    message: &InboundMessage,
) -> Result<()> {
    if store.is_paired(message.chat_id, message.user_id) {
        send_reply(
            transport,
            message,
            &format!(
                "Already paired.\n{}",
                status_text(store, identity, message.chat_id)
            ),
        )?;
        return Ok(());
    }
    let pending =
        store.request_pairing(message.chat_id, message.user_id, message.username.clone())?;
    send_reply(transport, message, &pairing_code_text(&pending.code))?;
    Ok(())
}

fn handle_ordinary<T: BotTransport>(
    transport: &mut T,
    store: &mut BindingStore,
    message: &InboundMessage,
    text: &str,
) -> Result<()> {
    if !store.is_paired(message.chat_id, message.user_id) {
        let pending =
            store.request_pairing(message.chat_id, message.user_id, message.username.clone())?;
        send_reply(
            transport,
            message,
            &format!("Pairing required.\n{}", pairing_code_text(&pending.code)),
        )?;
        return Ok(());
    }
    let binding = store
        .binding(message.chat_id)
        .cloned()
        .ok_or_else(|| anyhow!("telegram_gateway_not_paired"))?;
    let Some(agent_id) = binding.agent_id.clone() else {
        send_reply(
            transport,
            message,
            "No agent bound. Use /agent to list agents, then /agent <id>.",
        )?;
        return Ok(());
    };
    let (reply, next_session) = send_turn(&agent_id, binding.session_id.as_deref(), text)
        .map_err(|error| anyhow!(error.to_string()))?;
    if !next_session.is_empty() && binding.session_id.as_deref() != Some(next_session.as_str()) {
        let _ = store.set_session(message.chat_id, Some(next_session));
    }
    send_reply(transport, message, &reply)?;
    Ok(())
}

fn require_paired(store: &BindingStore, message: &InboundMessage) -> Result<()> {
    if store.is_paired(message.chat_id, message.user_id) {
        Ok(())
    } else {
        Err(anyhow!(
            "Not paired. Send /start to request a pairing code."
        ))
    }
}

fn require_agent(store: &BindingStore, chat_id: i64) -> Result<String> {
    store
        .binding(chat_id)
        .and_then(|binding| binding.agent_id.clone())
        .ok_or_else(|| anyhow!("No agent bound. Use /agent <id> first."))
}

fn status_text(store: &BindingStore, identity: &BotIdentity, chat_id: i64) -> String {
    let binding = store.binding(chat_id);
    format!(
        "Bot: @{}\nPaired: {}\nAgent: {}\nSession: {}",
        identity.username,
        binding.map(|value| value.paired).unwrap_or(false),
        binding
            .and_then(|value| value.agent_id.as_deref())
            .unwrap_or("(none)"),
        binding
            .and_then(|value| value.session_id.as_deref())
            .unwrap_or("(none)")
    )
}

fn whoami_text(message: &InboundMessage) -> String {
    format!(
        "chatId: {}\nuserId: {}\nusername: {}",
        message.chat_id,
        message.user_id,
        message
            .username
            .as_deref()
            .map(|value| format!("@{value}"))
            .unwrap_or_else(|| "(none)".to_owned())
    )
}

fn pairing_code_text(code: &str) -> String {
    format!(
        "Pairing code: {code}\n\
         Approve in LicoUp → Keys → Telegram Channel,\n\
         or: licoup-cli gateway channel telegram pairing approve {code}"
    )
}

fn api_err(error: super::transport::TelegramApiError) -> anyhow::Error {
    anyhow!("{}: {}", error.code, error.message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::gateway_runtime::channels::telegram::inbound::InboundKind;
    use crate::platform::gateway_runtime::channels::telegram::transport::{
        MockBotTransport, Update,
    };
    use crate::platform::paths::set_portable_data_dir_override;
    use std::sync::{Arc, Mutex};

    fn text_message(
        chat_id: i64,
        user_id: i64,
        username: Option<&str>,
        text: &str,
        message_id: i64,
    ) -> InboundMessage {
        InboundMessage {
            update_id: message_id,
            chat_id,
            user_id,
            username: username.map(str::to_owned),
            is_private: true,
            message_id,
            message_thread_id: None,
            edited: false,
            kind: InboundKind::Text,
            text: Some(text.to_owned()),
            caption: None,
            media: Vec::new(),
            reply_to: None,
            forward_label: None,
            location: None,
            venue_label: None,
            contact_label: None,
            poll_question: None,
        }
    }

    #[test]
    fn start_issues_pairing_and_approve_enables_agent_command() {
        let root = std::env::temp_dir().join(format!("licoup-tg-rt-{}", uuid::Uuid::new_v4()));
        let _ = std::fs::create_dir_all(&root);
        let previous = set_portable_data_dir_override(Some(root.clone()));
        let mut store = BindingStore::open_default().unwrap();
        let sent = Arc::new(Mutex::new(Vec::new()));
        let mut transport = MockBotTransport {
            sent: sent.clone(),
            ..MockBotTransport::default()
        };
        let message = text_message(99, 77, Some("bob"), "/start", 1);
        handle_inbound(
            &mut transport,
            &mut store,
            &BotIdentity::default(),
            &message,
        )
        .unwrap();
        let code = store.pending_pairings()[0].code.clone();
        store.approve(&code).unwrap();
        let list = text_message(99, 77, Some("bob"), "/agent", 2);
        handle_inbound(&mut transport, &mut store, &BotIdentity::default(), &list).unwrap();
        let messages = sent.lock().unwrap();
        assert!(
            messages
                .iter()
                .any(|(_, body)| body.contains("Pairing code"))
        );
        assert!(messages.iter().any(|(_, body)| {
            body.contains("Verified local agents") || body.contains("No verified local agents")
        }));
        set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
        let _ = Update {
            update_id: 0,
            message: None,
        };
    }

    #[test]
    fn whoami_works_before_pairing_and_unpair_revokes() {
        let root = std::env::temp_dir().join(format!("licoup-tg-who-{}", uuid::Uuid::new_v4()));
        let _ = std::fs::create_dir_all(&root);
        let previous = set_portable_data_dir_override(Some(root.clone()));
        let mut store = BindingStore::open_default().unwrap();
        let sent = Arc::new(Mutex::new(Vec::new()));
        let mut transport = MockBotTransport {
            sent: sent.clone(),
            ..MockBotTransport::default()
        };
        let identity = BotIdentity {
            username: "licoup_bot".into(),
            ..BotIdentity::default()
        };
        handle_inbound(
            &mut transport,
            &mut store,
            &identity,
            &text_message(42, 42, Some("alice"), "/whoami", 1),
        )
        .unwrap();
        handle_inbound(
            &mut transport,
            &mut store,
            &identity,
            &text_message(42, 42, Some("alice"), "/start", 2),
        )
        .unwrap();
        let code = store.pending_pairings()[0].code.clone();
        store.approve(&code).unwrap();
        handle_inbound(
            &mut transport,
            &mut store,
            &identity,
            &text_message(42, 42, Some("alice"), "/unpair", 3),
        )
        .unwrap();
        assert!(!store.is_paired(42, 42));
        let messages = sent.lock().unwrap();
        assert!(messages.iter().any(|(_, body)| body.contains("chatId: 42")));
        assert!(
            messages
                .iter()
                .any(|(_, body)| body.contains("Pairing revoked"))
        );
        set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn photo_caption_command_uses_caption_for_control() {
        let root = std::env::temp_dir().join(format!("licoup-tg-cap-{}", uuid::Uuid::new_v4()));
        let _ = std::fs::create_dir_all(&root);
        let previous = set_portable_data_dir_override(Some(root.clone()));
        let mut store = BindingStore::open_default().unwrap();
        let sent = Arc::new(Mutex::new(Vec::new()));
        let mut transport = MockBotTransport {
            sent: sent.clone(),
            ..MockBotTransport::default()
        };
        let mut message = text_message(5, 5, None, "", 1);
        message.kind = InboundKind::Photo;
        message.text = None;
        message.caption = Some("/whoami".into());
        message.media = vec![
            crate::platform::gateway_runtime::channels::telegram::inbound::MediaRef {
                kind: "photo".into(),
                file_id: "p".into(),
                file_unique_id: None,
                file_name: None,
                mime_type: None,
                file_size: Some(10),
                width: Some(1),
                height: Some(1),
                duration: None,
                emoji: None,
            },
        ];
        handle_inbound(
            &mut transport,
            &mut store,
            &BotIdentity::default(),
            &message,
        )
        .unwrap();
        let messages = sent.lock().unwrap();
        assert!(messages.iter().any(|(_, body)| body.contains("chatId: 5")));
        set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }
}
