//! Pure, total transition reducer used for both live mutation and recovery.
use super::{EngineErrorCode, StepState, WorkflowEvent, WorkflowSnapshot, WorkflowState};

pub fn reduce_workflow_event(
    state: &WorkflowSnapshot,
    event: &WorkflowEvent,
) -> Result<WorkflowSnapshot, EngineErrorCode> {
    if state.state.is_terminal() {
        return Err(EngineErrorCode::TerminalState);
    }
    let mut next = state.clone();
    match event {
        WorkflowEvent::Admitted { input_artifact } if state.state == WorkflowState::Created => {
            next.submit_input = Some(input_artifact.clone());
            next.state = WorkflowState::Admitted;
        }
        WorkflowEvent::ApprovalRequested { step_id } => {
            let s = step_mut(&mut next, step_id)?;
            require(s.state == StepState::Pending)?;
            s.state = StepState::AwaitingApproval;
            next.state = WorkflowState::AwaitingApproval;
            next.active_step_id = Some(step_id.clone());
        }
        WorkflowEvent::StepApproved { step_id } => {
            let s = step_mut(&mut next, step_id)?;
            require(s.state == StepState::AwaitingApproval)?;
            s.approved = true;
            s.state = StepState::Pending;
            next.state = WorkflowState::Admitted;
            next.active_step_id = None;
        }
        WorkflowEvent::ConditionEvaluated { step_id, matched } => {
            let s = step_mut(&mut next, step_id)?;
            require(s.state == StepState::Pending)?;
            if !matched {
                s.state = StepState::Skipped;
            }
        }
        WorkflowEvent::DispatchStarted {
            step_id,
            attempt,
            absolute_deadline_ms,
            ..
        } => {
            require(!next.steps.iter().any(|s| s.state.is_active()))?;
            let s = step_mut(&mut next, step_id)?;
            require(s.state == StepState::Pending)?;
            s.state = StepState::Dispatching;
            s.attempts = *attempt;
            s.deadline_ms = Some(*absolute_deadline_ms);
            next.state = WorkflowState::Running;
            next.active_step_id = Some(step_id.clone());
        }
        WorkflowEvent::DispatchProvenSucceeded {
            step_id,
            artifact_handle,
            digest,
        } => {
            let s = step_mut(&mut next, step_id)?;
            if s.state.is_terminal() {
                return Err(EngineErrorCode::TerminalState);
            }
            require(matches!(
                s.state,
                StepState::Dispatching | StepState::Running | StepState::Validating
            ))?;
            s.state = StepState::Succeeded;
            s.deadline_ms = None;
            s.artifact = Some(super::ArtifactRef {
                opaque_handle: artifact_handle.clone(),
                digest: digest.clone(),
            });
            next.state = WorkflowState::Admitted;
            next.active_step_id = None;
            next.reason_code = Some("provider_summary_redacted".into());
        }
        WorkflowEvent::StepFailed {
            step_id,
            reason_code,
        } => {
            let s = step_mut(&mut next, step_id)?;
            require(!s.state.is_terminal())?;
            s.state = StepState::Failed;
            s.deadline_ms = None;
            next.state = WorkflowState::Admitted;
            next.active_step_id = None;
            next.reason_code = Some(reason_code.clone());
        }
        WorkflowEvent::StepCancelled { step_id } => {
            let s = step_mut(&mut next, step_id)?;
            require(!s.state.is_terminal())?;
            s.state = StepState::Cancelled;
            s.deadline_ms = None;
            next.active_step_id = None;
        }
        WorkflowEvent::StepUnknown {
            step_id,
            reason_code,
        } => {
            let s = step_mut(&mut next, step_id)?;
            require(!s.state.is_terminal())?;
            s.state = StepState::Unknown;
            s.deadline_ms = None;
            next.active_step_id = None;
            next.reason_code = Some(reason_code.clone());
        }
        WorkflowEvent::WorkflowCompleted => {
            next.state = WorkflowState::Completed;
            next.active_step_id = None;
        }
        WorkflowEvent::WorkflowFailed { reason_code } => {
            next.state = WorkflowState::Failed;
            next.reason_code = Some(reason_code.clone());
            next.active_step_id = None;
        }
        WorkflowEvent::WorkflowCancelled { reason_code } => {
            next.state = WorkflowState::Cancelled;
            next.reason_code = Some(reason_code.clone());
            next.active_step_id = None;
            for s in &mut next.steps {
                if !s.state.is_terminal() {
                    s.state = StepState::Cancelled;
                    s.deadline_ms = None;
                }
            }
        }
        WorkflowEvent::WorkflowUnknown { reason_code } => {
            next.state = WorkflowState::Unknown;
            next.reason_code = Some(reason_code.clone());
            next.active_step_id = None;
        }
        _ => return Err(EngineErrorCode::InvalidCommand),
    }
    Ok(next)
}
fn require(ok: bool) -> Result<(), EngineErrorCode> {
    if ok {
        Ok(())
    } else {
        Err(EngineErrorCode::InvalidCommand)
    }
}
fn step_mut<'a>(
    state: &'a mut WorkflowSnapshot,
    id: &str,
) -> Result<&'a mut super::StepSnapshot, EngineErrorCode> {
    state
        .steps
        .iter_mut()
        .find(|s| s.id == id)
        .ok_or(EngineErrorCode::NotFound)
}
