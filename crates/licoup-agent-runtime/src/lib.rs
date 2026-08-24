//! Host-neutral Agent runtime boundary.
//!
//! Concrete process, CLI, RPC, and approval drivers remain private to the
//! composing host. This crate owns the L4/L5 contracts that let those drivers
//! be selected and invoked without making the Conversation crate depend on a
//! particular host lifetime or transport implementation.

use serde_json::Value;

pub mod protocol_selector;

/// Stable identity and capability surface of one runtime driver.
///
/// Identifiers are protocol/catalog names. Implementations must not expose an
/// executable path, process identifier, credential, or machine identity here.
pub trait RuntimeDriver: Send + Sync {
    type Error: std::error::Error + Send + Sync + 'static;

    fn id(&self) -> &'static str;
    fn capabilities(&self) -> Value;
    fn dispatch(&self, operation: &str, request: &Value) -> Result<Value, Self::Error>;
}

/// Read-only driver selection. The composing host owns registration and
/// process lifetime; callers receive no mutable process-global authority.
pub trait RuntimeDriverRegistry: Send + Sync {
    type Driver: RuntimeDriver + ?Sized;

    fn driver(&self, agent_id: &str) -> Option<&Self::Driver>;
}

/// Persistent-turn operations shared by desktop reconnect and mobile resume.
/// Conversation state and replay cursors are supplied by the durable store;
/// an implementation may cache them, but the cache is never authoritative.
pub trait PersistentTurnRuntime: Send + Sync {
    type Error: std::error::Error + Send + Sync + 'static;

    fn open_or_resume(&self, request: &Value) -> Result<Value, Self::Error>;
    fn send(&self, request: &Value) -> Result<Value, Self::Error>;
    fn attach(&self, request: &Value) -> Result<Value, Self::Error>;
    fn steer(&self, request: &Value) -> Result<Value, Self::Error>;
    fn cancel(&self, request: &Value) -> Result<Value, Self::Error>;
    fn cleanup(&self, request: &Value) -> Result<Value, Self::Error>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fmt;

    #[derive(Debug)]
    struct FixtureError;

    impl fmt::Display for FixtureError {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("fixture")
        }
    }

    impl std::error::Error for FixtureError {}

    struct FixtureDriver;

    impl RuntimeDriver for FixtureDriver {
        type Error = FixtureError;

        fn id(&self) -> &'static str {
            "fixture"
        }

        fn capabilities(&self) -> Value {
            serde_json::json!({"streaming": true})
        }

        fn dispatch(&self, operation: &str, request: &Value) -> Result<Value, Self::Error> {
            Ok(serde_json::json!({"operation": operation, "request": request}))
        }
    }

    #[test]
    fn driver_contract_is_independent_of_host_process_types() {
        let driver = FixtureDriver;
        assert_eq!(driver.id(), "fixture");
        assert_eq!(driver.capabilities()["streaming"], true);
        assert_eq!(
            driver
                .dispatch("send", &serde_json::json!({"text": "hello"}))
                .unwrap()["operation"],
            "send"
        );
    }
}
