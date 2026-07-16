//! Responsibility-level stdio RPC regression composition.

use super::super::stdio_rpc::*;
use super::*;

#[path = "rpc/error.rs"]
mod error;
#[path = "rpc/line.rs"]
mod line;
#[path = "rpc/request.rs"]
mod request;
#[path = "rpc/response.rs"]
mod response;
#[path = "rpc/server.rs"]
mod server;
