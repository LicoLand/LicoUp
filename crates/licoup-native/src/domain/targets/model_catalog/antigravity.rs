use super::*;
use crate::platform::run_bounded_command_output;
use std::time::Duration;

const DEFAULT_AGENT_CLI_MODEL_LOOKUP_TIMEOUT_MS: u64 = 3_000;
const MIN_AGENT_CLI_MODEL_LOOKUP_TIMEOUT_MS: u64 = 100;
const MAX_AGENT_CLI_MODEL_LOOKUP_TIMEOUT_MS: u64 = 10_000;
const MAX_AGENT_CLI_MODEL_LOOKUP_OUTPUT_BYTES: usize = 256 * 1024;

pub(super) fn collect_antigravity_cli_model_catalog(
    params: &Value,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    let source = "antigravity-cli:models";
    if param_bool(params, "disableAgentCliModelLookup").unwrap_or(false)
        || param_bool(params, "disableAntigravityCliModelLookup").unwrap_or(false)
    {
        diagnostics.push(json!({
            "source": source,
            "status": "disabled",
        }));
        return;
    }
    if cfg!(test) && !param_bool(params, "enableAgentCliModelLookup").unwrap_or(false) {
        diagnostics.push(json!({
            "source": source,
            "status": "disabled-in-tests",
        }));
        return;
    }

    let program = param_string(params, "antigravityCliPath")
        .or_else(|| param_string(params, "agyPath"))
        .or_else(|| param_string(params, "agyBin"))
        .map(PathBuf::from)
        .or_else(|| find_binary(&["agy", "antigravity"]));
    let Some(program) = program else {
        diagnostics.push(json!({
            "source": source,
            "status": "binary-unavailable",
        }));
        return;
    };
    let timeout_ms = param_u64(params, "antigravityCliModelLookupTimeoutMs")
        .or_else(|| param_u64(params, "agentCliModelLookupTimeoutMs"))
        .unwrap_or(DEFAULT_AGENT_CLI_MODEL_LOOKUP_TIMEOUT_MS)
        .clamp(
            MIN_AGENT_CLI_MODEL_LOOKUP_TIMEOUT_MS,
            MAX_AGENT_CLI_MODEL_LOOKUP_TIMEOUT_MS,
        );
    let mut command = Command::new(program);
    command.arg("models");
    let output = run_bounded_command_output(
        &mut command,
        Duration::from_millis(timeout_ms),
        MAX_AGENT_CLI_MODEL_LOOKUP_OUTPUT_BYTES,
    );
    let Ok(output) = output else {
        diagnostics.push(json!({
            "source": source,
            "status": "command-failed",
        }));
        return;
    };
    if output.timed_out {
        diagnostics.push(json!({
            "source": source,
            "status": "timeout",
        }));
        return;
    }
    if output.truncated {
        diagnostics.push(json!({
            "source": source,
            "status": "output-too-large",
        }));
        return;
    }
    if !output.status.is_some_and(|status| status.success()) {
        diagnostics.push(json!({
            "source": source,
            "status": "command-exited",
            "code": output.status.and_then(|status| status.code()),
        }));
        return;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let added = collect_model_catalog_from_cli_lines(&stdout, source, entries);
    if added == 0 {
        diagnostics.push(json!({
            "source": source,
            "status": "empty",
        }));
    }
}

pub(super) fn collect_antigravity_available_models_param(
    params: &Value,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    const MAX_AVAILABLE_MODELS_BYTES: usize = 1024 * 1024;
    let Some(raw) = param_string(params, "antigravityAvailableModelsJson") else {
        return;
    };
    let source = "antigravity-local:available-models";
    if raw.len() > MAX_AVAILABLE_MODELS_BYTES {
        diagnostics.push(json!({"source": source, "status": "too-large"}));
        return;
    }
    let Ok(document) = serde_json::from_str::<Value>(&raw) else {
        diagnostics.push(json!({"source": source, "status": "not-parseable"}));
        return;
    };
    let Some(models) = document.get("models") else {
        diagnostics.push(json!({"source": source, "status": "models-missing"}));
        return;
    };
    match models {
        Value::Object(models) => {
            for (model_id, model) in models {
                let Some(name) = model_display_name_from_value(model, model_id) else {
                    continue;
                };
                add_model_catalog_entry_with_provider(
                    entries,
                    &name,
                    Some(&name),
                    provider_id_from_model_value(model).as_deref(),
                    provider_name_from_model_value(model).as_deref(),
                    source,
                    reasoning_efforts_from_value(model),
                );
            }
        }
        Value::Array(_) => {
            collect_model_catalog_entries_from_collection_value(models, source, entries);
        }
        _ => diagnostics.push(json!({"source": source, "status": "models-invalid"})),
    }
}

pub(super) fn collect_model_catalog_from_cli_lines(
    raw: &str,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) -> usize {
    let before = entries.len();
    for line in raw.lines() {
        let trimmed = line
            .trim()
            .trim_start_matches(|ch| matches!(ch, '-' | '*') || ch == '\u{2022}')
            .trim();
        if trimmed.is_empty()
            || trimmed.starts_with("Usage")
            || trimmed.starts_with("Available")
            || trimmed.starts_with("Model")
        {
            continue;
        }
        add_model_catalog_entry(entries, trimmed, source, BTreeSet::new());
    }
    entries.len().saturating_sub(before)
}
