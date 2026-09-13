use super::*;
use crate::platform::run_bounded_untrusted_agent_output;
use std::time::Duration;

pub(super) const SOURCE: &str = "deepseek-harness-installed-adapter";
const MAX_OUTPUT_BYTES: usize = 512 * 1024;
// Model discovery shares the existing one-minute catalog scan policy.
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(60);

// Query the installed official adapter's public metadata API. Do not boot a
// Cordis profile, apply a plugin, resolve credentials, or make a model request.
const METADATA_PROBE: &str = r#"
import { createRequire } from 'node:module';
import { realpathSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
const entry = realpathSync(process.argv[1]);
const require = createRequire(pathToFileURL(entry));
const modulePath = require.resolve('@deepseek-ai/dsh-llm-deepseek', {
  paths: [dirname(entry), join(dirname(entry), 'node_modules/@deepseek-ai/dsh')],
});
const { DeepSeekAdapter, resolveAdapterOptions } = await import(pathToFileURL(modulePath));
const adapter = new DeepSeekAdapter({
  options: () => resolveAdapterOptions({}),
  resolveFiles: () => ({}),
});
const provider = adapter.providerInfo('deepseek-official');
const models = [];
for (const row of await adapter.listModels(provider.id)) {
  const resolved = await adapter.resolveModel(provider.id, row.id);
  models.push({
    name: row.id,
    displayName: row.name,
    providerId: provider.id,
    provider: provider.name,
    reasoningEfforts: resolved.reasoning?.efforts?.map(effort => effort.id) ?? [],
  });
}
process.stdout.write(JSON.stringify({ models }));
"#;

pub(super) fn collect_installed_model_catalog(
    params: &Value,
    entries: &mut BTreeMap<String, ModelCatalogEntry>,
    diagnostics: &mut Vec<Value>,
) -> bool {
    if !agent_cli_model_lookup_enabled(params) {
        diagnostics.push(json!({"source":SOURCE,"status":"disabled"}));
        return false;
    }
    let program = param_string(params, "deepseekHarnessCliPath")
        .map(PathBuf::from)
        .or_else(|| find_binary(&["dsh"]));
    let node = param_string(params, "deepseekHarnessNodePath")
        .map(PathBuf::from)
        .or_else(|| find_binary(&["node"]));
    let (Some(program), Some(node)) = (program, node) else {
        return false;
    };
    if ![&program, &node]
        .into_iter()
        .all(|path| crate::domain::targets::scan_paths::discovered_agent_may_execute(path, true))
    {
        diagnostics.push(json!({"source":SOURCE,"status":"execution-denied"}));
        return false;
    }
    let mut command = Command::new(node);
    command.args(["--input-type=module", "--eval", METADATA_PROBE]);
    command.arg(program);
    let Ok(output) =
        run_bounded_untrusted_agent_output(&mut command, LOOKUP_TIMEOUT, MAX_OUTPUT_BYTES)
    else {
        diagnostics.push(json!({"source":SOURCE,"status":"command-failed"}));
        return false;
    };
    if output.timed_out || output.truncated || !output.status.is_some_and(|status| status.success())
    {
        diagnostics.push(json!({"source":SOURCE,"status":"unavailable"}));
        return false;
    }
    let Ok(catalog) = serde_json::from_slice::<Value>(&output.stdout) else {
        diagnostics.push(json!({"source":SOURCE,"status":"invalid-catalog"}));
        return false;
    };
    let mut installed = BTreeMap::new();
    let mut sources = BTreeSet::new();
    merge_model_catalog_value_into(&catalog, SOURCE, &mut installed, &mut sources, diagnostics);
    if installed.is_empty() {
        diagnostics.push(json!({"source":SOURCE,"status":"empty"}));
        return false;
    }
    for (key, entry) in installed {
        entries.insert(key, entry);
    }
    true
}
