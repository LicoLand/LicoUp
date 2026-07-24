//! Local-only runtime skill invocation metering.
//!
//! The conversation adapter supplies privacy-minimal `skill.invoked` events.
//! This feature accepts no prompt or tool arguments and stores only one count
//! per UTC day, approved agent, and managed skill.

use super::{ClientStateStore, Result, Value};
use time::OffsetDateTime;

mod invocation;
mod ledger;
mod report;
#[cfg(test)]
mod tests;

pub(super) fn observe_conversation_result(
    store: &ClientStateStore,
    agent_id: &str,
    result: &Value,
) -> Result<Value> {
    observe_at(store, agent_id, result, OffsetDateTime::now_utc())
}

pub(super) fn report(store: &ClientStateStore, params: &Value) -> Result<Value> {
    report::report(store, params)
}

fn observe_at(
    store: &ClientStateStore,
    agent_id: &str,
    result: &Value,
    occurred_at: OffsetDateTime,
) -> Result<Value> {
    let counts = invocation::invocation_counts(result);
    ledger::record_counts(store, agent_id, counts, occurred_at)
}
