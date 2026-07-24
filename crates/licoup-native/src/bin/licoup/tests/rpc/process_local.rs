//! Process-local RPC lifecycle regression composition.

use super::*;

#[path = "process_local/drain_probe.rs"]
mod drain_probe;
#[path = "process_local/request.rs"]
mod request;
#[path = "process_local/support.rs"]
mod support;

use drain_probe::*;
use support::*;
