//! Configuration-backed goal lifecycle used by the production commit path.
//!
//! Public goal enums remain schema-generated wire projections. Executable
//! transitions and terminal classification come only from the compiled state
//! configuration.

use super::error::continuity_failure;
use super::generated::{
    ContinuityFailure, ContinuityFailureCode, ContinuityFailureStage, ContinuityGoalControl,
    ContinuityGoalLifecycle,
};

pub use crate::state_machine::conversation_continuity_goal_lifecycle::Event as ContinuityGoalEvent;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ContinuityGoalState {
    pub lifecycle: ContinuityGoalLifecycle,
    pub control: ContinuityGoalControl,
}

pub fn is_terminal(lifecycle: ContinuityGoalLifecycle) -> bool {
    crate::state_machine::conversation_continuity_goal_lifecycle::terminal(phase_state(lifecycle))
}

pub fn apply_goal_event(
    current: ContinuityGoalState,
    event: ContinuityGoalEvent,
) -> Result<ContinuityGoalState, ContinuityFailure> {
    use crate::state_machine::{
        conversation_continuity_goal_control as control_machine,
        conversation_continuity_goal_lifecycle as phase_machine,
    };
    let next_phase = phase_machine::transition(phase_state(current.lifecycle), event)
        .ok_or_else(invalid_transition)?;
    let control_event = control_machine::Event::from_name(event.as_str())
        .expect("goal phase and control machines declare the same event vocabulary");
    let next_control = control_machine::transition(control_state(current.control), control_event)
        .ok_or_else(invalid_transition)?;
    Ok(ContinuityGoalState {
        lifecycle: public_phase(next_phase),
        control: public_control(next_control),
    })
}

pub fn suppresses_new_work(control: ContinuityGoalControl) -> bool {
    matches!(
        control,
        ContinuityGoalControl::Paused | ContinuityGoalControl::CancelRequested
    )
}

fn invalid_transition() -> ContinuityFailure {
    continuity_failure(
        ContinuityFailureCode::InvalidRequest,
        ContinuityFailureStage::ContinuityAdmission,
    )
}

fn phase_state(
    lifecycle: ContinuityGoalLifecycle,
) -> crate::state_machine::conversation_continuity_goal_lifecycle::State {
    use crate::state_machine::conversation_continuity_goal_lifecycle::State;
    match lifecycle {
        ContinuityGoalLifecycle::Active => State::Active,
        ContinuityGoalLifecycle::Waiting => State::Waiting,
        ContinuityGoalLifecycle::Verifying => State::Verifying,
        ContinuityGoalLifecycle::Achieved => State::Achieved,
        ContinuityGoalLifecycle::Cancelled => State::Cancelled,
        ContinuityGoalLifecycle::Superseded => State::Superseded,
    }
}

fn public_phase(
    lifecycle: crate::state_machine::conversation_continuity_goal_lifecycle::State,
) -> ContinuityGoalLifecycle {
    use crate::state_machine::conversation_continuity_goal_lifecycle::State;
    match lifecycle {
        State::Active => ContinuityGoalLifecycle::Active,
        State::Waiting => ContinuityGoalLifecycle::Waiting,
        State::Verifying => ContinuityGoalLifecycle::Verifying,
        State::Achieved => ContinuityGoalLifecycle::Achieved,
        State::Cancelled => ContinuityGoalLifecycle::Cancelled,
        State::Superseded => ContinuityGoalLifecycle::Superseded,
    }
}

fn control_state(
    control: ContinuityGoalControl,
) -> crate::state_machine::conversation_continuity_goal_control::State {
    use crate::state_machine::conversation_continuity_goal_control::State;
    match control {
        ContinuityGoalControl::Enabled => State::Enabled,
        ContinuityGoalControl::Paused => State::Paused,
        ContinuityGoalControl::CancelRequested => State::CancelRequested,
    }
}

fn public_control(
    control: crate::state_machine::conversation_continuity_goal_control::State,
) -> ContinuityGoalControl {
    use crate::state_machine::conversation_continuity_goal_control::State;
    match control {
        State::Enabled => ContinuityGoalControl::Enabled,
        State::Paused => ContinuityGoalControl::Paused,
        State::CancelRequested => ContinuityGoalControl::CancelRequested,
    }
}
