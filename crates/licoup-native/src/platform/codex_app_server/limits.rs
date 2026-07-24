use std::time::Duration;

pub(super) const INITIALIZE_REQUEST_ID: i64 = 1;
pub(super) const THREAD_REQUEST_ID: i64 = 2;
pub(super) const TURN_REQUEST_ID: i64 = 3;
pub(super) const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
