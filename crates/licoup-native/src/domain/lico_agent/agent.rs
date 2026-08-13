use super::events::AgentEvent;
use super::loop_::run_turn;
use super::profiles::{base_system_prompt, plan_system_prompt};
use super::tools::{ToolRegistry, read_tool, write_plan_tool};
use super::transport::LlmTransport;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentProfileKind {
    Base,
    Plan,
}

impl AgentProfileKind {
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "base" | "agent" => Some(Self::Base),
            "plan" => Some(Self::Plan),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Base => "base",
            Self::Plan => "plan",
        }
    }
}

pub struct AgentConfig {
    pub profile: AgentProfileKind,
    pub model: String,
    pub workspace: PathBuf,
    pub plan_path: Option<PathBuf>,
}

pub struct Agent {
    config: AgentConfig,
    transport: Arc<dyn LlmTransport>,
    tools: ToolRegistry,
    history: Vec<Value>,
    abort: AtomicBool,
}

impl Agent {
    pub fn new(config: AgentConfig, transport: Arc<dyn LlmTransport>) -> Result<Self, String> {
        let mut tools = ToolRegistry::new();
        tools.register(read_tool(config.workspace.clone()));
        if config.profile == AgentProfileKind::Plan {
            let plan = config
                .plan_path
                .clone()
                .ok_or_else(|| "plan_path_required".to_string())?;
            tools.register(write_plan_tool(plan));
        }
        Ok(Self {
            config,
            transport,
            tools,
            history: Vec::new(),
            abort: AtomicBool::new(false),
        })
    }

    pub fn inject_history(&mut self, messages: Vec<Value>) {
        self.history = messages;
    }

    pub fn history(&self) -> &[Value] {
        &self.history
    }

    pub fn profile(&self) -> AgentProfileKind {
        self.config.profile
    }

    pub fn abort(&self) {
        self.abort.store(true, Ordering::SeqCst);
    }

    pub fn prompt(
        &mut self,
        user_text: &str,
        mut on_event: impl FnMut(AgentEvent),
    ) -> Result<(), String> {
        self.abort.store(false, Ordering::SeqCst);
        on_event(AgentEvent::AgentStart);
        let user = json!({"role": "user", "content": user_text});
        on_event(AgentEvent::MessageStart {
            role: "user".into(),
        });
        on_event(AgentEvent::MessageEnd {
            role: "user".into(),
            content: user_text.to_string(),
        });
        self.history.push(user);
        let system = match self.config.profile {
            AgentProfileKind::Base => base_system_prompt(),
            AgentProfileKind::Plan => plan_system_prompt(),
        };
        let result = run_turn(
            self.transport.as_ref(),
            &self.config.model,
            system,
            &mut self.history,
            &self.tools,
            &self.abort,
            &mut on_event,
        );
        on_event(AgentEvent::AgentEnd);
        result
    }
}
