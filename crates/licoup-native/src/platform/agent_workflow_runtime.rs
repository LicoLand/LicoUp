//! Native conversation dispatch and polling for the LicoUp workflow loop.

use crate::domain::{
    agent_workflow_loop::{
        AgentTarget, AgentWorkflowLoop, AgentWorkflowSpec, ChildDispatch, CodexPluginState,
        ConversationReturn, MainResume, OrchestrationOwner, WorkflowAction, WorkflowError,
        WorkflowState, select_orchestration_owner,
    },
    conversations,
};
use crate::platform::runtime_adapters::{RuntimeAdapterError, send_message};
use serde_json::{Value, json};
use std::{thread, time::Duration};

const MAX_MATCHED_SESSIONS: u64 = 2;

#[derive(Debug)]
pub enum WorkflowRuntimeError {
    Adapter(RuntimeAdapterError),
    DispatchFailed,
    ConversationNotFound,
    ConversationAmbiguous,
    InvalidConversationPath,
    HistoryUnavailable,
    InvalidWorkflow,
    WorkflowFailed,
    PollTimeout,
}

impl From<RuntimeAdapterError> for WorkflowRuntimeError {
    fn from(value: RuntimeAdapterError) -> Self {
        Self::Adapter(value)
    }
}

impl From<WorkflowError> for WorkflowRuntimeError {
    fn from(_: WorkflowError) -> Self {
        Self::InvalidWorkflow
    }
}

#[derive(Clone, Copy, Debug)]
pub struct PollingPolicy {
    pub interval: Duration,
    pub max_attempts_per_turn: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OrchestrationExecution {
    MainAgentPlugin,
    LicoUpCompleted,
}

impl Default for PollingPolicy {
    fn default() -> Self {
        Self {
            interval: Duration::from_millis(500),
            max_attempts_per_turn: 7_200,
        }
    }
}

trait WorkflowTransport {
    fn dispatch_child(&mut self, dispatch: &ChildDispatch) -> Result<String, WorkflowRuntimeError>;
    fn resume_main(&mut self, resume: &MainResume) -> Result<(), WorkflowRuntimeError>;
    fn poll_conversation(
        &mut self,
        adapter_id: &str,
        conversation_path: &str,
    ) -> Result<ConversationReturn, WorkflowRuntimeError>;
}

struct NativeWorkflowTransport;

impl WorkflowTransport for NativeWorkflowTransport {
    fn dispatch_child(&mut self, dispatch: &ChildDispatch) -> Result<String, WorkflowRuntimeError> {
        dispatch_child(dispatch)
    }

    fn resume_main(&mut self, resume: &MainResume) -> Result<(), WorkflowRuntimeError> {
        resume_main(resume)
    }

    fn poll_conversation(
        &mut self,
        adapter_id: &str,
        conversation_path: &str,
    ) -> Result<ConversationReturn, WorkflowRuntimeError> {
        poll_conversation(adapter_id, conversation_path)
    }
}

/// Runs the LicoUp-owned fallback one child at a time. The main conversation
/// is resumed after every returned child conversation before the next child
/// can be dispatched.
pub fn run_sequential_fallback(
    spec: AgentWorkflowSpec,
    polling: PollingPolicy,
) -> Result<WorkflowState, WorkflowRuntimeError> {
    let mut transport = NativeWorkflowTransport;
    run_with_transport(spec, polling, &mut transport)
}

/// Single ownership boundary used by the client: a ready Codex plugin keeps
/// the workflow in the main conversation; every other state executes the
/// LicoUp sequential fallback.
pub fn orchestrate(
    spec: AgentWorkflowSpec,
    codex_plugin: CodexPluginState,
    polling: PollingPolicy,
) -> Result<OrchestrationExecution, WorkflowRuntimeError> {
    let mut transport = NativeWorkflowTransport;
    orchestrate_with_transport(spec, codex_plugin, polling, &mut transport)
}

fn orchestrate_with_transport(
    spec: AgentWorkflowSpec,
    codex_plugin: CodexPluginState,
    polling: PollingPolicy,
    transport: &mut impl WorkflowTransport,
) -> Result<OrchestrationExecution, WorkflowRuntimeError> {
    if select_orchestration_owner(&spec.main.target.adapter_id, codex_plugin)
        == OrchestrationOwner::MainAgentPlugin
    {
        return Ok(OrchestrationExecution::MainAgentPlugin);
    }
    run_with_transport(spec, polling, transport)?;
    Ok(OrchestrationExecution::LicoUpCompleted)
}

fn run_with_transport(
    spec: AgentWorkflowSpec,
    polling: PollingPolicy,
    transport: &mut impl WorkflowTransport,
) -> Result<WorkflowState, WorkflowRuntimeError> {
    if polling.max_attempts_per_turn == 0 {
        return Err(WorkflowRuntimeError::InvalidWorkflow);
    }
    let mut workflow = AgentWorkflowLoop::new(spec)?;
    let mut actions = workflow.main_suspended()?;
    while let Some(action) = actions.pop() {
        actions = match action {
            WorkflowAction::DispatchChild(dispatch) => {
                let path = transport.dispatch_child(&dispatch)?;
                workflow.child_dispatched(&dispatch.dispatch_id, path)?
            }
            WorkflowAction::PollChild(poll) => {
                let observed = poll_until_returned(
                    transport,
                    &poll.adapter_id,
                    &poll.conversation_path,
                    polling,
                )?;
                workflow.observe_child(&poll.dispatch_id, observed)?
            }
            WorkflowAction::ResumeMain(resume) => {
                transport.resume_main(&resume)?;
                workflow.main_resume_dispatched()?
            }
            WorkflowAction::PollMain {
                adapter_id,
                conversation_path,
            } => {
                let observed =
                    poll_until_returned(transport, &adapter_id, &conversation_path, polling)?;
                workflow.observe_main(observed)?
            }
        };
    }
    match workflow.state() {
        WorkflowState::Completed => Ok(WorkflowState::Completed),
        WorkflowState::Failed => Err(WorkflowRuntimeError::WorkflowFailed),
        _ => Err(WorkflowRuntimeError::InvalidWorkflow),
    }
}

fn poll_until_returned(
    transport: &mut impl WorkflowTransport,
    adapter_id: &str,
    conversation_path: &str,
    policy: PollingPolicy,
) -> Result<ConversationReturn, WorkflowRuntimeError> {
    for attempt in 0..policy.max_attempts_per_turn {
        let observed = transport.poll_conversation(adapter_id, conversation_path)?;
        if observed != ConversationReturn::Pending {
            return Ok(observed);
        }
        if attempt + 1 < policy.max_attempts_per_turn && !policy.interval.is_zero() {
            thread::sleep(policy.interval);
        }
    }
    Err(WorkflowRuntimeError::PollTimeout)
}

/// Dispatches one fresh subordinate turn and returns only its local
/// conversation file location. Model output never crosses this boundary.
pub fn dispatch_child(dispatch: &ChildDispatch) -> Result<String, WorkflowRuntimeError> {
    let mut params = json!({
        "agentId": dispatch.target.adapter_id,
        "text": dispatch.prompt,
        "sessionId": "",
        "streamEvents": false,
    });
    apply_target_settings(&mut params, &dispatch.target);
    let response = send_message(&params)?;
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(WorkflowRuntimeError::DispatchFailed);
    }
    let session_id = native_session_id(&response).ok_or(WorkflowRuntimeError::DispatchFailed)?;
    resolve_conversation_path(&dispatch.target.adapter_id, session_id)
}

/// Resumes the exact main conversation using its local file location. The
/// native session identifier is resolved locally and never placed in a child
/// hand-off prompt.
pub fn resume_main(resume: &MainResume) -> Result<(), WorkflowRuntimeError> {
    let session = session_for_path(&resume.target.adapter_id, &resume.conversation_path)?;
    let session_id = session
        .get("nativeSessionId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(WorkflowRuntimeError::ConversationNotFound)?;
    let mut params = json!({
        "agentId": resume.target.adapter_id,
        "text": resume.prompt,
        "sessionId": session_id,
        "sourcePath": resume.conversation_path,
        "streamEvents": false,
    });
    apply_target_settings(&mut params, &resume.target);
    let response = send_message(&params)?;
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        Ok(())
    } else {
        Err(WorkflowRuntimeError::DispatchFailed)
    }
}

/// Polls the local history projection. Caller timeouts remain `Pending`; only
/// an explicit failed terminal projection becomes `Failed`.
pub fn poll_conversation(
    adapter_id: &str,
    conversation_path: &str,
) -> Result<ConversationReturn, WorkflowRuntimeError> {
    let session = session_for_path(adapter_id, conversation_path)?;
    if session.get("failed").and_then(Value::as_bool) == Some(true) {
        return Ok(ConversationReturn::Failed);
    }
    Ok(if session_has_user_visible_return(&session) {
        ConversationReturn::ReturnedToUser
    } else {
        ConversationReturn::Pending
    })
}

fn resolve_conversation_path(
    adapter_id: &str,
    session_id: &str,
) -> Result<String, WorkflowRuntimeError> {
    let response = conversations::conversation_list(&json!({
        "agent": adapter_id,
        "sessionId": session_id,
        "limit": MAX_MATCHED_SESSIONS,
    }))
    .map_err(|_| WorkflowRuntimeError::HistoryUnavailable)?;
    let sessions = response
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or(WorkflowRuntimeError::HistoryUnavailable)?;
    if sessions.len() != 1 {
        return Err(if sessions.is_empty() {
            WorkflowRuntimeError::ConversationNotFound
        } else {
            WorkflowRuntimeError::ConversationAmbiguous
        });
    }
    sessions[0]
        .get("sourcePath")
        .and_then(Value::as_str)
        .filter(|path| !path.is_empty() && std::path::Path::new(path).is_absolute())
        .map(str::to_owned)
        .ok_or(WorkflowRuntimeError::InvalidConversationPath)
}

fn session_for_path(
    adapter_id: &str,
    conversation_path: &str,
) -> Result<Value, WorkflowRuntimeError> {
    if conversation_path.is_empty() || !std::path::Path::new(conversation_path).is_absolute() {
        return Err(WorkflowRuntimeError::InvalidConversationPath);
    }
    let response = conversations::conversation_list(&json!({
        "agent": adapter_id,
        "matchProjectPath": conversation_path,
        "limit": MAX_MATCHED_SESSIONS,
    }))
    .map_err(|_| WorkflowRuntimeError::HistoryUnavailable)?;
    let exact = response
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or(WorkflowRuntimeError::HistoryUnavailable)?
        .iter()
        .filter(|session| {
            session.get("sourcePath").and_then(Value::as_str) == Some(conversation_path)
        })
        .collect::<Vec<_>>();
    if exact.len() != 1 {
        return Err(if exact.is_empty() {
            WorkflowRuntimeError::ConversationNotFound
        } else {
            WorkflowRuntimeError::ConversationAmbiguous
        });
    }
    Ok(exact[0].clone())
}

fn session_has_user_visible_return(session: &Value) -> bool {
    session
        .get("messages")
        .and_then(Value::as_array)
        .and_then(|messages| {
            messages.iter().rev().find(|message| {
                !matches!(
                    message.get("role").and_then(Value::as_str),
                    Some("system" | "developer" | "metadata" | "tool" | "function")
                )
            })
        })
        .is_some_and(|message| {
            matches!(
                message.get("role").and_then(Value::as_str),
                Some("assistant" | "agent")
            ) && message
                .get("text")
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty())
        })
}

fn native_session_id(response: &Value) -> Option<&str> {
    response
        .get("nativeSessionId")
        .or_else(|| response.get("sessionId"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

fn apply_target_settings(params: &mut Value, target: &AgentTarget) {
    if let Some(model) = target.model.as_deref() {
        params["model"] = json!(model);
    }
    if let Some(reasoning) = target.reasoning_effort.as_deref() {
        params["reasoningEffort"] = json!(reasoning);
    }
    if let Some(cwd) = target.working_directory.as_deref() {
        params["cwd"] = json!(cwd);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::agent_workflow_loop::{
        AgentTarget, MainConversation, WorkflowRole, WorkflowStep,
    };

    #[derive(Default)]
    struct MockTransport {
        dispatched: Vec<WorkflowRole>,
        resumed: Vec<String>,
    }

    impl WorkflowTransport for MockTransport {
        fn dispatch_child(
            &mut self,
            dispatch: &ChildDispatch,
        ) -> Result<String, WorkflowRuntimeError> {
            self.dispatched.push(dispatch.role);
            Ok(format!("/synthetic/child-{}.jsonl", self.dispatched.len()))
        }

        fn resume_main(&mut self, resume: &MainResume) -> Result<(), WorkflowRuntimeError> {
            self.resumed.push(resume.prompt.clone());
            Ok(())
        }

        fn poll_conversation(
            &mut self,
            _adapter_id: &str,
            _conversation_path: &str,
        ) -> Result<ConversationReturn, WorkflowRuntimeError> {
            Ok(ConversationReturn::ReturnedToUser)
        }
    }

    fn target(label: &str) -> AgentTarget {
        AgentTarget {
            adapter_id: "codex".into(),
            display_name: label.into(),
            model: None,
            reasoning_effort: None,
            working_directory: None,
        }
    }

    #[test]
    fn fallback_runner_never_overlaps_children_and_resumes_main_between_each() {
        let steps = [
            ("design", WorkflowRole::Designer, "Designer", "设计"),
            (
                "backend-work",
                WorkflowRole::Worker,
                "Backend Worker",
                "后端实现",
            ),
            (
                "backend-review",
                WorkflowRole::Reviewer,
                "Backend Reviewer",
                "后端审查",
            ),
            (
                "frontend-work",
                WorkflowRole::Worker,
                "Frontend Worker",
                "前端实现",
            ),
            (
                "frontend-review",
                WorkflowRole::Reviewer,
                "Frontend Reviewer",
                "前端审查",
            ),
        ]
        .into_iter()
        .map(|(id, role, label, work_summary)| WorkflowStep {
            id: id.into(),
            role,
            target: target(label),
            work_summary: work_summary.into(),
        })
        .collect();
        let spec = AgentWorkflowSpec {
            workflow_id: "workflow-a".into(),
            main: MainConversation {
                target: target("Main"),
                conversation_path: "/synthetic/main.jsonl".into(),
            },
            steps,
        };
        let mut transport = MockTransport::default();
        assert_eq!(
            run_with_transport(
                spec,
                PollingPolicy {
                    interval: Duration::ZERO,
                    max_attempts_per_turn: 1,
                },
                &mut transport,
            )
            .unwrap(),
            WorkflowState::Completed
        );
        assert_eq!(
            transport.dispatched,
            [
                WorkflowRole::Designer,
                WorkflowRole::Worker,
                WorkflowRole::Reviewer,
                WorkflowRole::Worker,
                WorkflowRole::Reviewer,
            ]
        );
        assert_eq!(transport.resumed.len(), 5);
        for (index, prompt) in transport.resumed.iter().enumerate() {
            assert!(prompt.contains(&format!("/synthetic/child-{}.jsonl", index + 1)));
        }
    }

    #[test]
    fn plugin_ready_skips_fallback_and_missing_plugin_runs_it() {
        let spec = AgentWorkflowSpec {
            workflow_id: "workflow-owner".into(),
            main: MainConversation {
                target: target("Main"),
                conversation_path: "/synthetic/main.jsonl".into(),
            },
            steps: [
                ("design", WorkflowRole::Designer, "Designer", "设计"),
                (
                    "backend-work",
                    WorkflowRole::Worker,
                    "Backend Worker",
                    "后端实现",
                ),
                (
                    "backend-review",
                    WorkflowRole::Reviewer,
                    "Backend Reviewer",
                    "后端审查",
                ),
                (
                    "frontend-work",
                    WorkflowRole::Worker,
                    "Frontend Worker",
                    "前端实现",
                ),
                (
                    "frontend-review",
                    WorkflowRole::Reviewer,
                    "Frontend Reviewer",
                    "前端审查",
                ),
            ]
            .into_iter()
            .map(|(id, role, label, work_summary)| WorkflowStep {
                id: id.into(),
                role,
                target: target(label),
                work_summary: work_summary.into(),
            })
            .collect(),
        };
        let polling = PollingPolicy {
            interval: Duration::ZERO,
            max_attempts_per_turn: 1,
        };
        let mut plugin_transport = MockTransport::default();
        assert_eq!(
            orchestrate_with_transport(
                spec.clone(),
                CodexPluginState::Ready,
                polling,
                &mut plugin_transport,
            )
            .unwrap(),
            OrchestrationExecution::MainAgentPlugin
        );
        assert!(plugin_transport.dispatched.is_empty());

        let mut fallback_transport = MockTransport::default();
        assert_eq!(
            orchestrate_with_transport(
                spec,
                CodexPluginState::Missing,
                polling,
                &mut fallback_transport,
            )
            .unwrap(),
            OrchestrationExecution::LicoUpCompleted
        );
        assert_eq!(fallback_transport.dispatched.len(), 5);
    }

    #[test]
    fn only_a_last_visible_assistant_message_counts_as_returned() {
        assert!(session_has_user_visible_return(&json!({
            "messages": [
                {"role": "user", "text": "task"},
                {"role": "assistant", "text": "done"}
            ]
        })));
        assert!(!session_has_user_visible_return(&json!({
            "messages": [
                {"role": "assistant", "text": "partial"},
                {"role": "user", "text": "continue"}
            ]
        })));
        assert!(session_has_user_visible_return(&json!({
            "messages": [{"role": "agent", "text": "done"}]
        })));
    }

    #[test]
    fn empty_or_tool_only_output_is_not_a_user_visible_return() {
        assert!(!session_has_user_visible_return(&json!({
            "messages": [{"role": "assistant", "text": ""}]
        })));
        assert!(!session_has_user_visible_return(&json!({
            "messages": [{"role": "tool", "text": "private"}]
        })));
    }
}
