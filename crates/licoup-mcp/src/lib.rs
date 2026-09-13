//! Independently buildable MCP adapter. Only the public CLI process contract
//! crosses into LicoUp; no scheduler, history store or kernel source is linked.
pub mod application;
pub mod lifecycle;
pub mod private_state;
mod server;
pub mod transport;
#[cfg(any(windows, test))]
mod windows_private_state;
mod wire;
pub use server::*;
pub use wire::*;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Map, Value};
    mod server;
    fn object(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }
}
