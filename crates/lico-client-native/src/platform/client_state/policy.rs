pub(super) const STATE_SCHEMA_VERSION: &str = "v0.0.1:schema:definition-1";
pub(super) const CLIENT_STATE_DIR: &str = "client-state";
pub(super) const ACTIVITY_DIR: &str = "activity";
pub(super) const ACTIVITY_FILE: &str = "activity.jsonl";
pub(super) const SNAPSHOT_DIR: &str = "snapshots";
pub(super) const REDACTED_SECRET: &str = "<redacted-secret>";
pub(super) const REDACTED_PRIVATE_KEY: &str = "<redacted-private-key>";
pub(super) const REDACTED_LOCAL_PATH: &str = "<private-local-path>";

pub(super) const MAX_COLLECTION_DOCUMENT_BYTES: usize = 16 * 1024 * 1024;
pub(super) const MAX_ACTIVITY_FILE_BYTES: usize = 64 * 1024 * 1024;
pub(super) const MAX_ACTIVITY_EVENT_BYTES: usize = 4 * 1024 * 1024;
pub(super) const MAX_ACTIVITY_EVENTS: usize = 10_000;
pub(super) const MAX_ACTIVITY_TYPE_BYTES: usize = 128;
pub(super) const MAX_SNAPSHOT_SOURCE_BYTES: usize = 8 * 1024 * 1024;
pub(super) const MAX_SNAPSHOT_RECORD_BYTES: usize = 64 * 1024 * 1024;
pub(super) const MAX_SNAPSHOT_FILES: usize = 10_000;
pub(super) const MAX_SNAPSHOT_ID_BYTES: usize = 192;
pub(super) const MAX_LOCAL_PATH_BYTES: usize = 4 * 1024;
pub(super) const MAX_REDACTION_DEPTH: usize = 64;
pub(super) const MAX_REDACTION_PATHS: usize = 4_096;

pub(super) const COLLECTIONS: &[&str] = &[
    "settings",
    "targets",
    "target-discovery-cache",
    "pairings",
    "skills",
    "pins",
    "identities",
    "conversation-archive-profiles",
    "agent-usage-reports",
    "skill-usage",
    "collaboration-plugins",
    "local-server-assemblies",
    "local-server-assembly-cleanup",
    "local-server-assembly-transaction",
    "mcp-install-transactions",
];
