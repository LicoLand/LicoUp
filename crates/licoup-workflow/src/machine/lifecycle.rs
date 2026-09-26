//! Declarative lifecycle execution for workflow runs and commands.
//!
//! Reducer guards and effects stay in the parent module. This module is the
//! single bridge from those decisions to the generated transition tables.

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};

use super::Machine;
use crate::state_machines::{workflow_command, workflow_run};

pub(super) use workflow_command::Event as CommandEvent;
pub use workflow_command::State as CommandStatus;
pub(super) use workflow_run::Event as RunEvent;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CommandKind {
    Authorization,
    Actor,
    Script,
    WorksetItem,
}

impl Machine<'_> {
    pub(super) fn apply_run_event(&mut self, event: RunEvent) -> Result<()> {
        let next = workflow_run::transition(self.snapshot.status, event)
            .ok_or_else(|| anyhow!("strategy_run_transition_conflict"))?;
        self.snapshot.status = next;
        Ok(())
    }

    pub(super) fn apply_command_event(
        &mut self,
        command_id: &str,
        event: CommandEvent,
    ) -> Result<()> {
        let Some(command) = self.snapshot.commands.get_mut(command_id) else {
            return Err(anyhow!("strategy_callback_stale"));
        };
        let next = workflow_command::transition(command.status, event)
            .ok_or_else(|| anyhow!("strategy_callback_conflict"))?;
        command.status = next;
        if !self
            .delta
            .settled_commands
            .iter()
            .any(|settled| settled == command_id)
        {
            self.delta.settled_commands.push(command_id.to_owned());
        }
        Ok(())
    }
}
