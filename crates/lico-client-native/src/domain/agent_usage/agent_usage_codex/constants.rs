use std::time::Duration;

pub(super) const CACHE_SCHEMA_VERSION: i64 = 8;
pub(super) const PARSER_REVISION: &str = "codex-token-events-v8";
pub(super) const CACHE_REFRESH_INTERVAL: Duration = Duration::from_secs(60);
pub(super) const CACHE_DATABASE_PREFIX: &str = "agent-usage-cache-v2";
pub(super) const CONTENT_GUARD_BUFFER_BYTES: usize = 256 * 1024;
