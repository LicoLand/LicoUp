//! Configuration-backed lifecycle for durable parent-context grants.
//!
//! The schema-generated public enum is the wire projection. The compiled
//! state configuration is the sole executable transition authority.

use super::ContinuityParentGrantStatus;
use crate::state_machine::conversation_continuity_parent_grant as machine;

pub fn initial_parent_grant_status() -> ContinuityParentGrantStatus {
    public_status(machine::INITIAL)
}

pub fn revoke_parent_grant_status(
    current: ContinuityParentGrantStatus,
) -> Option<ContinuityParentGrantStatus> {
    machine::transition(machine_status(current), machine::Event::Revoke).map(public_status)
}

fn machine_status(status: ContinuityParentGrantStatus) -> machine::State {
    match status {
        ContinuityParentGrantStatus::Admitted => machine::State::Admitted,
        ContinuityParentGrantStatus::Revoked => machine::State::Revoked,
        ContinuityParentGrantStatus::Exhausted => machine::State::Exhausted,
    }
}

fn public_status(status: machine::State) -> ContinuityParentGrantStatus {
    match status {
        machine::State::Admitted => ContinuityParentGrantStatus::Admitted,
        machine::State::Revoked => ContinuityParentGrantStatus::Revoked,
        machine::State::Exhausted => ContinuityParentGrantStatus::Exhausted,
    }
}
