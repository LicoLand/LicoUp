use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct CheckpointFileRecord {
    pub label: String,
    pub relative_path: String,
    pub sha256: String,
    pub byte_size: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct CheckpointLocalFile {
    pub path: String,
    pub label: String,
    pub relative_path: String,
    pub sha256: String,
    pub byte_size: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct CheckpointManifest {
    pub input_digest: String,
    pub manifest_digest: String,
    pub file_count: usize,
    pub file_records: Vec<CheckpointFileRecord>,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum CheckpointState {
    #[default]
    FilesConfirmed,
    UploadVerified,
    ServerProcessing,
    NetworkInterrupted,
    ManualStopped,
    ServerCompleted,
    ClientConfirmed,
    Failed,
    Abandoned,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum CheckpointMode {
    #[default]
    Initial,
    Resume,
    Append,
    Branch,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct CleanupPrompt {
    pub completed_checkpoint_id: String,
    pub obsolete_checkpoint_id: String,
    pub obsolete_job_id: String,
    pub obsolete_service_url: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct CheckpointNode {
    pub checkpoint_id: String,
    pub parent_checkpoint_id: String,
    pub tree_root_id: String,
    pub branch_root_id: String,
    pub mode: CheckpointMode,
    pub state: CheckpointState,
    pub created_at: String,
    pub updated_at: String,
    pub input_digest: String,
    pub input_text: String,
    pub manifest_digest: String,
    pub summary: String,
    pub file_count: usize,
    pub file_records: Vec<CheckpointFileRecord>,
    pub local_files: Vec<CheckpointLocalFile>,
    pub local_verified_at: String,
    pub upload_verified_at: String,
    pub upload_session_id: String,
    pub upload_session_service_url: String,
    pub server_processing_at: String,
    pub server_completed_at: String,
    pub client_confirmed_at: String,
    pub network_interrupted_at: String,
    pub manual_stopped_at: String,
    pub abandoned_at: String,
    pub server_job_id: String,
    pub server_service_url: String,
    pub server_verified_manifest_digest: String,
    pub server_verified_file_count: usize,
    pub last_error: String,
    pub supersedes_checkpoint_id: String,
    pub supersedes_job_id: String,
    pub supersedes_service_url: String,
    pub resume_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct CheckpointStore {
    pub schema_version: u32,
    pub active_checkpoint_id: String,
    pub network_resume_checkpoint_id: String,
    pub manual_branch_anchor_id: String,
    pub pending_cleanup: Option<CleanupPrompt>,
    pub nodes: Vec<CheckpointNode>,
}

#[derive(Debug, Clone)]
pub struct CheckpointStart {
    pub checkpoint_id: String,
}

impl CheckpointStore {
    pub fn load(base_dir: &Path) -> Result<Self> {
        let path = checkpoints_path(base_dir);
        match fs::read_to_string(&path) {
            Ok(raw) => {
                let mut parsed: Self = serde_json::from_str(&raw).unwrap_or_default();
                if parsed.schema_version == 0 {
                    parsed.schema_version = 1;
                }
                Ok(parsed)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self {
                schema_version: 1,
                ..Self::default()
            }),
            Err(error) => {
                Err(error).with_context(|| format!("读取 checkpoint 存储失败：{}", path.display()))
            }
        }
    }

    pub fn save(&self, base_dir: &Path) -> Result<()> {
        let path = checkpoints_path(base_dir);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        fs::write(&path, serde_json::to_vec_pretty(self)?)
            .with_context(|| format!("写入 checkpoint 存储失败：{}", path.display()))
    }

    pub fn begin_submission(&mut self, manifest: &CheckpointManifest) -> CheckpointStart {
        if let Some(existing_id) = self.find_network_resume_candidate(manifest) {
            let now = now_iso_string();
            if let Some(node) = self.find_node_mut(&existing_id) {
                node.mode = CheckpointMode::Resume;
                node.state = if node.server_job_id.is_empty() {
                    CheckpointState::FilesConfirmed
                } else {
                    CheckpointState::ServerProcessing
                };
                node.updated_at = now;
                node.last_error.clear();
                node.resume_count += 1;
            }
            self.active_checkpoint_id = existing_id.clone();
            return CheckpointStart {
                checkpoint_id: existing_id,
            };
        }

        let parent_checkpoint_id = if !self.manual_branch_anchor_id.is_empty() {
            self.manual_branch_anchor_id.clone()
        } else {
            self.active_checkpoint_id.clone()
        };
        let parent = self.find_node(&parent_checkpoint_id).cloned();
        let checkpoint_id = Uuid::new_v4().to_string();
        let now = now_iso_string();
        let tree_root_id = parent
            .as_ref()
            .map(|node| node.tree_root_id.clone())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| checkpoint_id.clone());
        let branch_root_id = if !self.manual_branch_anchor_id.is_empty() {
            checkpoint_id.clone()
        } else {
            parent
                .as_ref()
                .map(|node| node.branch_root_id.clone())
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| checkpoint_id.clone())
        };
        let mode = if !self.manual_branch_anchor_id.is_empty() {
            CheckpointMode::Branch
        } else if !self.network_resume_checkpoint_id.is_empty() {
            CheckpointMode::Append
        } else if parent.is_some() {
            CheckpointMode::Append
        } else {
            CheckpointMode::Initial
        };
        let supersedes_checkpoint_id = if !self.manual_branch_anchor_id.is_empty() {
            self.manual_branch_anchor_id.clone()
        } else {
            String::new()
        };
        let supersedes_job_id = parent
            .as_ref()
            .filter(|_| !self.manual_branch_anchor_id.is_empty())
            .map(|node| node.server_job_id.clone())
            .unwrap_or_default();
        let supersedes_service_url = parent
            .as_ref()
            .filter(|_| !self.manual_branch_anchor_id.is_empty())
            .map(|node| node.server_service_url.clone())
            .unwrap_or_default();

        self.nodes.push(CheckpointNode {
            checkpoint_id: checkpoint_id.clone(),
            parent_checkpoint_id,
            tree_root_id,
            branch_root_id,
            mode,
            state: CheckpointState::FilesConfirmed,
            created_at: now.clone(),
            updated_at: now.clone(),
            input_digest: manifest.input_digest.clone(),
            input_text: String::new(),
            manifest_digest: manifest.manifest_digest.clone(),
            summary: manifest.summary.clone(),
            file_count: manifest.file_count,
            file_records: manifest.file_records.clone(),
            local_files: Vec::new(),
            local_verified_at: now,
            upload_verified_at: String::new(),
            upload_session_id: String::new(),
            upload_session_service_url: String::new(),
            server_processing_at: String::new(),
            server_completed_at: String::new(),
            client_confirmed_at: String::new(),
            network_interrupted_at: String::new(),
            manual_stopped_at: String::new(),
            abandoned_at: String::new(),
            server_job_id: String::new(),
            server_service_url: String::new(),
            server_verified_manifest_digest: String::new(),
            server_verified_file_count: 0,
            last_error: String::new(),
            supersedes_checkpoint_id,
            supersedes_job_id,
            supersedes_service_url,
            resume_count: 0,
        });

        self.active_checkpoint_id = checkpoint_id.clone();
        self.network_resume_checkpoint_id.clear();
        self.manual_branch_anchor_id.clear();

        CheckpointStart { checkpoint_id }
    }

    pub fn bind_local_payload(
        &mut self,
        checkpoint_id: &str,
        input_text: &str,
        local_files: &[CheckpointLocalFile],
    ) {
        let now = now_iso_string();
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.updated_at = now;
            node.input_text = input_text.to_string();
            node.local_files = local_files.to_vec();
        }
    }

    pub fn mark_upload_verified(
        &mut self,
        checkpoint_id: &str,
        server_job_id: &str,
        server_service_url: &str,
        server_manifest_digest: &str,
        server_file_count: usize,
    ) {
        let now = now_iso_string();
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.state = CheckpointState::UploadVerified;
            node.updated_at = now.clone();
            node.upload_verified_at = now.clone();
            node.server_processing_at = now;
            node.server_job_id = server_job_id.to_string();
            node.server_service_url = server_service_url.to_string();
            node.server_verified_manifest_digest = server_manifest_digest.to_string();
            node.server_verified_file_count = server_file_count;
            node.last_error.clear();
        }
        self.active_checkpoint_id = checkpoint_id.to_string();
        self.network_resume_checkpoint_id.clear();
    }

    pub fn bind_upload_session(
        &mut self,
        checkpoint_id: &str,
        upload_session_id: &str,
        upload_session_service_url: &str,
    ) {
        let now = now_iso_string();
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.updated_at = now;
            node.upload_session_id = upload_session_id.to_string();
            node.upload_session_service_url = upload_session_service_url.to_string();
            node.last_error.clear();
        }
    }

    pub fn mark_server_processing(&mut self, checkpoint_id: &str) {
        let now = now_iso_string();
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.state = CheckpointState::ServerProcessing;
            node.updated_at = now.clone();
            if node.server_processing_at.is_empty() {
                node.server_processing_at = now;
            }
            node.last_error.clear();
        }
        self.active_checkpoint_id = checkpoint_id.to_string();
        self.network_resume_checkpoint_id.clear();
    }

    pub fn mark_network_interrupted(&mut self, checkpoint_id: &str, error: &str) {
        let now = now_iso_string();
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.state = CheckpointState::NetworkInterrupted;
            node.updated_at = now.clone();
            node.network_interrupted_at = now;
            node.last_error = error.to_string();
        }
        self.network_resume_checkpoint_id = checkpoint_id.to_string();
        self.active_checkpoint_id = checkpoint_id.to_string();
    }

    pub fn mark_manual_stopped(&mut self, checkpoint_id: &str) {
        let now = now_iso_string();
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.state = CheckpointState::ManualStopped;
            node.updated_at = now.clone();
            node.manual_stopped_at = now;
            node.last_error = "用户手动中断。".to_string();
        }
        self.manual_branch_anchor_id = checkpoint_id.to_string();
        self.network_resume_checkpoint_id.clear();
        self.active_checkpoint_id = checkpoint_id.to_string();
    }

    pub fn mark_server_completed(&mut self, checkpoint_id: &str) {
        let now = now_iso_string();
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.state = CheckpointState::ServerCompleted;
            node.updated_at = now.clone();
            node.server_completed_at = now;
            node.last_error.clear();
        }
        self.active_checkpoint_id = checkpoint_id.to_string();
        self.network_resume_checkpoint_id.clear();
    }

    pub fn mark_client_confirmed(&mut self, checkpoint_id: &str) {
        let now = now_iso_string();
        let mut pending_cleanup = None;
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.state = CheckpointState::ClientConfirmed;
            node.updated_at = now.clone();
            node.client_confirmed_at = now;
            node.last_error.clear();

            if !node.supersedes_checkpoint_id.is_empty() {
                pending_cleanup = Some(CleanupPrompt {
                    completed_checkpoint_id: node.checkpoint_id.clone(),
                    obsolete_checkpoint_id: node.supersedes_checkpoint_id.clone(),
                    obsolete_job_id: node.supersedes_job_id.clone(),
                    obsolete_service_url: node.supersedes_service_url.clone(),
                    message: format!(
                        "新链路 {} 已确认完成，是否删除旧链路 {}？",
                        short_id(&node.checkpoint_id),
                        short_id(&node.supersedes_checkpoint_id)
                    ),
                });
            }
        }

        self.active_checkpoint_id = checkpoint_id.to_string();
        self.network_resume_checkpoint_id.clear();
        self.manual_branch_anchor_id.clear();
        self.pending_cleanup = pending_cleanup;
    }

    pub fn mark_failed(&mut self, checkpoint_id: &str, error: &str) {
        let now = now_iso_string();
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.state = CheckpointState::Failed;
            node.updated_at = now;
            node.last_error = error.to_string();
        }
    }

    pub fn mark_abandoned(&mut self, checkpoint_id: &str) {
        let now = now_iso_string();
        if let Some(node) = self.find_node_mut(checkpoint_id) {
            node.state = CheckpointState::Abandoned;
            node.updated_at = now.clone();
            node.abandoned_at = now;
        }

        if self.active_checkpoint_id == checkpoint_id {
            self.active_checkpoint_id.clear();
        }
        if self.network_resume_checkpoint_id == checkpoint_id {
            self.network_resume_checkpoint_id.clear();
        }
        if self.manual_branch_anchor_id == checkpoint_id {
            self.manual_branch_anchor_id.clear();
        }
    }

    pub fn clear_pending_cleanup(&mut self) {
        self.pending_cleanup = None;
    }

    pub fn arm_network_resume(&mut self, checkpoint_id: &str) {
        if checkpoint_id.is_empty() {
            return;
        }

        self.network_resume_checkpoint_id = checkpoint_id.to_string();
        self.active_checkpoint_id = checkpoint_id.to_string();
    }

    pub fn pending_cleanup(&self) -> Option<&CleanupPrompt> {
        self.pending_cleanup.as_ref()
    }

    pub fn find_node(&self, checkpoint_id: &str) -> Option<&CheckpointNode> {
        self.nodes
            .iter()
            .find(|node| node.checkpoint_id == checkpoint_id)
    }

    pub fn find_node_mut(&mut self, checkpoint_id: &str) -> Option<&mut CheckpointNode> {
        self.nodes
            .iter_mut()
            .find(|node| node.checkpoint_id == checkpoint_id)
    }

    fn find_network_resume_candidate(&self, manifest: &CheckpointManifest) -> Option<String> {
        if self.network_resume_checkpoint_id.is_empty() {
            return None;
        }

        self.find_node(&self.network_resume_checkpoint_id)
            .and_then(|node| {
                if node.manifest_digest == manifest.manifest_digest
                    && node.input_digest == manifest.input_digest
                {
                    Some(node.checkpoint_id.clone())
                } else {
                    None
                }
            })
    }

    pub fn auto_resume_candidate_id(&self) -> Option<String> {
        let preferred = [
            self.network_resume_checkpoint_id.as_str(),
            self.active_checkpoint_id.as_str(),
        ];

        for checkpoint_id in preferred {
            if checkpoint_id.is_empty() {
                continue;
            }

            if let Some(node) = self.find_node(checkpoint_id) {
                if is_resumable_state(&node.state) {
                    return Some(node.checkpoint_id.clone());
                }
            }
        }

        self.nodes
            .iter()
            .filter(|node| is_resumable_state(&node.state))
            .max_by(|left, right| {
                left.updated_at
                    .cmp(&right.updated_at)
                    .then_with(|| left.created_at.cmp(&right.created_at))
                    .then_with(|| left.checkpoint_id.cmp(&right.checkpoint_id))
            })
            .map(|node| node.checkpoint_id.clone())
    }

    pub fn depth_map(&self) -> HashMap<String, usize> {
        let mut depths = HashMap::new();
        for node in &self.nodes {
            let depth = depth_for_node(&self.nodes, node);
            depths.insert(node.checkpoint_id.clone(), depth);
        }
        depths
    }
}

pub fn checkpoints_path(base_dir: &Path) -> PathBuf {
    base_dir.join("checkpoints.json")
}

pub fn now_iso_string() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    format!("{:x}", hasher.finalize())
}

pub fn short_id(value: &str) -> String {
    value.chars().take(8).collect()
}

fn depth_for_node(nodes: &[CheckpointNode], node: &CheckpointNode) -> usize {
    let mut depth = 0usize;
    let mut current_parent = node.parent_checkpoint_id.as_str();

    while !current_parent.is_empty() {
        if let Some(parent) = nodes
            .iter()
            .find(|candidate| candidate.checkpoint_id == current_parent)
        {
            depth += 1;
            current_parent = parent.parent_checkpoint_id.as_str();
        } else {
            break;
        }
    }

    depth
}

fn is_resumable_state(state: &CheckpointState) -> bool {
    matches!(
        state,
        CheckpointState::FilesConfirmed
            | CheckpointState::UploadVerified
            | CheckpointState::ServerProcessing
            | CheckpointState::NetworkInterrupted
            | CheckpointState::ServerCompleted
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_manifest(summary: &str, files: &[(&str, &str, &str)]) -> CheckpointManifest {
        let file_records = files
            .iter()
            .map(|(label, relative_path, body)| CheckpointFileRecord {
                label: (*label).to_string(),
                relative_path: (*relative_path).to_string(),
                sha256: sha256_hex(body.as_bytes()),
                byte_size: body.len() as u64,
            })
            .collect::<Vec<_>>();
        let manifest_digest = sha256_hex(
            serde_json::to_string(
                &file_records
                    .iter()
                    .map(|item| (&item.relative_path, &item.sha256, item.byte_size))
                    .collect::<Vec<_>>(),
            )
            .unwrap()
            .as_bytes(),
        );

        CheckpointManifest {
            input_digest: sha256_hex(summary.as_bytes()),
            manifest_digest,
            file_count: file_records.len(),
            file_records,
            summary: summary.to_string(),
        }
    }

    #[test]
    fn resumes_same_checkpoint_after_network_interruption() {
        let mut store = CheckpointStore::default();
        let manifest = make_manifest(
            "weekly report",
            &[("周报", "mailbox/weekly.eml", "weekly body")],
        );

        let started = store.begin_submission(&manifest);
        store.mark_network_interrupted(&started.checkpoint_id, "network down");

        let resumed = store.begin_submission(&manifest);
        assert_eq!(resumed.checkpoint_id, started.checkpoint_id);

        let node = store.find_node(&started.checkpoint_id).unwrap();
        assert!(matches!(node.mode, CheckpointMode::Resume));
        assert!(matches!(node.state, CheckpointState::FilesConfirmed));
        assert_eq!(node.resume_count, 1);
        assert_eq!(store.active_checkpoint_id, started.checkpoint_id);
    }

    #[test]
    fn appends_new_manifest_after_network_interruption() {
        let mut store = CheckpointStore::default();
        let first = make_manifest(
            "weekly report",
            &[("周报", "mailbox/weekly-1.eml", "first body")],
        );
        let second = make_manifest(
            "weekly report + attachment",
            &[("周报", "mailbox/weekly-2.eml", "second body")],
        );

        let started = store.begin_submission(&first);
        store.mark_network_interrupted(&started.checkpoint_id, "network down");

        let appended = store.begin_submission(&second);
        assert_ne!(appended.checkpoint_id, started.checkpoint_id);

        let node = store.find_node(&appended.checkpoint_id).unwrap();
        assert!(matches!(node.mode, CheckpointMode::Append));
        assert_eq!(node.parent_checkpoint_id, started.checkpoint_id);
        assert_eq!(node.tree_root_id, started.checkpoint_id);
    }

    #[test]
    fn manual_stop_branches_and_creates_cleanup_prompt() {
        let mut store = CheckpointStore::default();
        let old_manifest = make_manifest(
            "old branch",
            &[("旧周报", "mailbox/weekly-old.eml", "old body")],
        );
        let new_manifest = make_manifest(
            "new branch",
            &[("新周报", "mailbox/weekly-new.eml", "new body")],
        );

        let original = store.begin_submission(&old_manifest);
        store.mark_upload_verified(
            &original.checkpoint_id,
            "job-old",
            "http://old-service:8787",
            &old_manifest.manifest_digest,
            old_manifest.file_count,
        );
        store.mark_manual_stopped(&original.checkpoint_id);

        let branched = store.begin_submission(&new_manifest);
        let branch_node = store.find_node(&branched.checkpoint_id).unwrap();
        assert!(matches!(branch_node.mode, CheckpointMode::Branch));
        assert_eq!(branch_node.parent_checkpoint_id, original.checkpoint_id);
        assert_eq!(branch_node.supersedes_checkpoint_id, original.checkpoint_id);
        assert_eq!(branch_node.supersedes_job_id, "job-old");
        assert_eq!(
            branch_node.supersedes_service_url,
            "http://old-service:8787"
        );
        assert_eq!(branch_node.branch_root_id, branched.checkpoint_id);

        store.mark_client_confirmed(&branched.checkpoint_id);

        let prompt = store.pending_cleanup().unwrap();
        assert_eq!(prompt.completed_checkpoint_id, branched.checkpoint_id);
        assert_eq!(prompt.obsolete_checkpoint_id, original.checkpoint_id);
        assert_eq!(prompt.obsolete_job_id, "job-old");
        assert_eq!(prompt.obsolete_service_url, "http://old-service:8787");
    }

    #[test]
    fn auto_resume_candidate_prefers_network_resume_pointer() {
        let mut store = CheckpointStore::default();
        let first =
            store.begin_submission(&make_manifest("first", &[("A", "mailbox/a.eml", "body-a")]));
        let second = store.begin_submission(&make_manifest(
            "second",
            &[("B", "mailbox/b.eml", "body-b")],
        ));

        store.network_resume_checkpoint_id = first.checkpoint_id.clone();
        store.active_checkpoint_id = second.checkpoint_id.clone();

        assert_eq!(
            store.auto_resume_candidate_id(),
            Some(first.checkpoint_id.clone())
        );
    }

    #[test]
    fn save_and_load_preserves_pending_cleanup() {
        let base_dir =
            std::env::temp_dir().join(format!("lico-checkpoints-{}", Uuid::new_v4()));
        fs::create_dir_all(&base_dir).unwrap();

        let mut store = CheckpointStore::default();
        let original = store.begin_submission(&make_manifest(
            "old branch",
            &[("旧周报", "mailbox/weekly-old.eml", "old body")],
        ));
        store.mark_upload_verified(
            &original.checkpoint_id,
            "job-old",
            "http://old-service:8787",
            "manifest-old",
            1,
        );
        store.bind_local_payload(
            &original.checkpoint_id,
            "pending text",
            &[CheckpointLocalFile {
                path: "/tmp/mailbox/weekly-old.eml".to_string(),
                label: "旧周报".to_string(),
                relative_path: "mailbox/weekly-old.eml".to_string(),
                sha256: "sha-old".to_string(),
                byte_size: 12,
            }],
        );
        store.bind_upload_session(
            &original.checkpoint_id,
            "upload-session-1",
            "http://server-upload:8787",
        );
        store.mark_manual_stopped(&original.checkpoint_id);

        let branch = store.begin_submission(&make_manifest(
            "new branch",
            &[("新周报", "mailbox/weekly-new.eml", "new body")],
        ));
        store.mark_client_confirmed(&branch.checkpoint_id);
        store.save(&base_dir).unwrap();

        let loaded = CheckpointStore::load(&base_dir).unwrap();
        let prompt = loaded.pending_cleanup().unwrap();
        assert_eq!(prompt.obsolete_checkpoint_id, original.checkpoint_id);
        assert_eq!(prompt.obsolete_job_id, "job-old");
        assert_eq!(prompt.obsolete_service_url, "http://old-service:8787");
        let original_node = loaded.find_node(&original.checkpoint_id).unwrap();
        assert_eq!(original_node.input_text, "pending text");
        assert_eq!(original_node.local_files.len(), 1);
        assert_eq!(
            original_node.local_files[0].path,
            "/tmp/mailbox/weekly-old.eml"
        );
        assert_eq!(original_node.upload_session_id, "upload-session-1");
        assert_eq!(
            original_node.upload_session_service_url,
            "http://server-upload:8787"
        );

        fs::remove_dir_all(&base_dir).unwrap();
    }
}
