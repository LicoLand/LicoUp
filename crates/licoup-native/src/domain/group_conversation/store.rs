use super::membership::GroupRoster;
use super::turn_taking::TurnTakingPolicy;
use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupConversationRecord {
    pub id: String,
    pub title: String,
    pub roster: GroupRoster,
    pub turn_taking: TurnTakingPolicy,
    /// Canonical message projection path (parent-owned JSONL).
    pub transcript_path: PathBuf,
}

pub struct GroupConversationStore {
    root: PathBuf,
}

impl GroupConversationStore {
    pub fn open(portable_root: &Path) -> Result<Self> {
        let root = portable_root
            .join("client-state")
            .join("group-conversations");
        crate::platform::file_security::ensure_private_dir(&root)?;
        Ok(Self { root })
    }

    pub fn path_for(&self, id: &str) -> PathBuf {
        self.root.join(format!("{id}.json"))
    }

    pub fn load(&self, id: &str) -> Result<Option<GroupConversationRecord>> {
        let path = self.path_for(id);
        if !path.is_file() {
            return Ok(None);
        }
        let bytes = fs::read(&path)?;
        let record = serde_json::from_slice(&bytes)?;
        Ok(Some(record))
    }

    pub fn save(&self, record: &GroupConversationRecord) -> Result<()> {
        if record.id.trim().is_empty() {
            return Err(anyhow!("group_conversation_id_invalid"));
        }
        let path = self.path_for(&record.id);
        let text = serde_json::to_string_pretty(record)?;
        crate::platform::file_security::atomic_write_private_text(&path, &text)?;
        Ok(())
    }

    /// Ensure the default Lico group room exists.
    pub fn ensure_default_lico_room(
        &self,
        portable_root: &Path,
    ) -> Result<GroupConversationRecord> {
        const ID: &str = "lico-group-default";
        if let Some(existing) = self.load(ID)? {
            return Ok(existing);
        }
        let transcript_dir = portable_root
            .join("client-state")
            .join("group-conversations")
            .join("transcripts");
        crate::platform::file_security::ensure_private_dir(&transcript_dir)?;
        let transcript_path = transcript_dir.join(format!("{ID}.jsonl"));
        if !transcript_path.exists() {
            fs::write(&transcript_path, b"")?;
        }
        let mut roster = GroupRoster::default();
        roster.ensure_human("You");
        let record = GroupConversationRecord {
            id: ID.into(),
            title: "Lico".into(),
            roster,
            turn_taking: TurnTakingPolicy::FlywheelMainDispatch,
            transcript_path,
        };
        self.save(&record)?;
        Ok(record)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn ensure_default_room_round_trips() {
        let root = std::env::temp_dir().join(format!("lico-group-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let store = GroupConversationStore::open(&root).unwrap();
        let room = store.ensure_default_lico_room(&root).unwrap();
        assert_eq!(room.id, "lico-group-default");
        let loaded = store.load(&room.id).unwrap().unwrap();
        assert_eq!(loaded.title, "Lico");
        let _ = fs::remove_dir_all(root);
    }
}
