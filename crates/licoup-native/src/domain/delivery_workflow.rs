//! Current-generation LicoUp-owned delivery coordinator.

use crate::domain::{
    agent_usage::workflow_ledger,
    delivery_plan::{
        DeliveryPlanEngine, DispatchBinding, DispatchPhase, NextAction, Plan, PlanError, PlanPhase,
        Role, RoleBrief, TaskStatus,
    },
    subagent_handoff::{self, HandoffRecord, HandoffState, SessionMode, UsageSettlementState},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::hash_map::DefaultHasher,
    fmt,
    hash::{Hash, Hasher},
    path::{Path, PathBuf},
    sync::{LazyLock, Mutex},
};

pub const DELIVERY_SCHEMA_VERSION: &str = "licoup.delivery-workflow.v1";
pub const DELIVERY_AUTHORITY: &str = "licoup";
pub const ROUTE_SELECTION_AUTHORITY: &str = "adaptive-flywheel";
pub const MAX_WORKFLOW_ID_BYTES: usize = 256;
pub const MAX_ROUTE_FIELD_BYTES: usize = 256;
const WORKFLOW_TERMINAL_LOCK_STRIPES: usize = 64;

static WORKFLOW_TERMINAL_LOCKS: LazyLock<[Mutex<()>; WORKFLOW_TERMINAL_LOCK_STRIPES]> =
    LazyLock::new(|| std::array::from_fn(|_| Mutex::new(())));

fn workflow_terminal_lock(workflow_id: &str) -> &'static Mutex<()> {
    let mut hasher = DefaultHasher::new();
    workflow_id.hash(&mut hasher);
    &WORKFLOW_TERMINAL_LOCKS[hasher.finish() as usize % WORKFLOW_TERMINAL_LOCK_STRIPES]
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryError {
    pub code: String,
    pub stage: String,
    pub component: String,
    pub retryable: bool,
    pub recovery: String,
}

impl DeliveryError {
    pub fn new(
        code: impl Into<String>,
        stage: impl Into<String>,
        component: impl Into<String>,
        retryable: bool,
        recovery: impl Into<String>,
    ) -> Self {
        Self {
            code: code.into(),
            stage: stage.into(),
            component: component.into(),
            retryable,
            recovery: recovery.into(),
        }
    }

    pub fn invalid(code: &'static str, stage: &'static str) -> Self {
        Self::new(
            code,
            stage,
            "delivery-workflow",
            false,
            "correct_request_and_retry",
        )
    }

    pub fn public_value(&self) -> Value {
        json!({
            "code": self.code,
            "stage": self.stage,
            "component": self.component,
            "retryable": self.retryable,
            "recovery": self.recovery,
        })
    }
}

impl fmt::Display for DeliveryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.code)
    }
}

impl std::error::Error for DeliveryError {}

pub type DeliveryResult<T> = Result<T, DeliveryError>;

impl From<PlanError> for DeliveryError {
    fn from(error: PlanError) -> Self {
        let stage = format!("{:?}", error.stage).to_ascii_lowercase();
        Self::new(
            error.code,
            stage,
            "delivery-plan",
            false,
            "correct_plan_and_retry",
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Difficulty {
    Standard,
    Complex,
}

impl Difficulty {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Standard => "standard",
            Self::Complex => "complex",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RouteReceipt {
    pub role: Role,
    pub difficulty: Difficulty,
    pub agent_id: String,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub authority: String,
}

impl RouteReceipt {
    pub fn validate(&self) -> DeliveryResult<()> {
        if self.authority != ROUTE_SELECTION_AUTHORITY
            || !valid_identifier(&self.agent_id)
            || self
                .model
                .as_deref()
                .is_some_and(|value| !valid_identifier(value))
            || self
                .reasoning_effort
                .as_deref()
                .is_some_and(|value| !valid_identifier(value))
        {
            return Err(DeliveryError::new(
                "route_selection_invalid",
                "route-selection",
                "adaptive-flywheel",
                false,
                "repair_adaptive_route_and_retry",
            ));
        }
        Ok(())
    }

    pub fn frozen_value(&self) -> Value {
        json!({
            "authority": self.authority,
            "role": self.role,
            "difficulty": self.difficulty,
            "agentId": self.agent_id,
            "model": self.model,
            "reasoningEffort": self.reasoning_effort,
        })
    }
}

pub trait RouteSelector: Send + Sync {
    fn select(
        &self,
        role: Role,
        difficulty: Difficulty,
        plan: &Plan,
        task_code: Option<&str>,
    ) -> DeliveryResult<RouteReceipt>;
}

#[derive(Clone, Debug, Default)]
pub struct AdaptiveFlywheelRouteSelector {
    pub state: Value,
}

impl AdaptiveFlywheelRouteSelector {
    pub fn from_state(state: Value) -> Self {
        Self { state }
    }

    pub fn from_client_state() -> DeliveryResult<Self> {
        let state = crate::platform::client_state::state_get(
            crate::ffi::generated::client_state::ClientStateGetRequest {
                collection:
                    crate::ffi::generated::client_state::ClientStateCollection::AdaptiveFlywheel,
            },
        )
        .map_err(|_| {
            DeliveryError::new(
                "route_selection_unavailable",
                "route-selection",
                "adaptive-flywheel",
                true,
                "repair_adaptive_route_and_retry",
            )
        })?;
        Ok(Self::from_state(Value::Object(
            state.document.content.into_iter().collect(),
        )))
    }
}

impl RouteSelector for AdaptiveFlywheelRouteSelector {
    fn select(
        &self,
        role: Role,
        difficulty: Difficulty,
        _plan: &Plan,
        _task_code: Option<&str>,
    ) -> DeliveryResult<RouteReceipt> {
        let role_key = role_name(role);
        let root = self
            .state
            .get("delivery_routes")
            .or_else(|| self.state.get("deliveryRoutes"))
            .or_else(|| self.state.get("routes"))
            .or_else(|| {
                self.state
                    .get("adaptive_flywheel")
                    .and_then(|value| value.get("delivery_routes"))
            })
            .or_else(|| self.state.get("code_engineering"))
            .or_else(|| {
                self.state
                    .get("adaptive_flywheel")
                    .and_then(|value| value.get("code_engineering"))
            });
        let role_value = root.and_then(|value| value.get(role_key));
        let routes = role_value
            .and_then(|value| value.get(difficulty.as_str()))
            .or_else(|| {
                role_value.and_then(|value| {
                    value
                        .get("agents")
                        .and_then(Value::as_array)
                        .and_then(|agents| {
                            let wants_fast = difficulty == Difficulty::Standard;
                            agents
                                .iter()
                                .find(|agent| {
                                    agent.get("fast").and_then(Value::as_bool) == Some(wants_fast)
                                })
                                .or_else(|| agents.first())
                        })
                })
            })
            .or(role_value)
            .and_then(Value::as_object)
            .ok_or_else(|| {
                DeliveryError::new(
                    "route_selection_unavailable",
                    "route-selection",
                    "adaptive-flywheel",
                    true,
                    "configure_adaptive_route_and_retry",
                )
            })?;
        let agent_id = routes
            .get("agentId")
            .or_else(|| routes.get("agent"))
            .or_else(|| routes.get("agent_id"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                DeliveryError::new(
                    "route_selection_invalid",
                    "route-selection",
                    "adaptive-flywheel",
                    false,
                    "repair_adaptive_route_and_retry",
                )
            })?;
        let receipt = RouteReceipt {
            role,
            difficulty,
            agent_id: agent_id.to_owned(),
            model: routes
                .get("model")
                .or_else(|| routes.get("modelName"))
                .or_else(|| routes.get("model_name"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
            reasoning_effort: routes
                .get("reasoningEffort")
                .or_else(|| routes.get("reasoning_effort"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
            authority: ROUTE_SELECTION_AUTHORITY.to_owned(),
        };
        receipt.validate()?;
        Ok(receipt)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdmittedConversation {
    pub agent_id: String,
    pub session_id: String,
    pub source_path: String,
    pub working_directory: String,
    pub binding: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DispatchResult {
    pub conversation: AdmittedConversation,
    pub terminal: TerminalState,
    pub usage: Value,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalState {
    Pending,
    Completed,
    Failed,
    Cancelled,
}

impl TerminalState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Clone, Debug)]
pub struct DispatchRequest {
    pub workflow_id: String,
    pub dispatch_id: String,
    pub role: Role,
    pub task_code: Option<String>,
    pub attempt: u32,
    pub route: RouteReceipt,
    pub brief: RoleBrief,
    pub parent_conversation: Option<AdmittedConversation>,
    pub conversation: AdmittedConversation,
    pub working_directory: String,
}

pub trait DeliveryExecutor: Send + Sync {
    fn prepare_conversation(
        &self,
        agent_id: &str,
        working_directory: &str,
        existing: Option<&str>,
    ) -> DeliveryResult<AdmittedConversation>;
    fn dispatch(&self, request: &DispatchRequest) -> DeliveryResult<DispatchResult>;
    fn reconcile(&self, conversation: &AdmittedConversation) -> DeliveryResult<TerminalState>;
    fn cancel(&self, conversation: &AdmittedConversation) -> DeliveryResult<()>;
    fn usage_snapshot(&self, conversation: &AdmittedConversation) -> DeliveryResult<Value>;
}

#[derive(Clone, Debug)]
pub struct SchedulerConfig {
    pub state_root: PathBuf,
    pub manager_agent_id: String,
    pub manager_location: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduleReport {
    pub dispatched: usize,
    pub completed: usize,
    pub failed: usize,
    pub pending: usize,
}

pub struct DeliveryScheduler<'a, R, E>
where
    R: RouteSelector,
    E: DeliveryExecutor,
{
    pub workflow_id: String,
    pub engine: DeliveryPlanEngine,
    pub selector: &'a R,
    pub executor: &'a E,
    pub config: SchedulerConfig,
}

impl<'a, R, E> DeliveryScheduler<'a, R, E>
where
    R: RouteSelector,
    E: DeliveryExecutor,
{
    pub fn new(
        workflow_id: impl Into<String>,
        engine: DeliveryPlanEngine,
        selector: &'a R,
        executor: &'a E,
        config: SchedulerConfig,
    ) -> Self {
        Self {
            workflow_id: workflow_id.into(),
            engine,
            selector,
            executor,
            config,
        }
    }

    pub fn drive(&mut self) -> DeliveryResult<ScheduleReport> {
        let terminal_lock = workflow_terminal_lock(&self.workflow_id);
        let _terminal_guard = terminal_lock
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        self.drive_locked()
    }

    fn drive_locked(&mut self) -> DeliveryResult<ScheduleReport> {
        let mut report = ScheduleReport::default();
        if self.engine.next_action().map_err(DeliveryError::from)? == NextAction::Cancelled {
            self.reconcile_cancelled_ledger()?;
            return Ok(report);
        }
        self.ensure_delivery_root()?;
        self.reconcile_pending(&mut report)?;
        match self.engine.next_action().map_err(DeliveryError::from)? {
            NextAction::Designer => self.dispatch_designer(&mut report)?,
            NextAction::Worker { .. } => {
                // The Plan authority supplies the complete eligible frontier on
                // every pass; callers cannot submit a partial frontier.
                for task in self.engine.eligible_tasks().map_err(DeliveryError::from)? {
                    self.dispatch_worker(&task, &mut report)?;
                }
            }
            NextAction::Reviewer => self.dispatch_reviewer(&mut report)?,
            NextAction::AwaitingAcceptance { .. }
            | NextAction::None
            | NextAction::Completed
            | NextAction::Blocked
            | NextAction::Cancelled => {}
        }
        match self.engine.next_action().map_err(DeliveryError::from)? {
            NextAction::Completed => self.finish_delivery_ledger("completed")?,
            NextAction::Blocked => self.finish_delivery_ledger("failed")?,
            NextAction::Cancelled => self.finish_delivery_ledger("cancelled")?,
            _ => {}
        }
        Ok(report)
    }

    fn reconcile_cancelled_ledger(&self) -> DeliveryResult<()> {
        let report = workflow_ledger::workflow_report(&json!({
            "workflowId": self.workflow_id,
            "stateRoot": self.config.state_root,
        }))
        .map_err(|error| {
            DeliveryError::new(
                error.code,
                "settlement",
                "workflow-ledger",
                error.retryable,
                error.recovery,
            )
        })?;
        let state = report
            .get("workflows")
            .and_then(Value::as_array)
            .and_then(|workflows| workflows.first())
            .and_then(|workflow| workflow.get("state"))
            .and_then(Value::as_str);
        match state {
            Some("cancelled") => Ok(()),
            Some("active") => self.finish_delivery_ledger("cancelled"),
            Some(_) => Err(DeliveryError::new(
                "usage_ledger_terminal_state_conflict",
                "settlement",
                "workflow-ledger",
                true,
                "reconcile_terminal_state_before_retry",
            )),
            None => {
                self.ensure_delivery_root()?;
                self.finish_delivery_ledger("cancelled")
            }
        }
    }

    fn ensure_delivery_root(&self) -> DeliveryResult<()> {
        let location = self
            .config
            .manager_location
            .as_deref()
            .or_else(|| {
                self.engine
                    .checkpoints()
                    .designer
                    .as_ref()
                    .and_then(|session| session.conversation_location.as_deref())
            })
            .ok_or_else(|| {
                DeliveryError::invalid("conversation_location_missing", "conversation-admission")
            })?;
        let manager = self.executor.prepare_conversation(
            &self.config.manager_agent_id,
            "",
            Some(location),
        )?;
        let baseline_usage = self.executor.usage_snapshot(&manager)?;
        let params = json!({
            "workflowId": self.workflow_id,
            "planCode": self.engine.plan().code,
            "planRevision": self.engine.checkpoints().revision,
            "managerAgentId": self.config.manager_agent_id,
            "managerConversationBinding": manager.binding,
            "stateRoot": self.config.state_root,
        });
        workflow_ledger::begin_delivery(&params).map_err(|error| {
            DeliveryError::new(
                error.code,
                "ledger-prepare",
                "workflow-ledger",
                error.retryable,
                error.recovery,
            )
        })?;
        let mut baseline = params;
        baseline["nodeId"] = json!(format!("{}:root", self.workflow_id));
        baseline["dispatchId"] = json!(format!("{}:root", self.workflow_id));
        baseline["phase"] = json!("main");
        baseline["role"] = json!("main");
        baseline["attempt"] = json!(0);
        baseline["agentId"] = json!(self.config.manager_agent_id);
        baseline["conversationBinding"] = json!(manager.binding);
        baseline["lineageScope"] = json!(manager.binding);
        baseline["sessionMode"] = json!("resume");
        baseline["source"] = json!("cumulative");
        baseline["baseline"] = baseline_usage;
        workflow_ledger::bind_conversation_baseline(&baseline).map_err(|error| {
            DeliveryError::new(
                error.code,
                "ledger-prepare",
                "workflow-ledger",
                error.retryable,
                error.recovery,
            )
        })?;
        Ok(())
    }

    fn finish_delivery_ledger(&self, state: &str) -> DeliveryResult<()> {
        let location = self
            .config
            .manager_location
            .as_deref()
            .or_else(|| {
                self.engine
                    .checkpoints()
                    .designer
                    .as_ref()
                    .and_then(|session| session.conversation_location.as_deref())
            })
            .ok_or_else(|| {
                DeliveryError::invalid("conversation_location_missing", "conversation-admission")
            })?;
        let manager = self.executor.prepare_conversation(
            &self.config.manager_agent_id,
            "",
            Some(location),
        )?;
        let usage = self.executor.usage_snapshot(&manager)?;
        workflow_ledger::settle_turn(&json!({
            "workflowId": self.workflow_id,
            "nodeId": format!("{}:root", self.workflow_id),
            "conversationBinding": manager.binding,
            "source": "cumulative",
            "usage": usage,
            "stateRoot": self.config.state_root,
        }))
        .map_err(|error| {
            DeliveryError::new(
                error.code,
                "settlement",
                "workflow-ledger",
                error.retryable,
                error.recovery,
            )
        })?;
        let terminal = workflow_ledger::mark_terminal(&json!({
            "workflowId": self.workflow_id,
            "state": state,
            "terminalCorrelation": format!("delivery:{}", self.workflow_id),
            "stateRoot": self.config.state_root,
        }))
        .map_err(|error| {
            DeliveryError::new(
                error.code,
                "settlement",
                "workflow-ledger",
                error.retryable,
                error.recovery,
            )
        })?;
        if terminal.get("state").and_then(Value::as_str) != Some(state) {
            return Err(DeliveryError::new(
                "usage_ledger_terminal_state_conflict",
                "settlement",
                "workflow-ledger",
                true,
                "reconcile_terminal_state_before_retry",
            ));
        }
        Ok(())
    }

    fn dispatch_designer(&mut self, report: &mut ScheduleReport) -> DeliveryResult<()> {
        let session = self
            .engine
            .checkpoints()
            .designer
            .as_ref()
            .ok_or_else(|| DeliveryError::invalid("designer_not_open", "designer"))?;
        if session.completed || self.pending_role(Role::Designer) {
            return Ok(());
        }
        let location = session.conversation_location.as_deref().ok_or_else(|| {
            DeliveryError::invalid("conversation_location_missing", "conversation-admission")
        })?;
        let route = self.selector.select(
            Role::Designer,
            Difficulty::Complex,
            self.engine.plan(),
            None,
        )?;
        let parent = self.executor.prepare_conversation(
            &self.config.manager_agent_id,
            "",
            Some(location),
        )?;
        let brief = RoleBrief {
            role: Role::Designer,
            authority: "delivery-plan.designer".to_owned(),
            selected_decisions: Vec::new(),
            direct_inputs: Vec::new(),
            task: None,
            review: None,
            execution_policy: self.engine.plan().execution_policy.clone(),
            repository_references: self.engine.plan().references.clone(),
            native_conversation_location: Some(parent.source_path.clone()),
        };
        self.dispatch_one(
            format!("{}:designer:1", self.workflow_id),
            Role::Designer,
            None,
            1,
            route,
            brief,
            parent,
            report,
        )
    }

    fn dispatch_worker(
        &mut self,
        task_code: &str,
        report: &mut ScheduleReport,
    ) -> DeliveryResult<()> {
        if self.pending_task(task_code) {
            return Ok(());
        }
        let task = self
            .engine
            .plan()
            .tasks
            .iter()
            .find(|task| task.code == task_code)
            .ok_or_else(|| DeliveryError::invalid("unknown_task", "eligibility"))?;
        let difficulty = if task.contract.len() > 512 || task.requirements.len() > 2 {
            Difficulty::Complex
        } else {
            Difficulty::Standard
        };
        let route = self.selector.select(
            Role::Worker,
            difficulty,
            self.engine.plan(),
            Some(task_code),
        )?;
        let location = self.config.manager_location.as_deref().ok_or_else(|| {
            DeliveryError::invalid("conversation_location_missing", "conversation-admission")
        })?;
        let parent = self.executor.prepare_conversation(
            &self.config.manager_agent_id,
            "",
            Some(location),
        )?;
        let brief = self
            .engine
            .compile_task_brief(task_code, Some(parent.source_path.clone()))
            .map_err(DeliveryError::from)?;
        let attempt = self
            .engine
            .checkpoints()
            .dispatches
            .values()
            .filter(|dispatch| dispatch.task_code.as_deref() == Some(task_code))
            .map(|dispatch| dispatch.attempt)
            .max()
            .unwrap_or(0)
            .saturating_add(1);
        let dispatch_id = format!("{}:task:{}:{}", self.workflow_id, task_code, attempt);
        self.engine
            .bind_dispatch(DispatchBinding {
                id: dispatch_id.clone(),
                task_code: task_code.to_owned(),
                attempt,
                conversation_location: None,
                receipt: Some(route.frozen_value().to_string()),
            })
            .map_err(DeliveryError::from)?;
        self.dispatch_one(
            dispatch_id,
            Role::Worker,
            Some(task_code.to_owned()),
            attempt,
            route,
            brief,
            parent,
            report,
        )
    }

    fn dispatch_reviewer(&mut self, report: &mut ScheduleReport) -> DeliveryResult<()> {
        if self.engine.checkpoints().reviewer.is_none() {
            let location = self.config.manager_location.clone().ok_or_else(|| {
                DeliveryError::invalid("conversation_location_missing", "conversation-admission")
            })?;
            self.engine
                .open_reviewer(location)
                .map_err(DeliveryError::from)?;
        }
        let session = self
            .engine
            .checkpoints()
            .reviewer
            .as_ref()
            .ok_or_else(|| DeliveryError::invalid("reviewer_not_open", "reviewer"))?;
        if session.completed || self.pending_role(Role::Reviewer) {
            return Ok(());
        }
        let location = session.conversation_location.as_deref().ok_or_else(|| {
            DeliveryError::invalid("conversation_location_missing", "conversation-admission")
        })?;
        let route = self.selector.select(
            Role::Reviewer,
            Difficulty::Complex,
            self.engine.plan(),
            None,
        )?;
        let parent = self.executor.prepare_conversation(
            &self.config.manager_agent_id,
            "",
            Some(location),
        )?;
        let brief = self
            .engine
            .compile_reviewer_brief(Some(parent.source_path.clone()))
            .map_err(DeliveryError::from)?;
        self.dispatch_one(
            format!("{}:reviewer:1", self.workflow_id),
            Role::Reviewer,
            None,
            1,
            route,
            brief,
            parent,
            report,
        )
    }

    fn dispatch_one(
        &mut self,
        dispatch_id: String,
        role: Role,
        task_code: Option<String>,
        attempt: u32,
        route: RouteReceipt,
        mut brief: RoleBrief,
        parent: AdmittedConversation,
        report: &mut ScheduleReport,
    ) -> DeliveryResult<()> {
        route.validate()?;
        if role != Role::Worker {
            self.engine
                .bind_role_dispatch(role, &dispatch_id)
                .map_err(DeliveryError::from)?;
        }
        let child =
            self.executor
                .prepare_conversation(&route.agent_id, &parent.working_directory, None)?;
        let child_baseline = self.executor.usage_snapshot(&child)?;
        brief.native_conversation_location = Some(child.source_path.clone());
        let mut handoff = HandoffRecord::new_delivery(
            dispatch_id.clone(),
            "delivery.dispatch",
            self.engine.plan().code.clone(),
            self.engine.checkpoints().revision,
            task_code.clone(),
            Some(role_name(role).to_owned()),
            self.config.manager_agent_id.clone(),
            route.agent_id.clone(),
            role_name(role),
            attempt as u64,
            SessionMode::New,
            Some(parent.binding.clone()),
            Some(child.binding.clone()),
            Some(format!("{}:{}", self.workflow_id, role_name(role))),
            self.config.manager_location.clone(),
        );
        handoff.conversation_path = Some(child.source_path.clone());
        let portable = crate::platform::paths::portable_data_dir().map_err(|_| {
            DeliveryError::new(
                "handoff_store_unavailable",
                "dispatch",
                "subagent-handoff",
                true,
                "retry_after_store_recovers",
            )
        })?;
        subagent_handoff::persist_handoff(&portable, &handoff).map_err(|_| {
            DeliveryError::new(
                "handoff_store_unavailable",
                "dispatch",
                "subagent-handoff",
                true,
                "retry_after_store_recovers",
            )
        })?;

        let ledger_params = json!({
            "workflowId": self.workflow_id,
            "planCode": self.engine.plan().code,
            "planRevision": self.engine.checkpoints().revision,
            "managerAgentId": self.config.manager_agent_id,
            "managerConversationBinding": parent.binding,
            "stateRoot": self.config.state_root,
        });
        workflow_ledger::begin_delivery(&ledger_params).map_err(|error| {
            DeliveryError::new(
                error.code,
                "ledger-prepare",
                "workflow-ledger",
                error.retryable,
                error.recovery,
            )
        })?;
        let node_id = format!("{}:{}", self.workflow_id, dispatch_id);
        let mut baseline = ledger_params;
        baseline["nodeId"] = json!(node_id);
        baseline["parentNodeId"] = json!(format!("{}:root", self.workflow_id));
        baseline["taskCode"] = json!(task_code);
        baseline["phase"] = json!(role_name(role));
        baseline["dispatchId"] = json!(dispatch_id);
        baseline["role"] = json!(role_name(role));
        baseline["attempt"] = json!(attempt);
        baseline["agentId"] = json!(route.agent_id);
        baseline["model"] = json!(route.model);
        baseline["conversationBinding"] = json!(child.binding);
        baseline["lineageScope"] = json!(format!("{}:{}", self.workflow_id, role_name(role)));
        baseline["sessionMode"] = json!("new");
        baseline["baseline"] = child_baseline;
        workflow_ledger::bind_conversation_baseline(&baseline).map_err(|error| {
            DeliveryError::new(
                error.code,
                "ledger-prepare",
                "workflow-ledger",
                error.retryable,
                error.recovery,
            )
        })?;

        let result = self.executor.dispatch(&DispatchRequest {
            workflow_id: self.workflow_id.clone(),
            dispatch_id: handoff.dispatch_id.clone(),
            role,
            task_code: task_code.clone(),
            attempt,
            route,
            brief,
            parent_conversation: Some(parent),
            conversation: child.clone(),
            working_directory: child.working_directory.clone(),
        })?;
        match result.terminal {
            TerminalState::Pending => {
                handoff.state = HandoffState::Running;
                handoff.usage_settlement = UsageSettlementState::Ready;
                report.pending += 1;
            }
            TerminalState::Completed | TerminalState::Failed | TerminalState::Cancelled => {
                self.finish(&mut handoff, result, report)?;
            }
        }
        subagent_handoff::persist_handoff(&portable, &handoff).map_err(|_| {
            DeliveryError::new(
                "handoff_store_unavailable",
                "dispatch",
                "subagent-handoff",
                true,
                "retry_after_store_recovers",
            )
        })?;
        report.dispatched += 1;
        Ok(())
    }

    fn finish(
        &mut self,
        handoff: &mut HandoffRecord,
        result: DispatchResult,
        report: &mut ScheduleReport,
    ) -> DeliveryResult<()> {
        let node_id = format!("{}:{}", self.workflow_id, handoff.dispatch_id);
        // A pending native turn commonly has no usage in its later catalog
        // terminal projection. Read the exact admitted conversation instead
        // of silently settling a zero-valued synthetic terminal event.
        let usage = if result.usage.is_object()
            && workflow_ledger::NormalizedUsage::from_value(&result.usage).is_some()
        {
            result.usage
        } else {
            self.executor.usage_snapshot(&result.conversation)?
        };
        let mut settle = json!({
            "workflowId": self.workflow_id,
            "nodeId": node_id,
            "conversationBinding": result.conversation.binding,
            "usage": usage,
            "stateRoot": self.config.state_root,
        });
        if result.terminal == TerminalState::Cancelled {
            settle["reconcile"] = json!(true);
        }
        workflow_ledger::settle_turn(&settle).map_err(|error| {
            DeliveryError::new(
                error.code,
                "settlement",
                "workflow-ledger",
                error.retryable,
                error.recovery,
            )
        })?;
        handoff.state = match result.terminal {
            TerminalState::Completed => HandoffState::Completed,
            TerminalState::Failed => HandoffState::Failed,
            TerminalState::Cancelled => HandoffState::CancelRequested,
            TerminalState::Pending => HandoffState::Running,
        };
        handoff.usage_settlement = UsageSettlementState::Settled;
        handoff.conversation_path = Some(result.conversation.source_path);
        if result.terminal == TerminalState::Failed {
            handoff.error_code = Some("native_terminal_failed".to_owned());
        }
        match handoff.role.as_str() {
            "designer" if result.terminal == TerminalState::Completed => {
                let already_completed = self
                    .engine
                    .checkpoints()
                    .designer
                    .as_ref()
                    .is_some_and(|session| session.completed);
                if !already_completed {
                    self.engine
                        .complete_designer(Some("native-terminal".to_owned()))
                        .map_err(DeliveryError::from)?;
                    self.engine.mark_ready().map_err(DeliveryError::from)?;
                }
            }
            "worker" if result.terminal == TerminalState::Completed => {
                let task = handoff
                    .task_code
                    .as_deref()
                    .ok_or_else(|| DeliveryError::invalid("dispatch_task_missing", "acceptance"))?;
                let running = self
                    .engine
                    .checkpoints()
                    .dispatches
                    .get(&handoff.dispatch_id)
                    .is_some_and(|dispatch| {
                        matches!(
                            dispatch.phase,
                            DispatchPhase::WorkerRunning | DispatchPhase::WorkerCorrection
                        )
                    });
                if running {
                    self.engine
                        .complete_dispatch(&handoff.dispatch_id, Vec::new())
                        .map_err(DeliveryError::from)?;
                }
                let already_accepted = self
                    .engine
                    .checkpoints()
                    .tasks
                    .get(task)
                    .is_some_and(|checkpoint| checkpoint.status == TaskStatus::Completed);
                if !already_accepted {
                    self.engine
                        .accept_task(
                            task,
                            &handoff.dispatch_id,
                            Some("native-terminal".to_owned()),
                        )
                        .map_err(DeliveryError::from)?;
                }
            }
            "worker" if result.terminal == TerminalState::Failed => {
                let needs_failure = self
                    .engine
                    .checkpoints()
                    .dispatches
                    .get(&handoff.dispatch_id)
                    .is_some_and(|dispatch| {
                        matches!(
                            dispatch.phase,
                            DispatchPhase::WorkerRunning | DispatchPhase::WorkerCorrection
                        )
                    });
                if needs_failure {
                    let _ = self.engine.fail_dispatch(
                        &handoff.dispatch_id,
                        "native_terminal_failed",
                        true,
                    );
                }
            }
            "reviewer" if result.terminal == TerminalState::Completed => {
                let already_completed = self
                    .engine
                    .checkpoints()
                    .reviewer
                    .as_ref()
                    .is_some_and(|session| session.completed);
                if !already_completed {
                    self.engine
                        .complete_reviewer(Some("native-terminal".to_owned()))
                        .map_err(DeliveryError::from)?;
                }
            }
            _ => {}
        }
        report.completed += usize::from(result.terminal == TerminalState::Completed);
        report.failed += usize::from(result.terminal == TerminalState::Failed);
        Ok(())
    }

    fn pending_task(&self, task_code: &str) -> bool {
        self.engine
            .checkpoints()
            .dispatches
            .values()
            .any(|dispatch| {
                dispatch.task_code.as_deref() == Some(task_code)
                    && dispatch.phase != DispatchPhase::WorkerCorrection
                    && dispatch.id.starts_with(&format!("{}:", self.workflow_id))
            })
    }

    fn pending_role(&self, role: Role) -> bool {
        let session = match role {
            Role::Designer => self.engine.checkpoints().designer.as_ref(),
            Role::Reviewer => self.engine.checkpoints().reviewer.as_ref(),
            Role::Worker => None,
        };
        session.is_some_and(|session| !session.completed && session.receipt.is_some())
    }

    fn reconcile_pending(&mut self, report: &mut ScheduleReport) -> DeliveryResult<()> {
        let portable = crate::platform::paths::portable_data_dir().map_err(|_| {
            DeliveryError::new(
                "handoff_store_unavailable",
                "recovery",
                "subagent-handoff",
                true,
                "retry_after_store_recovers",
            )
        })?;
        for mut handoff in subagent_handoff::list_handoffs(&portable).map_err(|_| {
            DeliveryError::new(
                "handoff_store_unavailable",
                "recovery",
                "subagent-handoff",
                true,
                "retry_after_store_recovers",
            )
        })? {
            if handoff.plan_code != self.engine.plan().code
                || !handoff
                    .dispatch_id
                    .starts_with(&format!("{}:", self.workflow_id))
                || !matches!(
                    handoff.state,
                    HandoffState::Accepted | HandoffState::Running
                )
            {
                continue;
            }
            let Some(path) = handoff.conversation_path.clone() else {
                continue;
            };
            let conversation =
                self.executor
                    .prepare_conversation(&handoff.agent_id, "", Some(&path))?;
            let terminal = self.executor.reconcile(&conversation)?;
            if terminal == TerminalState::Pending {
                report.pending += 1;
            } else {
                let result = DispatchResult {
                    conversation,
                    terminal,
                    usage: json!({}),
                };
                self.finish(&mut handoff, result, report)?;
                subagent_handoff::persist_handoff(&portable, &handoff).map_err(|_| {
                    DeliveryError::new(
                        "handoff_store_unavailable",
                        "recovery",
                        "subagent-handoff",
                        true,
                        "retry_after_store_recovers",
                    )
                })?;
            }
        }
        Ok(())
    }
}

pub fn start(params: &Value) -> DeliveryResult<Value> {
    let workflow_id = workflow_id(params)?;
    let terminal_lock = workflow_terminal_lock(&workflow_id);
    let _terminal_guard = terminal_lock
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let root = plan_root(params)?;
    let mut engine = if root.join(crate::domain::delivery_plan::PLAN_FILE).is_file() {
        DeliveryPlanEngine::load(&root)?
    } else {
        let plan = params
            .get("plan")
            .cloned()
            .ok_or_else(|| DeliveryError::invalid("plan_missing", "start"))?;
        let plan: Plan = serde_json::from_value(plan)
            .map_err(|_| DeliveryError::invalid("plan_invalid", "start"))?;
        DeliveryPlanEngine::create(&root, plan)?
    };
    ensure_not_cancelled(&engine)?;
    if let Some(decisions) = params
        .get("decisions")
        .or_else(|| params.get("decisionSelections"))
        .and_then(Value::as_object)
    {
        let selected: std::collections::BTreeMap<String, String> = decisions
            .iter()
            .filter_map(|(key, value)| value.as_str().map(|value| (key.clone(), value.to_owned())))
            .collect();
        if !selected.is_empty() && !engine.checkpoints().dossier_resolved {
            engine.resolve_dossier(selected)?;
        }
    }
    if engine.checkpoints().designer.is_none()
        && engine.checkpoints().dossier_resolved
        && let Some(location) = params
            .get("mainConversationLocation")
            .or_else(|| params.get("conversationLocation"))
            .and_then(Value::as_str)
    {
        engine.open_designer(location.to_owned())?;
    }
    let status = engine.status()?;
    Ok(json!({
        "schemaVersion": DELIVERY_SCHEMA_VERSION,
        "operation": "delivery.start",
        "workflowId": workflow_id,
        "planCode": status.plan_code,
        "planRevision": status.revision,
        "phase": status.phase,
        "nextAction": status.next_action,
        "deliveryAuthority": DELIVERY_AUTHORITY,
        "routeSelectionAuthority": ROUTE_SELECTION_AUTHORITY,
        "accepted": true
    }))
}

pub fn authorize(params: &Value) -> DeliveryResult<Value> {
    let workflow_id = workflow_id(params)?;
    let terminal_lock = workflow_terminal_lock(&workflow_id);
    let _terminal_guard = terminal_lock
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let mut engine = load_engine(params)?;
    ensure_not_cancelled(&engine)?;
    let expected = params
        .get("semanticDigest")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| DeliveryError::invalid("authorization_digest_missing", "authorization"))?;
    let actual = engine.semantic_digest()?;
    if actual != expected {
        return Err(DeliveryError::invalid(
            "authorization_digest_mismatch",
            "authorization",
        ));
    }
    let digest = if engine.checkpoints().phase == PlanPhase::Authorized {
        let sealed = engine
            .checkpoints()
            .semantic_digest
            .as_deref()
            .ok_or_else(|| DeliveryError::invalid("authorization_not_sealed", "authorization"))?;
        if sealed != expected {
            return Err(DeliveryError::invalid(
                "authorization_digest_mismatch",
                "authorization",
            ));
        }
        sealed.to_owned()
    } else {
        engine.mark_ready()?;
        engine.authorize()?
    };
    Ok(json!({
        "schemaVersion": DELIVERY_SCHEMA_VERSION,
        "operation": "delivery.authorize",
        "workflowId": workflow_id,
        "planRevision": engine.checkpoints().revision,
        "semanticDigest": digest,
        "deliveryAuthority": DELIVERY_AUTHORITY,
        "routeSelectionAuthority": ROUTE_SELECTION_AUTHORITY,
        "authorized": true
    }))
}

pub fn status(params: &Value) -> DeliveryResult<Value> {
    let id = workflow_id(params)?;
    let terminal_lock = workflow_terminal_lock(&id);
    let _terminal_guard = terminal_lock
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let status = load_engine(params)?.status()?;
    Ok(json!({
        "schemaVersion": DELIVERY_SCHEMA_VERSION,
        "operation": "delivery.status",
        "workflowId": id,
        "planCode": status.plan_code,
        "planRevision": status.revision,
        "phase": status.phase,
        "semanticDigest": status.semantic_digest,
        "tasks": status.tasks,
        "nextAction": status.next_action,
        "deliveryAuthority": DELIVERY_AUTHORITY,
        "routeSelectionAuthority": ROUTE_SELECTION_AUTHORITY
    }))
}

pub fn cancel(params: &Value) -> DeliveryResult<Value> {
    let id = workflow_id(params)?;
    let terminal_lock = workflow_terminal_lock(&id);
    let _terminal_guard = terminal_lock
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    let mut engine = load_engine(params)?;
    // Persist the single-file checkpoint terminal gate first. A ledger error
    // therefore leaves delivery fail-closed and retryable; a repeated request
    // completes the idempotent ledger transition without rescheduling work.
    engine.cancel()?;
    let ledger_terminal = workflow_ledger::mark_terminal(&json!({
        "workflowId": id,
        "state": "cancelled",
        "terminalCorrelation": format!("cancel:{}", id),
        "stateRoot": params.get("stateRoot").cloned().unwrap_or(Value::Null)
    }))
    .map_err(|error| {
        let missing = error.code == "usage_ledger_delivery_not_found";
        DeliveryError::new(
            error.code,
            error.stage,
            "workflow-ledger",
            error.retryable || missing,
            if missing {
                "initialize_delivery_ledger_then_retry_cancel".to_owned()
            } else {
                error.recovery
            },
        )
    })?;
    // `mark_terminal` is intentionally idempotent and returns the previously
    // committed state.  Cancellation may only advance the Plan when that
    // state is also cancelled; otherwise the two authorities would diverge.
    if ledger_terminal.get("state").and_then(Value::as_str) != Some("cancelled") {
        return Err(DeliveryError::new(
            "usage_ledger_terminal_state_conflict",
            "usage-ledger-terminal",
            "workflow-ledger",
            true,
            "reconcile_terminal_state_before_retry",
        ));
    }
    Ok(json!({
        "schemaVersion": DELIVERY_SCHEMA_VERSION,
        "operation": "delivery.cancel",
        "workflowId": id,
        "state": "cancelled",
        "deliveryAuthority": DELIVERY_AUTHORITY,
        "routeSelectionAuthority": ROUTE_SELECTION_AUTHORITY,
        "cancelRequested": true
    }))
}

fn ensure_not_cancelled(engine: &DeliveryPlanEngine) -> DeliveryResult<()> {
    if engine.checkpoints().cancellation_requested {
        return Err(DeliveryError::new(
            "delivery_cancelled",
            "lifecycle",
            "delivery-plan",
            false,
            "inspect_cancelled_delivery",
        ));
    }
    Ok(())
}

fn load_engine(params: &Value) -> DeliveryResult<DeliveryPlanEngine> {
    DeliveryPlanEngine::load(plan_root(params)?).map_err(DeliveryError::from)
}

fn workflow_id(params: &Value) -> DeliveryResult<String> {
    ["workflowId", "deliveryId", "id"]
        .iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| value.len() <= MAX_WORKFLOW_ID_BYTES && valid_identifier(value))
        .map(str::to_owned)
        .ok_or_else(|| DeliveryError::invalid("workflow_id_missing", "request"))
}

fn plan_root(params: &Value) -> DeliveryResult<PathBuf> {
    let raw = ["planRoot", "root", "directory"]
        .iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .ok_or_else(|| DeliveryError::invalid("plan_root_missing", "request"))?;
    let path = Path::new(raw);
    if !path.is_absolute() || !path.is_dir() {
        return Err(DeliveryError::invalid("plan_root_invalid", "request"));
    }
    Ok(path.to_path_buf())
}

fn role_name(role: Role) -> &'static str {
    match role {
        Role::Designer => "designer",
        Role::Worker => "worker",
        Role::Reviewer => "reviewer",
    }
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_ROUTE_FIELD_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::{
        Arc, Barrier,
        atomic::{AtomicUsize, Ordering},
    };
    use std::thread;

    fn test_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "licoup-delivery-workflow-{label}-{}",
            uuid::Uuid::new_v4()
        ))
    }

    #[derive(Default)]
    struct CountingRouteSelector(AtomicUsize);

    impl RouteSelector for CountingRouteSelector {
        fn select(
            &self,
            _role: Role,
            _difficulty: Difficulty,
            _plan: &Plan,
            _task_code: Option<&str>,
        ) -> DeliveryResult<RouteReceipt> {
            self.0.fetch_add(1, Ordering::Relaxed);
            Err(DeliveryError::invalid(
                "cancelled_runner_selected_route",
                "route-selection",
            ))
        }
    }

    #[derive(Default)]
    struct CountingExecutor {
        native_calls: AtomicUsize,
    }

    impl DeliveryExecutor for CountingExecutor {
        fn prepare_conversation(
            &self,
            _agent_id: &str,
            _working_directory: &str,
            _existing: Option<&str>,
        ) -> DeliveryResult<AdmittedConversation> {
            self.native_calls.fetch_add(1, Ordering::Relaxed);
            Err(DeliveryError::invalid(
                "cancelled_runner_prepared_conversation",
                "conversation-admission",
            ))
        }

        fn dispatch(&self, _request: &DispatchRequest) -> DeliveryResult<DispatchResult> {
            self.native_calls.fetch_add(1, Ordering::Relaxed);
            Err(DeliveryError::invalid(
                "cancelled_runner_dispatched",
                "dispatch",
            ))
        }

        fn reconcile(&self, _conversation: &AdmittedConversation) -> DeliveryResult<TerminalState> {
            self.native_calls.fetch_add(1, Ordering::Relaxed);
            Err(DeliveryError::invalid(
                "cancelled_runner_reconciled",
                "recovery",
            ))
        }

        fn cancel(&self, _conversation: &AdmittedConversation) -> DeliveryResult<()> {
            self.native_calls.fetch_add(1, Ordering::Relaxed);
            Ok(())
        }

        fn usage_snapshot(&self, _conversation: &AdmittedConversation) -> DeliveryResult<Value> {
            self.native_calls.fetch_add(1, Ordering::Relaxed);
            Ok(json!({
                "promptTokens": 0,
                "cachedInputTokens": 0,
                "completionTokens": 0,
                "totalTokens": 0
            }))
        }
    }

    fn reviewer_ready_engine(root: &Path) -> DeliveryPlanEngine {
        let mut engine =
            DeliveryPlanEngine::create(root, Plan::new("PLAN-TERMINAL-RACE", "Terminal race"))
                .unwrap();
        engine.resolve_dossier(Default::default()).unwrap();
        engine.open_designer("native/designer/race").unwrap();
        engine.complete_designer(None).unwrap();
        engine.mark_ready().unwrap();
        engine.authorize().unwrap();
        engine.open_reviewer("native/reviewer/race").unwrap();
        engine
    }

    #[test]
    fn route_receipt_is_adaptive_and_path_free() {
        let selector = AdaptiveFlywheelRouteSelector::from_state(json!({
            "delivery_routes": {
                "worker": {"standard": {"agent": "claude-code", "model": "standard", "reasoning_effort": "medium"}},
                "designer": {"agent": "codex", "model": "complex"},
                "reviewer": {"agent": "pi", "model": "review"}
            }
        }));
        let route = selector
            .select(
                Role::Worker,
                Difficulty::Standard,
                &Plan::new("P", "synthetic"),
                None,
            )
            .unwrap();
        assert_eq!(route.agent_id, "claude-code");
        assert_eq!(route.authority, ROUTE_SELECTION_AUTHORITY);
        assert!(!route.frozen_value().to_string().contains('/'));
    }

    #[test]
    fn current_adaptive_flywheel_agents_select_standard_and_complex_routes() {
        let selector = AdaptiveFlywheelRouteSelector::from_state(json!({
            "code_engineering": {
                "worker": {
                    "agents": [
                        {"agent": "fast-worker", "model": "fast-model", "fast": true},
                        {"agent": "deep-worker", "model": "deep-model", "fast": false}
                    ]
                }
            }
        }));
        let plan = Plan::new("PLAN-ROUTE-001", "route");
        let standard = selector
            .select(Role::Worker, Difficulty::Standard, &plan, None)
            .unwrap();
        let complex = selector
            .select(Role::Worker, Difficulty::Complex, &plan, None)
            .unwrap();
        assert_eq!(standard.agent_id, "fast-worker");
        assert_eq!(complex.agent_id, "deep-worker");
        assert_eq!(standard.authority, ROUTE_SELECTION_AUTHORITY);
        assert_eq!(complex.authority, ROUTE_SELECTION_AUTHORITY);
    }

    #[test]
    fn public_errors_do_not_contain_paths_or_content() {
        let error = DeliveryError::new(
            "conversation_location_ambiguous",
            "conversation-admission",
            "native-catalog",
            false,
            "choose_one_exact_location",
        );
        let rendered = error.public_value().to_string();
        assert!(!rendered.contains('/'));
        assert!(!rendered.contains("prompt"));
    }

    #[test]
    fn cancellation_uses_custom_ledger_root_and_terminalizes_before_success() {
        let plan_root = test_root("cancel-custom-plan");
        let state_root = test_root("cancel-custom-state");
        fs::create_dir_all(&state_root).unwrap();
        let engine = DeliveryPlanEngine::create(
            &plan_root,
            Plan::new("PLAN-CANCEL-CUSTOM", "Cancel custom ledger"),
        )
        .unwrap();
        let semantic_digest = engine.semantic_digest().unwrap();
        workflow_ledger::begin_delivery(&json!({
            "workflowId": "workflow-cancel-custom",
            "planCode": "PLAN-CANCEL-CUSTOM",
            "planRevision": engine.checkpoints().revision,
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();

        let response = cancel(&json!({
            "workflowId": "workflow-cancel-custom",
            "planRoot": plan_root.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();
        assert_eq!(response["state"], "cancelled");
        let reloaded = DeliveryPlanEngine::load(&plan_root).unwrap();
        assert!(reloaded.checkpoints().cancellation_requested);
        assert_eq!(reloaded.next_action().unwrap(), NextAction::Cancelled);
        assert_eq!(reloaded.semantic_digest().unwrap(), semantic_digest);
        let status = status(&json!({
            "workflowId": "workflow-cancel-custom",
            "planRoot": plan_root.to_string_lossy()
        }))
        .unwrap();
        assert_eq!(status["nextAction"], "cancelled");
        let start_error = start(&json!({
            "workflowId": "workflow-cancel-custom",
            "planRoot": plan_root.to_string_lossy()
        }))
        .unwrap_err();
        assert_eq!(start_error.code, "delivery_cancelled");
        let authorize_error = authorize(&json!({
            "workflowId": "workflow-cancel-custom",
            "planRoot": plan_root.to_string_lossy(),
            "semanticDigest": semantic_digest
        }))
        .unwrap_err();
        assert_eq!(authorize_error.code, "delivery_cancelled");
        let report = workflow_ledger::workflow_report(&json!({
            "workflowId": "workflow-cancel-custom",
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();
        assert_eq!(report["workflows"][0]["state"], "cancelled");

        let selector = CountingRouteSelector::default();
        let executor = CountingExecutor::default();
        let mut scheduler = DeliveryScheduler::new(
            "workflow-cancel-custom",
            DeliveryPlanEngine::load(&plan_root).unwrap(),
            &selector,
            &executor,
            SchedulerConfig {
                state_root: state_root.clone(),
                manager_agent_id: "main-agent".to_owned(),
                manager_location: Some("native/main/cancelled".to_owned()),
            },
        );
        assert_eq!(scheduler.drive().unwrap(), ScheduleReport::default());
        assert_eq!(selector.0.load(Ordering::Relaxed), 0);
        assert_eq!(executor.native_calls.load(Ordering::Relaxed), 0);
        let _ = fs::remove_dir_all(plan_root);
        let _ = fs::remove_dir_all(state_root);
    }

    #[test]
    fn ledger_terminal_failure_is_returned_and_plan_remains_retryable() {
        let plan_root = test_root("cancel-ledger-failure-plan");
        let state_root = test_root("cancel-ledger-failure-state");
        fs::create_dir_all(&state_root).unwrap();
        DeliveryPlanEngine::create(
            &plan_root,
            Plan::new("PLAN-CANCEL-FAILURE", "Cancel ledger failure"),
        )
        .unwrap();

        let error = cancel(&json!({
            "workflowId": "workflow-cancel-failure",
            "planRoot": plan_root.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap_err();
        assert_eq!(error.code, "usage_ledger_delivery_not_found");
        assert_eq!(error.component, "workflow-ledger");
        assert!(error.retryable);
        let reloaded = DeliveryPlanEngine::load(&plan_root).unwrap();
        assert!(reloaded.checkpoints().cancellation_requested);
        assert_eq!(reloaded.next_action().unwrap(), NextAction::Cancelled);

        workflow_ledger::begin_delivery(&json!({
            "workflowId": "workflow-cancel-failure",
            "planCode": "PLAN-CANCEL-FAILURE",
            "planRevision": reloaded.checkpoints().revision,
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();
        let recovered = cancel(&json!({
            "workflowId": "workflow-cancel-failure",
            "planRoot": plan_root.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();
        assert_eq!(recovered["state"], "cancelled");
        let _ = fs::remove_dir_all(plan_root);
        let _ = fs::remove_dir_all(state_root);
    }

    #[test]
    fn cancellation_rejects_a_conflicting_existing_ledger_terminal_state() {
        let plan_root = test_root("cancel-terminal-conflict-plan");
        let state_root = test_root("cancel-terminal-conflict-state");
        fs::create_dir_all(&state_root).unwrap();
        let engine = DeliveryPlanEngine::create(
            &plan_root,
            Plan::new("PLAN-CANCEL-CONFLICT", "Cancel terminal conflict"),
        )
        .unwrap();
        workflow_ledger::begin_delivery(&json!({
            "workflowId": "workflow-cancel-conflict",
            "planCode": "PLAN-CANCEL-CONFLICT",
            "planRevision": engine.checkpoints().revision,
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();
        workflow_ledger::mark_terminal(&json!({
            "workflowId": "workflow-cancel-conflict",
            "state": "completed",
            "terminalCorrelation": "complete:workflow-cancel-conflict",
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();

        let error = cancel(&json!({
            "workflowId": "workflow-cancel-conflict",
            "planRoot": plan_root.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap_err();
        assert_eq!(error.code, "usage_ledger_terminal_state_conflict");
        assert_eq!(error.component, "workflow-ledger");
        assert!(error.retryable);
        let reloaded = DeliveryPlanEngine::load(&plan_root).unwrap();
        assert!(reloaded.checkpoints().cancellation_requested);
        assert_eq!(reloaded.next_action().unwrap(), NextAction::Cancelled);
        let _ = fs::remove_dir_all(plan_root);
        let _ = fs::remove_dir_all(state_root);
    }

    #[test]
    fn concurrent_terminal_callback_and_cancel_commit_one_matching_terminal() {
        let plan_root = test_root("terminal-race-plan");
        let state_root = test_root("terminal-race-state");
        fs::create_dir_all(&state_root).unwrap();
        let engine = reviewer_ready_engine(&plan_root);
        workflow_ledger::begin_delivery(&json!({
            "workflowId": "workflow-terminal-race",
            "planCode": engine.plan().code,
            "planRevision": engine.checkpoints().revision,
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();

        // Hold the same striped authority used by scheduler callbacks and
        // cancellation while a real cancellation request waits. Completion
        // commits Plan+ledger first, so cancellation deterministically loses.
        let terminal_guard = workflow_terminal_lock("workflow-terminal-race")
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let barrier = Arc::new(Barrier::new(2));
        let cancel_barrier = Arc::clone(&barrier);
        let cancel_plan_root = plan_root.clone();
        let cancel_state_root = state_root.clone();
        let cancel_thread = thread::spawn(move || {
            cancel_barrier.wait();
            cancel(&json!({
                "workflowId": "workflow-terminal-race",
                "planRoot": cancel_plan_root.to_string_lossy(),
                "stateRoot": cancel_state_root.to_string_lossy()
            }))
        });
        barrier.wait();
        let mut completed = DeliveryPlanEngine::load(&plan_root).unwrap();
        completed
            .complete_reviewer(Some("native-terminal".to_owned()))
            .unwrap();
        workflow_ledger::mark_terminal(&json!({
            "workflowId": "workflow-terminal-race",
            "state": "completed",
            "terminalCorrelation": "delivery:workflow-terminal-race",
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();
        drop(terminal_guard);

        let cancel_error = cancel_thread.join().unwrap().unwrap_err();
        assert_eq!(cancel_error.code, "already_completed");
        let reloaded = DeliveryPlanEngine::load(&plan_root).unwrap();
        assert_eq!(reloaded.next_action().unwrap(), NextAction::Completed);
        assert!(!reloaded.checkpoints().cancellation_requested);
        let report = workflow_ledger::workflow_report(&json!({
            "workflowId": "workflow-terminal-race",
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();
        assert_eq!(report["workflows"][0]["state"], "completed");
        let _ = fs::remove_dir_all(plan_root);
        let _ = fs::remove_dir_all(state_root);
    }

    #[test]
    fn cancellation_winner_rejects_a_late_terminal_callback() {
        let plan_root = test_root("cancel-wins-plan");
        let state_root = test_root("cancel-wins-state");
        fs::create_dir_all(&state_root).unwrap();
        let engine = reviewer_ready_engine(&plan_root);
        workflow_ledger::begin_delivery(&json!({
            "workflowId": "workflow-cancel-wins",
            "planCode": engine.plan().code,
            "planRevision": engine.checkpoints().revision,
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();
        cancel(&json!({
            "workflowId": "workflow-cancel-wins",
            "planRoot": plan_root.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();

        let mut callback = DeliveryPlanEngine::load(&plan_root).unwrap();
        let callback_error = callback
            .complete_reviewer(Some("late-native-terminal".to_owned()))
            .unwrap_err();
        assert_eq!(callback_error.code(), "delivery_cancelled");
        let report = workflow_ledger::workflow_report(&json!({
            "workflowId": "workflow-cancel-wins",
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();
        assert_eq!(report["workflows"][0]["state"], "cancelled");
        let _ = fs::remove_dir_all(plan_root);
        let _ = fs::remove_dir_all(state_root);
    }
}
