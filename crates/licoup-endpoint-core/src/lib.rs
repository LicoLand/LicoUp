//! Client use-case, session, and Protocol Line execution boundary types.
//!
//! Session and runtime-facing types live here so later nodes can fill reducers
//! and policy without changing crate identity.

pub mod authority;

pub use authority::{
    AuthenticationRequirement, ClientSession, ClientSessionState, ConfirmationRequirement,
    OperationPolicy,
};

#[cfg(test)]
mod tests {
    use super::{ClientSession, ClientSessionState, ConfirmationRequirement, OperationPolicy};

    #[test]
    fn device_unlocked_session_is_the_ordinary_default() {
        let session = ClientSession::device_unlocked();
        assert_eq!(session.state(), ClientSessionState::DeviceUnlocked);
        assert!(session.allows_ordinary_interaction());
    }

    #[test]
    fn ordinary_direct_policy_requires_no_review() {
        let policy = OperationPolicy::ordinary_direct();
        assert_eq!(policy.confirmation, ConfirmationRequirement::None);
        assert!(!policy.requires_fresh_user_presence());
    }
}
