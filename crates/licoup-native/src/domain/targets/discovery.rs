use super::catalog::{TargetCandidate, TargetDef, target_def, target_defs};
use super::manual::{ManualTarget, manual_targets, manual_targets_read_only};
use super::parameters::target_param;
use super::probe_pool::{run_bounded_target_probes, target_scan_concurrency};
use super::processes::ScanContext;
use super::scan_merge::{scan_target_read_only_with_manual, scan_target_with_manual};
use super::support::{client_state_store, client_state_store_read_only};
use super::target_cache::{persist_discovery_cache, upsert_discovery_cache};
use super::virtual_machine_discovery::{AutomaticVmTarget, discover_virtual_machine_targets};
use crate::platform::client_state::ClientStateStore;
use anyhow::Result;
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Clone, Debug)]
struct TargetProbe {
    def: TargetDef,
    manual: Option<ManualTarget>,
    automatic_vm: Option<AutomaticVmTarget>,
    scan_context: ScanContext,
    params: Value,
}

pub(super) fn scan_targets() -> Result<Value> {
    scan_targets_with_params(&json!({}))
}

pub(super) fn scan_targets_with_params(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    scan_targets_with_store(params, &store)
}

pub(super) fn scan_targets_with_store(params: &Value, store: &ClientStateStore) -> Result<Value> {
    let manual_targets = manual_targets(store)?;
    let manual_by_target = manual_targets
        .into_iter()
        .map(|target| (target.target.clone(), target))
        .collect::<BTreeMap<_, _>>();
    let process_snapshot = ScanContext::snapshot_from_params(params);
    let definitions = target_defs();
    let requested_targets = definitions.iter().map(|def| def.id).collect::<Vec<_>>();
    let automatic_vm = discover_virtual_machine_targets(params, &requested_targets);
    let probes = definitions
        .into_iter()
        .map(|def| TargetProbe {
            manual: manual_by_target.get(def.id).cloned(),
            automatic_vm: automatic_vm.targets.get(def.id).cloned(),
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
            probe.automatic_vm.as_ref(),
            &mut probe.scan_context,
            &probe.params,
        )
    })?;
    persist_discovery_cache(store, &candidates)?;
    let mut scan_scopes = vec![
        "application-store",
        "package-manager",
        "executable-path",
        "local-configuration",
        "running-process",
    ];
    if automatic_vm.scope_available {
        scan_scopes.push("virtual-machine-orbstack");
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": 1,
        "source": "target-adapters",
        "scanScopes": scan_scopes,
        "diagnostics": automatic_vm.diagnostics,
        "candidates": candidates,
    }))
}

pub(super) fn inspect_target(target: &str) -> Result<Value> {
    inspect_target_with_params(&json!({ "target": target }))
}

pub(super) fn inspect_target_read_only(target: &str) -> Result<Value> {
    inspect_target_read_only_with_params(&json!({ "target": target }))
}

pub(super) fn inspect_target_read_only_with_params(params: &Value) -> Result<Value> {
    let mut params = params.clone();
    if let Some(object) = params.as_object_mut() {
        object.insert("disableAgentCliModelLookup".to_string(), json!(true));
        object.insert("enableAgentCliModelLookup".to_string(), json!(false));
        object.insert("probeConversationRuntime".to_string(), json!(false));
        object.insert("includeHistoryModelCatalog".to_string(), json!(false));
        object.insert("includeAccessibleEnvironments".to_string(), json!(false));
    }
    inspect_target_inner(&params, true)
}

pub(super) fn inspect_target_with_params(params: &Value) -> Result<Value> {
    inspect_target_inner(params, false)
}

fn inspect_target_inner(params: &Value, read_only: bool) -> Result<Value> {
    let target = target_param(params)?;
    let def = target_def(&target)?;
    let store = if read_only {
        client_state_store_read_only(params)?
    } else {
        client_state_store(params)?
    };
    let manual_targets = if read_only {
        manual_targets_read_only(&store)?
    } else {
        manual_targets(&store)?
    };
    let manual = manual_targets.iter().find(|item| item.target == def.id);
    let automatic_vm = discover_virtual_machine_targets(params, &[def.id]);
    let mut scan_context = ScanContext::from_params(params);
    let candidate = if read_only {
        scan_target_read_only_with_manual(
            &def,
            manual,
            automatic_vm.targets.get(def.id),
            &mut scan_context,
            params,
        )?
    } else {
        scan_target_with_manual(
            &def,
            manual,
            automatic_vm.targets.get(def.id),
            &mut scan_context,
            params,
        )?
    };
    if !read_only {
        upsert_discovery_cache(&store, &candidate)?;
    }
    let target = if read_only {
        read_only_target_projection(&candidate)
    } else {
        serde_json::to_value(candidate)?
    };
    Ok(json!({
        "ok": true,
        "diagnostics": automatic_vm.diagnostics,
        "target": target
    }))
}

fn read_only_target_projection(candidate: &TargetCandidate) -> Value {
    json!({
        "target": candidate.target,
        "status": candidate.status,
        "adapterCapabilities": {
            "conversationDriver": candidate.adapter_capabilities.conversation_driver,
            "conversationReadiness": candidate.adapter_capabilities.conversation_readiness,
            "conversationBlocker": candidate.adapter_capabilities.conversation_blocker,
        },
        "supportedActions": candidate.supported_actions,
    })
}
