//! Telegram Bot API transport (long polling by default).

use super::inbound::parse_message_update;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::Read;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[cfg(test)]
use super::inbound::InboundKind;
pub use super::inbound::InboundMessage;

pub const DEFAULT_API_ROOT: &str = "https://api.telegram.org";
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TelegramApiError {
    pub code: String,
    pub message: String,
}

impl TelegramApiError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

impl std::fmt::Display for TelegramApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for TelegramApiError {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BotIdentity {
    pub id: i64,
    pub username: String,
    pub first_name: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Update {
    pub update_id: i64,
    pub message: Option<InboundMessage>,
}

pub trait BotTransport: Send {
    fn get_me(&mut self) -> Result<BotIdentity, TelegramApiError>;
    fn delete_webhook(&mut self) -> Result<(), TelegramApiError>;
    fn set_my_commands(&mut self, commands: &[(String, String)]) -> Result<(), TelegramApiError>;
    fn get_updates(
        &mut self,
        offset: i64,
        timeout_secs: u64,
    ) -> Result<Vec<Update>, TelegramApiError>;
    fn send_message(
        &mut self,
        chat_id: i64,
        text: &str,
        reply_to_message_id: Option<i64>,
    ) -> Result<(), TelegramApiError>;
}

pub fn bot_commands() -> Vec<(String, String)> {
    vec![
        ("start".into(), "Request a pairing code".into()),
        ("help".into(), "Show help".into()),
        ("commands".into(), "List commands".into()),
        ("whoami".into(), "Show your Telegram ids".into()),
        ("pair".into(), "Show or renew pairing code".into()),
        ("unpair".into(), "Revoke this chat pairing".into()),
        ("status".into(), "Show pairing, agent, session".into()),
        ("agent".into(), "List or select a local agent".into()),
        ("session".into(), "List or select a conversation".into()),
        ("new".into(), "Start a new conversation".into()),
        ("reset".into(), "Same as /new".into()),
        ("stop".into(), "Stop note (turns are sequential)".into()),
    ]
}

/// Live ureq-backed Bot API client.
pub struct LiveBotTransport {
    api_root: String,
    token: String,
    agent: ureq::Agent,
}

impl LiveBotTransport {
    pub fn new(token: impl Into<String>, api_root: Option<&str>) -> Self {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(15))
            .timeout_read(Duration::from_secs(90))
            .build();
        Self {
            api_root: api_root
                .unwrap_or(DEFAULT_API_ROOT)
                .trim_end_matches('/')
                .to_owned(),
            token: token.into(),
            agent,
        }
    }

    fn method_url(&self, method: &str) -> String {
        format!("{}/bot{}/{}", self.api_root, self.token, method)
    }

    fn call_json(&self, method: &str, body: Value) -> Result<Value, TelegramApiError> {
        let url = self.method_url(method);
        let response = self
            .agent
            .post(&url)
            .set("Content-Type", "application/json")
            .send_json(body)
            .map_err(|error| map_transport_error(method, error))?;
        let status = response.status();
        let mut buffer = Vec::new();
        response
            .into_reader()
            .take(MAX_RESPONSE_BYTES as u64 + 1)
            .read_to_end(&mut buffer)
            .map_err(|error| {
                TelegramApiError::new("telegram_gateway_read_failed", error.to_string())
            })?;
        if buffer.len() > MAX_RESPONSE_BYTES {
            return Err(TelegramApiError::new(
                "telegram_gateway_response_too_large",
                "Bot API response exceeded bound",
            ));
        }
        let value: Value = serde_json::from_slice(&buffer).map_err(|error| {
            TelegramApiError::new("telegram_gateway_json_invalid", error.to_string())
        })?;
        if status == 401 || value["error_code"].as_i64() == Some(401) {
            return Err(TelegramApiError::new(
                "telegram_gateway_unauthorized",
                "getMe/Bot API rejected the bot token",
            ));
        }
        if status == 409 || value["error_code"].as_i64() == Some(409) {
            return Err(TelegramApiError::new(
                "telegram_gateway_conflict",
                "getUpdates conflict: another poller is using this bot token",
            ));
        }
        if value["ok"].as_bool() != Some(true) {
            let description = value["description"]
                .as_str()
                .unwrap_or("Bot API request failed");
            return Err(TelegramApiError::new(
                "telegram_gateway_api_failed",
                format!("{method}: {description}"),
            ));
        }
        Ok(value["result"].clone())
    }
}

impl BotTransport for LiveBotTransport {
    fn get_me(&mut self) -> Result<BotIdentity, TelegramApiError> {
        let result = self.call_json("getMe", json!({}))?;
        Ok(BotIdentity {
            id: result["id"].as_i64().unwrap_or_default(),
            username: result["username"].as_str().unwrap_or("").to_owned(),
            first_name: result["first_name"].as_str().unwrap_or("").to_owned(),
        })
    }

    fn delete_webhook(&mut self) -> Result<(), TelegramApiError> {
        let _ = self.call_json("deleteWebhook", json!({ "drop_pending_updates": false }))?;
        Ok(())
    }

    fn set_my_commands(&mut self, commands: &[(String, String)]) -> Result<(), TelegramApiError> {
        let payload = commands
            .iter()
            .map(|(command, description)| {
                json!({
                    "command": command,
                    "description": description,
                })
            })
            .collect::<Vec<_>>();
        let _ = self.call_json("setMyCommands", json!({ "commands": payload }))?;
        Ok(())
    }

    fn get_updates(
        &mut self,
        offset: i64,
        timeout_secs: u64,
    ) -> Result<Vec<Update>, TelegramApiError> {
        let result = self.call_json(
            "getUpdates",
            json!({
                "offset": offset,
                "timeout": timeout_secs,
                "allowed_updates": ["message", "edited_message"],
            }),
        )?;
        let items = result.as_array().cloned().unwrap_or_default();
        Ok(items.iter().filter_map(parse_update).collect())
    }

    fn send_message(
        &mut self,
        chat_id: i64,
        text: &str,
        reply_to_message_id: Option<i64>,
    ) -> Result<(), TelegramApiError> {
        let chunks = chunk_telegram_text(text, 4000);
        for (index, chunk) in chunks.iter().enumerate() {
            let mut body = json!({
                "chat_id": chat_id,
                "text": chunk,
                "disable_web_page_preview": true,
            });
            if index == 0 {
                if let Some(reply_to) = reply_to_message_id {
                    body["reply_to_message_id"] = json!(reply_to);
                    body["allow_sending_without_reply"] = json!(true);
                }
            }
            let _ = self.call_json("sendMessage", body)?;
        }
        Ok(())
    }
}

fn map_transport_error(method: &str, error: ureq::Error) -> TelegramApiError {
    match error {
        ureq::Error::Status(401, _) => TelegramApiError::new(
            "telegram_gateway_unauthorized",
            format!("{method}: unauthorized"),
        ),
        ureq::Error::Status(409, _) => TelegramApiError::new(
            "telegram_gateway_conflict",
            "getUpdates conflict: another poller is using this bot token",
        ),
        ureq::Error::Status(code, response) => {
            let description = response
                .into_string()
                .unwrap_or_else(|_| "status error".into());
            TelegramApiError::new(
                "telegram_gateway_api_failed",
                format!("{method}: HTTP {code}: {description}"),
            )
        }
        other => TelegramApiError::new(
            "telegram_gateway_network_failed",
            format!("{method}: {other}"),
        ),
    }
}

fn parse_update(value: &Value) -> Option<Update> {
    let update_id = value.get("update_id")?.as_i64()?;
    let message = value
        .get("message")
        .and_then(|message| parse_message_update(update_id, message, false))
        .or_else(|| {
            value
                .get("edited_message")
                .and_then(|message| parse_message_update(update_id, message, true))
        });
    Some(Update { update_id, message })
}

pub fn chunk_telegram_text(text: &str, limit: usize) -> Vec<String> {
    if text.is_empty() {
        return vec![String::new()];
    }
    let mut chunks = Vec::new();
    let mut rest = text;
    while !rest.is_empty() {
        if rest.len() <= limit {
            chunks.push(rest.to_owned());
            break;
        }
        let mut end = limit;
        while !rest.is_char_boundary(end) {
            end -= 1;
        }
        if let Some(split) = rest[..end].rfind('\n') {
            if split > limit / 4 {
                end = split + 1;
            }
        }
        chunks.push(rest[..end].to_owned());
        rest = &rest[end..];
    }
    chunks
}

/// In-memory transport for tests.
#[derive(Default)]
pub struct MockBotTransport {
    pub identity: BotIdentity,
    pub updates: Arc<Mutex<Vec<Update>>>,
    pub sent: Arc<Mutex<Vec<(i64, String)>>>,
    pub fail_get_updates_with: Option<TelegramApiError>,
    pub commands: Arc<Mutex<Vec<(String, String)>>>,
    pub webhook_deleted: Arc<Mutex<bool>>,
}

impl Default for BotIdentity {
    fn default() -> Self {
        Self {
            id: 1,
            username: "licoup_bot".into(),
            first_name: "LicoUp".into(),
        }
    }
}

impl BotTransport for MockBotTransport {
    fn get_me(&mut self) -> Result<BotIdentity, TelegramApiError> {
        Ok(self.identity.clone())
    }

    fn delete_webhook(&mut self) -> Result<(), TelegramApiError> {
        *self.webhook_deleted.lock().unwrap() = true;
        Ok(())
    }

    fn set_my_commands(&mut self, commands: &[(String, String)]) -> Result<(), TelegramApiError> {
        *self.commands.lock().unwrap() = commands.to_vec();
        Ok(())
    }

    fn get_updates(
        &mut self,
        offset: i64,
        _timeout_secs: u64,
    ) -> Result<Vec<Update>, TelegramApiError> {
        if let Some(error) = self.fail_get_updates_with.clone() {
            return Err(error);
        }
        let mut guard = self.updates.lock().unwrap();
        let (keep, take): (Vec<_>, Vec<_>) = guard
            .drain(..)
            .partition(|update| update.update_id < offset);
        *guard = keep;
        Ok(take)
    }

    fn send_message(
        &mut self,
        chat_id: i64,
        text: &str,
        _reply_to_message_id: Option<i64>,
    ) -> Result<(), TelegramApiError> {
        self.sent.lock().unwrap().push((chat_id, text.to_owned()));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_private_message_update() {
        let update = parse_update(&json!({
            "update_id": 10,
            "message": {
                "message_id": 3,
                "text": "/agent cursor",
                "chat": { "id": 42, "type": "private" },
                "from": { "id": 7, "username": "alice" }
            }
        }))
        .unwrap();
        let message = update.message.unwrap();
        assert_eq!(message.chat_id, 42);
        assert_eq!(message.user_id, 7);
        assert!(message.is_private);
        assert_eq!(message.control_text(), "/agent cursor");
    }

    #[test]
    fn parses_edited_photo_update() {
        let update = parse_update(&json!({
            "update_id": 11,
            "edited_message": {
                "message_id": 4,
                "caption": "updated",
                "photo": [{ "file_id": "p1", "width": 1, "height": 1 }],
                "chat": { "id": 42, "type": "private" },
                "from": { "id": 7 }
            }
        }))
        .unwrap();
        let message = update.message.unwrap();
        assert!(message.edited);
        assert_eq!(message.kind, InboundKind::Photo);
        assert!(message.agent_text().contains("[edited]"));
        assert!(message.agent_text().contains("updated"));
    }

    #[test]
    fn chunks_long_text_on_boundaries() {
        let text = format!("{}\n{}", "a".repeat(30), "b".repeat(30));
        let chunks = chunk_telegram_text(&text, 40);
        assert!(chunks.len() >= 2);
        assert!(chunks.iter().all(|chunk| chunk.len() <= 40));
        assert_eq!(chunks.concat(), text);
    }
}
