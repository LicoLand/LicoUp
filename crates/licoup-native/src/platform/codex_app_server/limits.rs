use std::time::Duration;

pub(in crate::platform) const INITIALIZE_REQUEST_ID: i64 = 1;
pub(in crate::platform) const THREAD_REQUEST_ID: i64 = 2;
pub(in crate::platform) const TURN_REQUEST_ID: i64 = 3;
pub(in crate::platform) const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
