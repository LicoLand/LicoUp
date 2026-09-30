//! Current state of one data root, as the client's own owners report it.
//!
//! Nothing here is derived by this tool: the domain list, the target versions and every
//! observed version come from the client's migration owner. Reporting a locally invented
//! version would make the tool a second authority, which is exactly what the delivery
//! forbids.

use crate::error::{
    DATA_ROOT_MISSING, DATA_ROOT_NOT_DIRECTORY, FRONTIER_UNAVAILABLE, STATE_UNAVAILABLE, ToolError,
    ToolResult,
};
use serde::Serialize;
use std::path::Path;

/// One domain, as the client reports it.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DomainReport {
    pub domain_id: String,
    /// The domain's authoritative version, resolved by the client's own owner: the
    /// version its store reports when that store exists, otherwise the version its
    /// durable marker records, so a converted domain that owns no store file reports
    /// its marker's version rather than zero.
    pub store_version: u32,
    /// The marker's version when a marker exists.
    pub marker_schema_version: Option<u32>,
    /// The version the next migration edge moves from.
    pub effective_version: u32,
    /// The version the client's frontier declares as the current target.
    pub target_schema_version: u32,
    /// Whether the domain is already at its target.
    pub at_target: bool,
}

/// The whole observed state of one root.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InspectReport {
    pub status: &'static str,
    pub frontier_id: String,
    pub domains: Vec<DomainReport>,
    /// Domains whose stored state is ahead of this tool; a non-empty list is a refusal.
    pub newer_than_tool: Vec<String>,
}

/// Read one root through the client's own migration owner.
pub fn inspect(data_root: &Path) -> ToolResult<InspectReport> {
    if !data_root.exists() {
        return Err(DATA_ROOT_MISSING);
    }
    if !data_root.is_dir() {
        return Err(DATA_ROOT_NOT_DIRECTORY);
    }
    let frontier = licoup_native::domain::client_state_migration::frontier_projection_struct()
        .map_err(|_| FRONTIER_UNAVAILABLE)?;
    let states = licoup_native::domain::client_state_migration::domain_state_projection(data_root)
        .map_err(|_| STATE_UNAVAILABLE)?;

    let targets: std::collections::BTreeMap<&str, u32> = frontier
        .domains
        .iter()
        .map(|domain| (domain.domain_id.as_str(), domain.target_schema_version))
        .collect();

    let mut domains = Vec::with_capacity(states.len());
    let mut newer_than_tool = Vec::new();
    for state in &states {
        let Some(target) = targets.get(state.domain_id.as_str()).copied() else {
            continue;
        };
        if state.store_version > target {
            newer_than_tool.push(state.domain_id.clone());
        }
        domains.push(DomainReport {
            domain_id: state.domain_id.clone(),
            store_version: state.store_version,
            marker_schema_version: state.marker_schema_version,
            effective_version: state.effective_version,
            target_schema_version: target,
            at_target: state.effective_version == target,
        });
    }
    domains.sort_by(|left, right| left.domain_id.cmp(&right.domain_id));

    if !newer_than_tool.is_empty() {
        return Err(ToolError::new("state_newer_than_binary"));
    }

    Ok(InspectReport {
        status: "inspected",
        frontier_id: frontier.frontier_id,
        domains,
        newer_than_tool,
    })
}

/// The domains that still owe work on this root.
pub fn outstanding(report: &InspectReport) -> Vec<&DomainReport> {
    report
        .domains
        .iter()
        .filter(|domain| !domain.at_target)
        .collect()
}
