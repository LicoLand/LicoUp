use super::AdapterContract;
use crate::platform::native_agent_parser::{LifecycleStage, Transition, TransitionReducer};
pub(super) const CONTRACT: AdapterContract =
    AdapterContract::new("openclaw", "gateway-jsonrpc-acp");

pub(in crate::platform) fn completed_transitions(output: &str) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Accepted);
    transitions.extend(reducer.advance(LifecycleStage::Processing));
    transitions.extend(reducer.advance(LifecycleStage::Responding));
    transitions.push(Transition::Text {
        unit_id: "openclaw:reply".to_owned(),
        text: output.to_owned(),
    });
    transitions.extend(reducer.advance(LifecycleStage::Completed));
    transitions
}

pub(in crate::platform) fn failed_transitions(
    code: &str,
    stage: &str,
    message: &str,
) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Accepted);
    if let Some(failure) = reducer.fail(code, stage, message) {
        transitions.push(failure);
    }
    transitions
}
