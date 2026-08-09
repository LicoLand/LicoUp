//! Pairing and per-chat agent/session binding store.

use crate::platform::file_security::{
    atomic_write_private_text, ensure_private_dir, read_private_text_bounded,
};
use crate::platform::paths;
use anyhow::{Result, anyhow, ensure};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const STATE_DIRECTORY: &str = "telegram-gateway";
const STATE_FILE: &str = "bindings.json";
const MAX_STATE_BYTES: usize = 256 * 1024;
const PAIRING_TTL: Duration = Duration::from_secs(60 * 60);
pub const BINDING_SCHEMA: &str = "licoup.telegram-gateway-bindings.v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingRecord {
    pub code: String,
    pub chat_id: i64,
    pub user_id: i64,
    pub username: Option<String>,
    pub created_at: u64,
    pub expires_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ChatBinding {
    pub chat_id: i64,
    pub user_id: i64,
    pub username: Option<String>,
    pub paired: bool,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub updated_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct BindingDocument {
    schema_version: String,
    pairings: Vec<PairingRecord>,
    chats: BTreeMap<String, ChatBinding>,
}

#[derive(Debug, Clone)]
pub struct BindingStore {
    path: PathBuf,
    document: BindingDocument,
}

impl BindingStore {
    pub fn open_default() -> Result<Self> {
        let root = paths::portable_data_dir()?.join(STATE_DIRECTORY);
        ensure_private_dir(&root)?;
        Self::open(root.join(STATE_FILE))
    }

    pub fn open(path: PathBuf) -> Result<Self> {
        if let Some(parent) = path.parent() {
            ensure_private_dir(parent)?;
        }
        let document = match read_private_text_bounded(&path, MAX_STATE_BYTES)? {
            Some(raw) => serde_json::from_str(&raw)
                .map_err(|_| anyhow!("telegram_gateway_bindings_invalid"))?,
            None => BindingDocument {
                schema_version: BINDING_SCHEMA.to_owned(),
                pairings: Vec::new(),
                chats: BTreeMap::new(),
            },
        };
        let mut store = Self { path, document };
        store.expire_pairings(now_secs())?;
        Ok(store)
    }

    pub fn save(&self) -> Result<()> {
        let raw = serde_json::to_string_pretty(&self.document)?;
        atomic_write_private_text(&self.path, &raw)
    }

    pub fn binding(&self, chat_id: i64) -> Option<&ChatBinding> {
        self.document.chats.get(&chat_id.to_string())
    }

    pub fn is_paired(&self, chat_id: i64, user_id: i64) -> bool {
        self.document
            .chats
            .get(&chat_id.to_string())
            .is_some_and(|binding| binding.paired && binding.user_id == user_id)
    }

    pub fn request_pairing(
        &mut self,
        chat_id: i64,
        user_id: i64,
        username: Option<String>,
    ) -> Result<PairingRecord> {
        self.expire_pairings(now_secs())?;
        if self.is_paired(chat_id, user_id) {
            return Err(anyhow!("telegram_gateway_already_paired"));
        }
        self.document
            .pairings
            .retain(|record| record.chat_id != chat_id || record.user_id != user_id);
        let now = now_secs();
        let record = PairingRecord {
            code: generate_pairing_code(),
            chat_id,
            user_id,
            username,
            created_at: now,
            expires_at: now + PAIRING_TTL.as_secs(),
        };
        self.document.pairings.push(record.clone());
        self.save()?;
        Ok(record)
    }

    pub fn approve(&mut self, code: &str) -> Result<ChatBinding> {
        self.expire_pairings(now_secs())?;
        let normalized = code.trim().to_uppercase();
        ensure!(
            !normalized.is_empty(),
            "telegram_gateway_pairing_code_invalid"
        );
        let index = self
            .document
            .pairings
            .iter()
            .position(|record| record.code == normalized)
            .ok_or_else(|| anyhow!("telegram_gateway_pairing_not_found"))?;
        let record = self.document.pairings.remove(index);
        let binding = ChatBinding {
            chat_id: record.chat_id,
            user_id: record.user_id,
            username: record.username,
            paired: true,
            agent_id: None,
            session_id: None,
            updated_at: now_secs(),
        };
        self.document
            .chats
            .insert(record.chat_id.to_string(), binding.clone());
        self.save()?;
        Ok(binding)
    }

    pub fn revoke(&mut self, chat_id: i64) -> Result<bool> {
        let removed = self.document.chats.remove(&chat_id.to_string()).is_some();
        let before = self.document.pairings.len();
        self.document
            .pairings
            .retain(|record| record.chat_id != chat_id);
        let pairing_removed = self.document.pairings.len() != before;
        if removed || pairing_removed {
            self.save()?;
        }
        Ok(removed || pairing_removed)
    }

    pub fn paired_chats(&self) -> Vec<ChatBinding> {
        self.document
            .chats
            .values()
            .filter(|binding| binding.paired)
            .cloned()
            .collect()
    }

    pub fn set_agent(&mut self, chat_id: i64, agent_id: Option<String>) -> Result<ChatBinding> {
        let mut binding = self
            .document
            .chats
            .get(&chat_id.to_string())
            .cloned()
            .ok_or_else(|| anyhow!("telegram_gateway_not_paired"))?;
        ensure!(binding.paired, "telegram_gateway_not_paired");
        if binding.agent_id.as_deref() != agent_id.as_deref() {
            binding.session_id = None;
        }
        binding.agent_id = agent_id;
        binding.updated_at = now_secs();
        self.document
            .chats
            .insert(chat_id.to_string(), binding.clone());
        self.save()?;
        Ok(binding)
    }

    pub fn set_session(&mut self, chat_id: i64, session_id: Option<String>) -> Result<ChatBinding> {
        let mut binding = self
            .document
            .chats
            .get(&chat_id.to_string())
            .cloned()
            .ok_or_else(|| anyhow!("telegram_gateway_not_paired"))?;
        ensure!(binding.paired, "telegram_gateway_not_paired");
        ensure!(
            binding.agent_id.is_some(),
            "telegram_gateway_agent_required"
        );
        binding.session_id = session_id;
        binding.updated_at = now_secs();
        self.document
            .chats
            .insert(chat_id.to_string(), binding.clone());
        self.save()?;
        Ok(binding)
    }

    pub fn pending_pairings(&self) -> Vec<PairingRecord> {
        self.document.pairings.clone()
    }

    fn expire_pairings(&mut self, now: u64) -> Result<()> {
        let before = self.document.pairings.len();
        self.document
            .pairings
            .retain(|record| record.expires_at > now);
        if self.document.pairings.len() != before {
            self.save()?;
        }
        Ok(())
    }
}

pub fn list_pairings() -> Result<Value> {
    let store = BindingStore::open_default()?;
    Ok(json!({
        "ok": true,
        "schemaVersion": BINDING_SCHEMA,
        "pairings": store.pending_pairings(),
        "chats": store.paired_chats(),
    }))
}

pub fn approve_pairing(code: &str) -> Result<Value> {
    let mut store = BindingStore::open_default()?;
    let binding = store.approve(code)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": BINDING_SCHEMA,
        "approved": true,
        "binding": binding,
    }))
}

pub fn revoke_pairing(chat_id: i64) -> Result<Value> {
    let mut store = BindingStore::open_default()?;
    let removed = store.revoke(chat_id)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": BINDING_SCHEMA,
        "revoked": removed,
        "chatId": chat_id,
    }))
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}

fn generate_pairing_code() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut bytes = [0u8; 6];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes
        .iter()
        .map(|byte| ALPHABET[(*byte as usize) % ALPHABET.len()] as char)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::paths::set_portable_data_dir_override;
    use std::sync::Mutex;

    static LOCK: Mutex<()> = Mutex::new(());

    fn with_store<F: FnOnce(BindingStore)>(body: F) {
        let _guard = LOCK.lock().unwrap();
        let root = std::env::temp_dir().join(format!("licoup-tg-bind-{}", uuid::Uuid::new_v4()));
        let _ = std::fs::create_dir_all(&root);
        let previous = set_portable_data_dir_override(Some(root.clone()));
        let store = BindingStore::open_default().unwrap();
        body(store);
        set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn pairing_approve_and_agent_switch_clears_session() {
        with_store(|mut store| {
            let pending = store.request_pairing(11, 22, Some("alice".into())).unwrap();
            let binding = store.approve(&pending.code).unwrap();
            assert!(binding.paired);
            store.set_agent(11, Some("cursor".into())).unwrap();
            store.set_session(11, Some("sess-1".into())).unwrap();
            let switched = store.set_agent(11, Some("codex".into())).unwrap();
            assert_eq!(switched.agent_id.as_deref(), Some("codex"));
            assert_eq!(switched.session_id, None);
        });
    }

    #[test]
    fn revoke_persists_when_only_pending_pairing_exists() {
        with_store(|mut store| {
            let pending = store.request_pairing(33, 44, Some("bob".into())).unwrap();
            assert_eq!(store.pending_pairings().len(), 1);
            assert!(store.revoke(pending.chat_id).unwrap());
            assert!(store.pending_pairings().is_empty());
            let reopened = BindingStore::open_default().unwrap();
            assert!(reopened.pending_pairings().is_empty());
        });
    }

    #[test]
    fn list_pairings_includes_approved_chats() {
        with_store(|mut store| {
            let pending = store.request_pairing(55, 66, Some("carol".into())).unwrap();
            store.approve(&pending.code).unwrap();
            let listed = list_pairings().unwrap();
            assert!(listed["pairings"].as_array().unwrap().is_empty());
            assert_eq!(listed["chats"].as_array().unwrap().len(), 1);
            assert_eq!(listed["chats"][0]["chatId"], 55);
        });
    }
}
