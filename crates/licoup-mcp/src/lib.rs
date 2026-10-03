//! Independently buildable MCP adapter. Only the public CLI process contract
//! crosses into LicoUp; no scheduler, history store or kernel source is linked.
//!
//! The crate has two layers, and the boundary between them is the `service`
//! Cargo feature.
//!
//! * `wire` and `server` are the service-neutral MCP engine: JSON-RPC
//!   framing, initialization, tool listing, cancellation and calls. They name no
//!   subagent, spawn no process and bind no endpoint, so the crate builds them
//!   without the optional payload.
//! * `application`, `transport`, `lifecycle` and `private_state` are the
//!   optional `org.licoland.feature.mcp` package: the five-tool subagent
//!   catalog, the CLI client behind it, the authenticated loopback endpoint and
//!   the service process control, plus the `connector` binary module that maps
//!   one stdio frame to one authenticated request. `lico-subagent-mcp` requires
//!   the feature and is not built without it; a consumer that wants only the
//!   engine does not build it either.

mod server;
pub mod wire;
pub use server::*;
pub use wire::*;

#[cfg(feature = "service")]
pub mod application;
#[cfg(feature = "service")]
pub mod lifecycle;
#[cfg(feature = "service")]
pub mod private_state;
#[cfg(feature = "service")]
pub mod transport;
#[cfg(all(feature = "service", any(windows, test)))]
mod windows_private_state;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Map, Value};
    mod server;
    fn object(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }
}
