use serde_json::Value;

pub(super) const MAX_BATCH: usize = 64;
pub(super) const DEFAULT_INTERVAL_SECONDS: i64 = 24 * 60 * 60;
pub(super) const MIN_INTERVAL_SECONDS: i64 = 15 * 60;
pub(super) const MAX_INTERVAL_SECONDS: i64 = 7 * 24 * 60 * 60;
pub(super) const CLAIM_LEASE_SECONDS: i64 = 15 * 60;
pub(super) const MAX_FAILURE_BACKOFF_SECONDS: i64 = 6 * 60 * 60;
pub(super) const LOCK_FILE: &str = ".skill-auto-update.lock";

#[derive(Clone, Debug)]
pub(super) struct UpdateJob {
    pub(super) agent_id: String,
    pub(super) skill_id: String,
    pub(super) source: Option<Value>,
    pub(super) install_root: Option<String>,
    pub(super) interval_seconds: i64,
}

pub(super) enum Selection<'a> {
    Due,
    UserRunNow {
        agent_id: &'a str,
        skill_filter: Option<&'a str>,
    },
}
