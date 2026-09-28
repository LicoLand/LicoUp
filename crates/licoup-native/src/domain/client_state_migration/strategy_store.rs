use anyhow::{Context, Result, anyhow, bail, ensure};
use rusqlite::{Connection, OptionalExtension};
use std::path::Path;

use super::strategy_store_artifact::{self, Event, State};
use super::{AuthoritativeProbe, MigrationEdge, stores};

fn read_store_state(root: &Path) -> Result<Option<State>> {
    let path = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
    if !stores::regular_file_present(&path)? {
        return Ok(None);
    }
    let connection = Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .context("unsupported_state_shape")?;
    let value: Option<String> = connection
        .query_row(
            "SELECT value FROM strategy_meta WHERE key='version'",
            [],
            |row| row.get(0),
        )
        .optional()
        .context("unsupported_state_shape")?;
    match value.as_deref() {
        Some("3") => Ok(Some(State::Current)),
        Some("2") => Ok(Some(State::WorkflowRouted)),
        Some(value) if value.parse::<u32>().is_ok_and(|value| value < 2) => Ok(Some(State::Legacy)),
        Some(value) if value.parse::<u32>().is_ok_and(|value| value > 3) => {
            bail!("state_newer_than_binary")
        }
        _ => bail!("unsupported_state_shape"),
    }
}

pub(super) fn probe(root: &Path) -> Result<AuthoritativeProbe> {
    let state = read_store_state(root)?;
    let version = match state {
        Some(State::Legacy) => 0,
        Some(State::WorkflowRouted) => 1,
        Some(State::Current) => 2,
        None => 0,
    };
    Ok(AuthoritativeProbe {
        version,
        present: state.is_some(),
    })
}

pub(super) fn apply(root: &Path, edge: &MigrationEdge) -> Result<()> {
    let Some(state) = read_store_state(root)? else {
        return Ok(());
    };
    let target = match edge.to_schema_version {
        1 => State::WorkflowRouted,
        2 => State::Current,
        _ => bail!("migration_frontier_incomplete"),
    };
    let transition = strategy_store_artifact::TRANSITIONS
        .iter()
        .find(|transition| transition.from == state && transition.to == target)
        .copied()
        .ok_or_else(|| anyhow!("migration_frontier_incomplete"))?;
    ensure!(
        strategy_store_artifact::transition(state, transition.event) == Some(target),
        "migration_frontier_incomplete"
    );
    match transition.event {
        Event::NormalizeStore => {
            crate::domain::workflow_store::StrategyStore::migrate_to_schema_2(root)
                .context("migration_step_failed")?;
        }
        Event::MaterializeWorkflowRouting => {
            crate::domain::workflow_store::StrategyStore::open_for_migration(root)
                .map(drop)
                .context("migration_step_failed")?;
        }
    }
    Ok(())
}
