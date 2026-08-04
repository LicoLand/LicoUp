use super::*;
use crate::platform::run_bounded_command_output;
use std::time::Duration;

const MAX_OUTPUT_BYTES: usize = 512 * 1024;

pub(super) fn collect_pi_cli_model_catalog(
    params: &Value,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) {
    const SOURCE: &str = "pi-cli:list-models";
    if param_bool(params, "disableAgentCliModelLookup").unwrap_or(false) {
        return;
    }
    if cfg!(test) && !param_bool(params, "enableAgentCliModelLookup").unwrap_or(false) {
        return;
    }
    let program = param_string(params, "piCliPath")
        .map(PathBuf::from)
        .or_else(|| find_binary(&["pi"]));
    let Some(program) = program else { return };
    let mut command = Command::new(program);
    command.arg("--list-models");
    let Ok(output) =
        run_bounded_command_output(&mut command, Duration::from_millis(3_000), MAX_OUTPUT_BYTES)
    else {
        diagnostics.push(json!({"source": SOURCE, "status": "command-failed"}));
        return;
    };
    if output.timed_out || output.truncated || !output.status.is_some_and(|status| status.success())
    {
        diagnostics.push(json!({"source": SOURCE, "status": "unavailable"}));
        return;
    }
    let raw = String::from_utf8_lossy(&output.stdout);
    if collect_pi_models_from_output(&raw, entries) == 0 {
        diagnostics.push(json!({"source": SOURCE, "status": "empty"}));
    }
}

fn collect_pi_models_from_output(
    raw: &str,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
) -> usize {
    let before = entries.len();
    for line in raw.lines().skip(1) {
        let columns = line.split_whitespace().collect::<Vec<_>>();
        if columns.len() < 2 {
            continue;
        }
        let efforts = (columns.get(4).copied() == Some("yes"))
            .then(|| ["off", "minimal", "low", "medium", "high", "xhigh", "max"])
            .into_iter()
            .flatten()
            .map(str::to_owned)
            .collect();
        add_model_catalog_entry_with_provider(
            entries,
            columns[1],
            None,
            Some(columns[0]),
            None,
            "pi-cli:list-models",
            efforts,
        );
    }
    entries.len().saturating_sub(before)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_pi_native_model_table() {
        let mut entries = BTreeMap::new();
        let count = collect_pi_models_from_output(
            "provider model context max-out thinking images\nacme alpha 1M 8K yes no\n",
            &mut entries,
        );
        assert_eq!(count, 1);
        let model = entries.values().next().unwrap();
        assert_eq!(model.name, "alpha");
        assert!(model.reasoning_efforts.contains(&"max".to_string()));
    }
}
