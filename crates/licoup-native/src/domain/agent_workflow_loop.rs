//! LicoUp-native, host-neutral sequential agent workflow coordination.
//!
//! The workflow does not depend on an external skill, role package, or plan
//! state. It alternates between one subordinate turn and the suspended main
//! conversation. Native conversation locations remain local hand-off handles.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const MAX_STEPS: usize = 256;
const MAX_IDENTIFIER_BYTES: usize = 256;
const MAX_LABEL_BYTES: usize = 512;
const MAX_CONVERSATION_PATH_BYTES: usize = 4096;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowRole {
    Designer,
    Worker,
    Reviewer,
}

impl WorkflowRole {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "designer" => Some(Self::Designer),
            "worker" => Some(Self::Worker),
            "reviewer" => Some(Self::Reviewer),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AgentTarget {
    pub adapter_id: String,
    pub display_name: String,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub working_directory: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowStep {
    pub id: String,
    pub role: WorkflowRole,
    pub target: AgentTarget,
    pub work_summary: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MainConversation {
    pub target: AgentTarget,
    pub conversation_path: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AgentWorkflowSpec {
    pub workflow_id: String,
    pub main: MainConversation,
    pub steps: Vec<WorkflowStep>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowState {
    AwaitingMainSuspension,
    DispatchingChild,
    AwaitingChildReturn,
    ResumingMain,
    AwaitingMainReturn,
    Completed,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChildDispatch {
    pub dispatch_id: String,
    pub workflow_id: String,
    pub step_id: String,
    pub role: WorkflowRole,
    pub target: AgentTarget,
    pub prompt: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConversationPoll {
    pub dispatch_id: String,
    pub adapter_id: String,
    pub conversation_path: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MainResume {
    pub workflow_id: String,
    pub target: AgentTarget,
    pub conversation_path: String,
    pub prompt: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkflowAction {
    DispatchChild(ChildDispatch),
    PollChild(ConversationPoll),
    ResumeMain(MainResume),
    PollMain {
        adapter_id: String,
        conversation_path: String,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConversationReturn {
    Pending,
    ReturnedToUser,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkflowError {
    InvalidSpec,
    InvalidTransition,
    DispatchMismatch,
    ConversationPathInvalid,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodexPluginState {
    Ready,
    Missing,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OrchestrationOwner {
    MainAgentPlugin,
    LicoUpFallback,
}

pub fn select_orchestration_owner(
    main_adapter_id: &str,
    plugin_state: CodexPluginState,
) -> OrchestrationOwner {
    if main_adapter_id == "codex" && plugin_state == CodexPluginState::Ready {
        OrchestrationOwner::MainAgentPlugin
    } else {
        OrchestrationOwner::LicoUpFallback
    }
}

#[derive(Clone, Debug)]
struct ActiveChild {
    dispatch_id: String,
    step_index: usize,
    conversation_path: Option<String>,
}

/// main suspends → child runs → child transcript returns → main resumes →
/// main transcript returns → next child runs.
#[derive(Debug)]
pub struct AgentWorkflowLoop {
    spec: AgentWorkflowSpec,
    state: WorkflowState,
    next_step: usize,
    next_dispatch: u64,
    active_child: Option<ActiveChild>,
}

impl AgentWorkflowLoop {
    pub fn new(spec: AgentWorkflowSpec) -> Result<Self, WorkflowError> {
        validate_spec(&spec)?;
        Ok(Self {
            spec,
            state: WorkflowState::AwaitingMainSuspension,
            next_step: 0,
            next_dispatch: 1,
            active_child: None,
        })
    }

    pub fn state(&self) -> WorkflowState {
        self.state
    }

    pub fn main_suspended(&mut self) -> Result<Vec<WorkflowAction>, WorkflowError> {
        if !matches!(
            self.state,
            WorkflowState::AwaitingMainSuspension | WorkflowState::AwaitingMainReturn
        ) || self.active_child.is_some()
        {
            return Err(WorkflowError::InvalidTransition);
        }
        self.dispatch_next_child()
    }

    pub fn child_dispatched(
        &mut self,
        dispatch_id: &str,
        conversation_path: String,
    ) -> Result<Vec<WorkflowAction>, WorkflowError> {
        validate_conversation_path(&conversation_path)?;
        if self.state != WorkflowState::DispatchingChild {
            return Err(WorkflowError::InvalidTransition);
        }
        let active = self
            .active_child
            .as_mut()
            .ok_or(WorkflowError::InvalidTransition)?;
        if active.dispatch_id != dispatch_id {
            return Err(WorkflowError::DispatchMismatch);
        }
        active.conversation_path = Some(conversation_path.clone());
        self.state = WorkflowState::AwaitingChildReturn;
        let step = &self.spec.steps[active.step_index];
        Ok(vec![WorkflowAction::PollChild(ConversationPoll {
            dispatch_id: dispatch_id.to_owned(),
            adapter_id: step.target.adapter_id.clone(),
            conversation_path,
        })])
    }

    pub fn observe_child(
        &mut self,
        dispatch_id: &str,
        observed: ConversationReturn,
    ) -> Result<Vec<WorkflowAction>, WorkflowError> {
        if self.state != WorkflowState::AwaitingChildReturn {
            return Err(WorkflowError::InvalidTransition);
        }
        let active = self
            .active_child
            .as_ref()
            .ok_or(WorkflowError::InvalidTransition)?;
        if active.dispatch_id != dispatch_id {
            return Err(WorkflowError::DispatchMismatch);
        }
        let conversation_path = active
            .conversation_path
            .clone()
            .ok_or(WorkflowError::InvalidTransition)?;
        let step = &self.spec.steps[active.step_index];
        match observed {
            ConversationReturn::Pending => Ok(vec![WorkflowAction::PollChild(ConversationPoll {
                dispatch_id: dispatch_id.to_owned(),
                adapter_id: step.target.adapter_id.clone(),
                conversation_path,
            })]),
            ConversationReturn::Failed => {
                self.state = WorkflowState::Failed;
                Ok(Vec::new())
            }
            ConversationReturn::ReturnedToUser => {
                self.state = WorkflowState::ResumingMain;
                Ok(vec![WorkflowAction::ResumeMain(MainResume {
                    workflow_id: self.spec.workflow_id.clone(),
                    target: self.spec.main.target.clone(),
                    conversation_path: self.spec.main.conversation_path.clone(),
                    prompt: main_handoff_prompt(
                        &step.target.display_name,
                        &step.work_summary,
                        &conversation_path,
                    ),
                })])
            }
        }
    }

    pub fn main_resume_dispatched(&mut self) -> Result<Vec<WorkflowAction>, WorkflowError> {
        if self.state != WorkflowState::ResumingMain {
            return Err(WorkflowError::InvalidTransition);
        }
        self.state = WorkflowState::AwaitingMainReturn;
        Ok(vec![WorkflowAction::PollMain {
            adapter_id: self.spec.main.target.adapter_id.clone(),
            conversation_path: self.spec.main.conversation_path.clone(),
        }])
    }

    pub fn observe_main(
        &mut self,
        observed: ConversationReturn,
    ) -> Result<Vec<WorkflowAction>, WorkflowError> {
        if self.state != WorkflowState::AwaitingMainReturn {
            return Err(WorkflowError::InvalidTransition);
        }
        match observed {
            ConversationReturn::Pending => Ok(vec![WorkflowAction::PollMain {
                adapter_id: self.spec.main.target.adapter_id.clone(),
                conversation_path: self.spec.main.conversation_path.clone(),
            }]),
            ConversationReturn::Failed => {
                self.state = WorkflowState::Failed;
                Ok(Vec::new())
            }
            ConversationReturn::ReturnedToUser => {
                self.next_step = self.next_step.saturating_add(1);
                self.active_child = None;
                self.dispatch_next_child()
            }
        }
    }

    fn dispatch_next_child(&mut self) -> Result<Vec<WorkflowAction>, WorkflowError> {
        if self.next_step == self.spec.steps.len() {
            self.state = WorkflowState::Completed;
            return Ok(Vec::new());
        }
        self.state = WorkflowState::DispatchingChild;
        let step = self.spec.steps[self.next_step].clone();
        let dispatch_id = format!("{}:dispatch:{}", self.spec.workflow_id, self.next_dispatch);
        self.next_dispatch = self.next_dispatch.saturating_add(1);
        self.active_child = Some(ActiveChild {
            dispatch_id: dispatch_id.clone(),
            step_index: self.next_step,
            conversation_path: None,
        });
        Ok(vec![WorkflowAction::DispatchChild(ChildDispatch {
            dispatch_id,
            workflow_id: self.spec.workflow_id.clone(),
            step_id: step.id,
            role: step.role,
            target: step.target,
            prompt: child_handoff_prompt(step.role, &self.spec.main.conversation_path),
        })])
    }
}

fn child_handoff_prompt(role: WorkflowRole, conversation_path: &str) -> String {
    let role_label = match role {
        WorkflowRole::Designer => "Designer",
        WorkflowRole::Worker => "Worker",
        WorkflowRole::Reviewer => "Reviewer",
    };
    subordinate_role_prompt(
        role,
        &format!("请作为 {role_label} 继续工作，对话详情的地址是 {conversation_path}。"),
    )
}

/// Applies the same role contract to every subordinate framework. This is
/// transport-owned context, not a skill that the target agent must install.
pub fn subordinate_role_prompt(role: WorkflowRole, prompt: &str) -> String {
    if role != WorkflowRole::Reviewer {
        return prompt.to_owned();
    }
    format!(
        "{prompt}\n\nLicoUp 验收约束：如果本次工作包含智能体适配器、模型可用性或精确路由探测，必须使用 LicoUp 的一次性诊断探针；普通探测不指定模型，由本机实测价格表选择最低成本的可用模型。仅在验收精确路由本身时指定模型。严禁通过普通委派或原生发送创建 `Reply with exactly READY` 对话。只有探针对话已移入系统废纸篓，或者目标框架明确未持久化且复扫确认无记录时，才可判定通过；任何清理失败都必须判定验收失败。"
    )
}

fn main_handoff_prompt(agent_name: &str, work_summary: &str, conversation_path: &str) -> String {
    format!(
        "刚刚 {agent_name} 已经执行了 {work_summary} 工作，对话详情的地址是 {conversation_path}。"
    )
}

fn validate_spec(spec: &AgentWorkflowSpec) -> Result<(), WorkflowError> {
    if !valid_identifier(&spec.workflow_id)
        || spec.steps.len() < 3
        || spec.steps.len() > MAX_STEPS
        || !valid_target(&spec.main.target)
        || validate_conversation_path(&spec.main.conversation_path).is_err()
    {
        return Err(WorkflowError::InvalidSpec);
    }
    let mut ids = HashSet::with_capacity(spec.steps.len());
    for step in &spec.steps {
        if !valid_identifier(&step.id)
            || !ids.insert(step.id.as_str())
            || !valid_target(&step.target)
            || step.work_summary.trim().is_empty()
            || step.work_summary.len() > MAX_LABEL_BYTES
        {
            return Err(WorkflowError::InvalidSpec);
        }
    }
    if spec.steps.first().map(|step| step.role) != Some(WorkflowRole::Designer) {
        return Err(WorkflowError::InvalidSpec);
    }
    let lanes = &spec.steps[1..];
    if lanes.len() % 2 != 0
        || lanes.chunks_exact(2).any(|pair| {
            pair[0].role != WorkflowRole::Worker || pair[1].role != WorkflowRole::Reviewer
        })
    {
        return Err(WorkflowError::InvalidSpec);
    }
    Ok(())
}

fn valid_target(target: &AgentTarget) -> bool {
    valid_identifier(&target.adapter_id)
        && !target.display_name.trim().is_empty()
        && target.display_name.len() <= MAX_LABEL_BYTES
        && target.model.as_deref().is_none_or(valid_identifier)
        && target
            .reasoning_effort
            .as_deref()
            .is_none_or(valid_identifier)
}

fn validate_conversation_path(value: &str) -> Result<(), WorkflowError> {
    if value.is_empty()
        || value.len() > MAX_CONVERSATION_PATH_BYTES
        || value.contains('\0')
        || !std::path::Path::new(value).is_absolute()
    {
        Err(WorkflowError::ConversationPathInvalid)
    } else {
        Ok(())
    }
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_IDENTIFIER_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(adapter: &str, label: &str) -> AgentTarget {
        AgentTarget {
            adapter_id: adapter.into(),
            display_name: label.into(),
            model: Some("model-a".into()),
            reasoning_effort: Some("high".into()),
            working_directory: None,
        }
    }

    fn spec() -> AgentWorkflowSpec {
        AgentWorkflowSpec {
            workflow_id: "workflow-a".into(),
            main: MainConversation {
                target: target("codex", "Codex"),
                conversation_path: "/synthetic/main.jsonl".into(),
            },
            steps: [
                ("design", WorkflowRole::Designer, "Designer", "总体设计"),
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
            .map(|(id, role, label, summary)| WorkflowStep {
                id: id.into(),
                role,
                target: target("claude-code", label),
                work_summary: summary.into(),
            })
            .collect(),
        }
    }

    #[test]
    fn workflow_is_sequential_and_returns_to_main_between_children() {
        let mut workflow = AgentWorkflowLoop::new(spec()).unwrap();
        let mut actions = workflow.main_suspended().unwrap();
        for index in 0..5 {
            let WorkflowAction::DispatchChild(dispatch) = actions.remove(0) else {
                panic!("expected child dispatch");
            };
            let role_label = match dispatch.role {
                WorkflowRole::Designer => "Designer",
                WorkflowRole::Worker => "Worker",
                WorkflowRole::Reviewer => "Reviewer",
            };
            let base = format!(
                "请作为 {} 继续工作，对话详情的地址是 /synthetic/main.jsonl。",
                role_label
            );
            if dispatch.role == WorkflowRole::Reviewer {
                assert!(dispatch.prompt.starts_with(&base));
                assert!(dispatch.prompt.contains("本机实测价格表选择最低成本"));
                assert!(dispatch.prompt.contains("Reply with exactly READY"));
                assert!(dispatch.prompt.contains("任何清理失败都必须判定验收失败"));
            } else {
                assert_eq!(dispatch.prompt, base);
            }
            let path = format!("/synthetic/child-{index}.jsonl");
            workflow
                .child_dispatched(&dispatch.dispatch_id, path.clone())
                .unwrap();
            let resumed = workflow
                .observe_child(&dispatch.dispatch_id, ConversationReturn::ReturnedToUser)
                .unwrap();
            let WorkflowAction::ResumeMain(resume) = &resumed[0] else {
                panic!("expected main resume");
            };
            let step = &workflow.spec.steps[index];
            assert_eq!(
                resume.prompt,
                format!(
                    "刚刚 {} 已经执行了 {} 工作，对话详情的地址是 {path}。",
                    step.target.display_name, step.work_summary
                )
            );
            workflow.main_resume_dispatched().unwrap();
            actions = workflow
                .observe_main(ConversationReturn::ReturnedToUser)
                .unwrap();
        }
        assert!(actions.is_empty());
        assert_eq!(workflow.state(), WorkflowState::Completed);
    }

    #[test]
    fn pending_poll_does_not_advance() {
        let mut workflow = AgentWorkflowLoop::new(spec()).unwrap();
        let WorkflowAction::DispatchChild(dispatch) = workflow.main_suspended().unwrap().remove(0)
        else {
            panic!("expected dispatch");
        };
        workflow
            .child_dispatched(&dispatch.dispatch_id, "/synthetic/child.jsonl".into())
            .unwrap();
        assert!(matches!(
            workflow
                .observe_child(&dispatch.dispatch_id, ConversationReturn::Pending)
                .unwrap()[0],
            WorkflowAction::PollChild(_)
        ));
        assert_eq!(workflow.state(), WorkflowState::AwaitingChildReturn);
    }

    #[test]
    fn invalid_role_order_is_rejected() {
        let mut invalid = spec();
        invalid.steps[2].role = WorkflowRole::Designer;
        assert_eq!(
            AgentWorkflowLoop::new(invalid).unwrap_err(),
            WorkflowError::InvalidSpec
        );
    }

    #[test]
    fn codex_plugin_is_preferred_only_when_ready() {
        assert_eq!(
            select_orchestration_owner("codex", CodexPluginState::Ready),
            OrchestrationOwner::MainAgentPlugin
        );
        assert_eq!(
            select_orchestration_owner("codex", CodexPluginState::Missing),
            OrchestrationOwner::LicoUpFallback
        );
        assert_eq!(
            select_orchestration_owner("claude-code", CodexPluginState::Ready),
            OrchestrationOwner::LicoUpFallback
        );
    }

    #[test]
    fn every_framework_receives_the_same_acceptance_role_contract() {
        for adapter in [
            "claude-code",
            "cursor",
            "antigravity",
            "opencode",
            "copilot",
            "kilo-code",
            "hermes",
            "kimi-code",
            "pi",
            "codex",
        ] {
            let prompt =
                subordinate_role_prompt(WorkflowRole::Reviewer, &format!("review with {adapter}"));
            assert!(prompt.contains("LicoUp 验收约束"));
            assert!(prompt.contains("系统废纸篓"));
        }
        assert_eq!(
            subordinate_role_prompt(WorkflowRole::Worker, "implement"),
            "implement"
        );
        assert_eq!(
            WorkflowRole::parse("reviewer"),
            Some(WorkflowRole::Reviewer)
        );
        assert_eq!(WorkflowRole::parse("unknown"), None);
    }
}
