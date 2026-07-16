use super::catalog::{TargetDef, target_def, target_defs};
use super::manual::{ManualTarget, manual_targets};
use super::parameters::target_param;
use super::probe_pool::{run_bounded_target_probes, target_scan_concurrency};
use super::processes::ScanContext;
use super::scan_merge::scan_target_with_manual;
use super::support::client_state_store;
use super::target_cache::{persist_discovery_cache, upsert_discovery_cache};
use anyhow::Result;
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
struct TargetProbe {
    def: TargetDef,
    manual: Option<ManualTarget>,
    scan_context: ScanContext,
    params: Value,
}

pub(super) fn scan_targets() -> Result<Value> {
    scan_targets_with_params(&json!({}))
}

pub(super) fn scan_targets_with_params(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let manual_targets = manual_targets(&store)?;
    let manual_by_target = manual_targets
        .into_iter()
        .map(|target| (target.target.clone(), target))
        .collect::<BTreeMap<_, _>>();
    let process_snapshot = ScanContext::snapshot_from_params(params);
    let probes = target_defs()
        .into_iter()
        .map(|def| TargetProbe {
            manual: manual_by_target.get(def.id).cloned(),
            def,
            scan_context: process_snapshot.clone(),
            params: params.clone(),
        })
        .collect::<Vec<_>>();
    let concurrency = target_scan_concurrency(params, probes.len());
    let candidates = run_bounded_target_probes(probes, concurrency, |mut probe| {
        scan_target_with_manual(
            &probe.def,
            probe.manual.as_ref(),
            &mut probe.scan_context,
            &probe.params,
        )
    })?;
    persist_discovery_cache(&store, &candidates)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": 1,
        "source": "target-adapters",
        "scanScopes": ["application-store", "package-manager", "executable-path", "local-configuration", "running-process"],
        "diagnostics": [],
        "candidates": candidates,
    }))
}

pub(super) fn inspect_target(target: &str) -> Result<Value> {
    inspect_target_with_params(&json!({ "target": target }))
}

pub(super) fn inspect_target_with_params(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    let def = target_def(&target)?;
    let store = client_state_store(params)?;
    let manual_targets = manual_targets(&store)?;
    let manual = manual_targets.iter().find(|item| item.target == def.id);
    let mut scan_context = ScanContext::from_params(params);
    let candidate = scan_target_with_manual(&def, manual, &mut scan_context, params)?;
    upsert_discovery_cache(&store, &candidate)?;
    Ok(json!({
        "ok": true,
        "target": candidate
    }))
}
