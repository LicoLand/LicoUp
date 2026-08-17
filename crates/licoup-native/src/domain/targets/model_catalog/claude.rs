use super::*;
use crate::platform::run_bounded_untrusted_agent_output;
use std::time::Duration;

// Product policy: every model-catalog scan waits up to one minute.
const DEFAULT_CLAUDE_CLI_MODEL_LOOKUP_TIMEOUT_MS: u64 = 60_000;
const MIN_CLAUDE_CLI_MODEL_LOOKUP_TIMEOUT_MS: u64 = 100;
const MAX_CLAUDE_CLI_MODEL_LOOKUP_TIMEOUT_MS: u64 = 60_000;
const MAX_CLAUDE_CLI_MODEL_LOOKUP_OUTPUT_BYTES: usize = 256 * 1024;

/// Claude Code family aliases are picker shortcuts, not callable backend ids.
pub(super) fn is_claude_code_family_alias(name: &str) -> bool {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return false;
    }
    let without_context = trimmed
        .split_once('[')
        .map(|(head, _)| head)
        .unwrap_or(trimmed)
        .trim();
    matches!(
        without_context.to_ascii_lowercase().as_str(),
        "opus" | "sonnet" | "haiku"
    )
}

pub(super) fn remove_claude_code_family_aliases(
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    default_model: &mut Option<String>,
) {
    entries.retain(|_, entry| !is_claude_code_family_alias(&entry.name));
    if default_model
        .as_deref()
        .is_some_and(is_claude_code_family_alias)
    {
        *default_model = entries
            .values()
            .next()
            .map(|entry| entry.name.clone())
            .filter(|name| !is_claude_code_family_alias(name));
    }
}

pub(super) fn collect_claude_code_cli_model_catalog(
    params: &Value,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) -> bool {
    let source = "claude-cli:models";
    if !agent_cli_model_lookup_enabled(params)
        || param_bool(params, "disableClaudeCliModelLookup").unwrap_or(false)
    {
        diagnostics.push(json!({"source": source, "status": "disabled"}));
        return false;
    }

    let program = param_string(params, "claudeCliPath")
        .or_else(|| param_string(params, "claudePath"))
        .map(PathBuf::from)
        .or_else(|| find_binary(&["claude"]));
    let Some(program) = program else {
        diagnostics.push(json!({"source": source, "status": "binary-unavailable"}));
        return false;
    };
    let timeout_ms = param_u64(params, "claudeCliModelLookupTimeoutMs")
        .or_else(|| param_u64(params, "agentCliModelLookupTimeoutMs"))
        .unwrap_or(DEFAULT_CLAUDE_CLI_MODEL_LOOKUP_TIMEOUT_MS)
        .clamp(
            MIN_CLAUDE_CLI_MODEL_LOOKUP_TIMEOUT_MS,
            MAX_CLAUDE_CLI_MODEL_LOOKUP_TIMEOUT_MS,
        );
    if !crate::domain::targets::scan_paths::discovered_agent_may_execute(&program, true) {
        diagnostics.push(json!({"source": source, "status": "execution-denied"}));
        return false;
    }
    let mut command = Command::new(program);
    command.arg("models");
    let Ok(output) = run_bounded_untrusted_agent_output(
        &mut command,
        Duration::from_millis(timeout_ms),
        MAX_CLAUDE_CLI_MODEL_LOOKUP_OUTPUT_BYTES,
    ) else {
        diagnostics.push(json!({"source": source, "status": "command-failed"}));
        return false;
    };
    if output.timed_out {
        diagnostics.push(json!({"source": source, "status": "timeout"}));
        return false;
    }
    if output.truncated {
        diagnostics.push(json!({"source": source, "status": "output-too-large"}));
        return false;
    }
    if !output.status.is_some_and(|status| status.success()) {
        diagnostics.push(json!({
            "source": source,
            "status": "command-exited",
            "code": output.status.and_then(|status| status.code()),
        }));
        return false;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let added = collect_claude_code_models_from_cli_output(&stdout, source, entries);
    if added == 0 {
        diagnostics.push(json!({"source": source, "status": "empty"}));
        return false;
    }
    true
}

pub(super) fn collect_claude_code_models_from_cli_output(
    raw: &str,
    source: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) -> usize {
    let before = entries.len();
    let trimmed = raw.trim();
    if (trimmed.starts_with('{') || trimmed.starts_with('['))
        && let Ok(value) = serde_json::from_str::<Value>(trimmed)
    {
        collect_model_catalog_entries_from_collection_value(&value, source, entries);
        entries.retain(|_, entry| !is_claude_code_family_alias(&entry.name));
        return entries.len().saturating_sub(before);
    }
    for line in raw.lines() {
        let trimmed = line
            .trim()
            .trim_start_matches(|ch| matches!(ch, '-' | '*') || ch == '\u{2022}')
            .trim();
        if trimmed.is_empty()
            || trimmed.starts_with("Usage")
            || trimmed.starts_with("Available")
            || trimmed.starts_with("Tip:")
            || trimmed.eq_ignore_ascii_case("models")
        {
            continue;
        }
        let (model_id, display_name) = trimmed
            .split_once(" - ")
            .map(|(id, label)| (id.trim(), Some(label.trim())))
            .unwrap_or((trimmed, None));
        let model_id = model_id
            .split_whitespace()
            .next()
            .unwrap_or(model_id)
            .trim_end_matches([':', ',']);
        if is_claude_code_family_alias(model_id) {
            continue;
        }
        add_model_catalog_entry_with_provider(
            entries,
            model_id,
            display_name.filter(|label| !is_claude_code_family_alias(label)),
            None,
            None,
            source,
            BTreeSet::new(),
        );
    }
    entries.len().saturating_sub(before)
}
