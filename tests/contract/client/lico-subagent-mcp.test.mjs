import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { linuxBundleLayout } from "../../../apps/desktop/scripts/package-client/bundle-resolver/linux.mjs";
import { macosBundleLayout } from "../../../apps/desktop/scripts/package-client/bundle-resolver/macos.mjs";
import { windowsBundleLayout } from "../../../apps/desktop/scripts/package-client/bundle-resolver/windows.mjs";

const root = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const read = (relative) => readFileSync(path.join(root, relative), "utf8");

const source = read("crates/licoup-native/src/bin/lico-subagent-mcp.rs");
const workflowLoop = read("crates/licoup-native/src/domain/agent_workflow_loop.rs");
const providerPricing = read("crates/licoup-native/src/domain/provider_model_pricing.rs");
const pricingSnapshot = JSON.parse(
  read("crates/licoup-native/src/domain/provider_model_pricing/pricing_snapshot.json"),
);
const cursorControl = read("crates/licoup-native/src/platform/cursor_driver/control.rs");
const antigravityControl = read("crates/licoup-native/src/platform/antigravity_driver/control.rs");
const codexPluginManager = read(
  "crates/licoup-native/src/platform/codex_plugin_manager.rs",
);
const packaging = JSON.parse(read("apps/desktop/packaging.modules.json"));
const resourceAssembly = read(
  "apps/desktop/scripts/package-client/resource-assembly.mjs",
);

const tools = [
  "lico_subagents_list",
  "lico_subagent_probe",
  "lico_subagent_delegate",
  "lico_subagent_continue",
  "lico_subagent_cancel",
];

test("subagent MCP exposes only direct subordinate operations", () => {
  for (const name of tools) {
    assert.match(source, new RegExp(`"${name}"`, "u"));
  }
  assert.match(
    source,
    /fn main\(\)[\s\S]*targets::scan_targets\(\)[\s\S]*ServerState::new\(\)/u,
  );
  assert.match(source, /dispatch_lane_operation\("send"/u);
  assert.match(source, /dispatch_lane_operation\(\s*"cancel"/u);
  assert.match(source, /AgentIntelligenceCatalog::embedded\(\)/u);
  assert.match(source, /provider_model_pricing::refresh_official_sources\(\)/u);
  assert.match(source, /provider_model_pricing::quote_probe/u);
  assert.match(providerPricing, /Refresh every provider concurrently/u);
  assert.deepEqual(
    pricingSnapshot.providers.map((provider) => provider.id),
    ["deepseek", "kimi", "google", "cursor", "openai-chatgpt", "kilo"],
  );
  assert.equal(
    pricingSnapshot.providers
      .find((provider) => provider.id === "cursor")
      .models.find((model) => model.model_id === "composer-2-5")
      .included_by_harness,
    true,
  );
  assert.equal(
    pricingSnapshot.providers
      .find((provider) => provider.id === "kilo")
      .models.find((model) => model.model_id === "free")
      .included_by_harness,
    true,
  );
  assert.match(source, /trash::delete\(target\)/u);
  assert.match(source, /moved-to-trash-and-verified/u);
  assert.match(source, /not-persisted-and-verified/u);
});

test("every target framework receives the reviewer probe contract", () => {
  assert.match(source, /required_workflow_role/u);
  assert.match(source, /subordinate_role_prompt\(role, &prompt\)/u);
  assert.match(workflowLoop, /pub fn subordinate_role_prompt/u);
  assert.match(workflowLoop, /LicoUp 验收约束/u);
  assert.match(workflowLoop, /Reply with exactly READY/u);
  assert.match(workflowLoop, /任何清理失败都必须判定验收失败/u);
  assert.match(cursorControl, /trash::delete\(&leaf\)/u);
  assert.match(cursorControl, /trash::delete\(&target\)/u);
  assert.match(antigravityControl, /trash::delete\(&brain\)/u);
});

test("code engineering uses one Designer and lane-specific Worker and Reviewer assignments", () => {
  assert.match(source, /"enum": \["designer", "worker", "reviewer"\]/u);
  assert.match(source, /"enum": \["backend", "frontend"\]/u);
  assert.match(source, /"designer", WorkflowRole::Designer, None/u);
  assert.match(source, /"backendWorker"/u);
  assert.match(source, /"frontendWorker"/u);
  assert.match(source, /"backendReviewer"/u);
  assert.match(source, /"frontendReviewer"/u);
  assert.match(source, /"codeEngineeringStrategy"/u);
  assert.match(source, /configured_code_engineering_assignment\(role, lane\)/u);
});

test("Codex plugin installs from the pinned GitHub release and uses the packaged runtime", () => {
  assert.match(codexPluginManager, /PLUGIN_NAME: &str = "lico-up-codex"/u);
  assert.match(codexPluginManager, /PLUGIN_VERSION: &str = "0\.1\.0"/u);
  assert.match(codexPluginManager, /MARKETPLACE_NAME: &str = "licoup-plugins"/u);
  assert.match(codexPluginManager, /MARKETPLACE_SOURCE: &str = "LicoLand\/LicoUp-Plugins"/u);
  assert.match(codexPluginManager, /MARKETPLACE_RELEASE: &str = "v0\.1\.0"/u);
  assert.match(codexPluginManager, /"marketplace",\s*"add"/u);
  assert.match(codexPluginManager, /"--ref",\s*MARKETPLACE_REF/u);
  assert.equal(packaging.modules["subagents-mcp"].cargoBin, "lico-subagent-mcp");
  assert.deepEqual(packaging.modules["codex-plugin"].requires, [
    "subagents-mcp",
  ]);
  assert.equal(
    packaging.modules["codex-plugin"].embeddedCargoBin,
    "lico-subagent-mcp",
  );
  assert.equal(
    packaging.modules["codex-plugin"].embeddedCargoTarget,
    "plugins/lico-up-codex/bin/lico-subagent-mcp",
  );
  assert.equal(packaging.modules["codex-plugin"].includePaths, undefined);
  assert.equal(packaging.modules["codex-plugin"].mappedResources, undefined);
  assert.match(resourceAssembly, /bundle\.pluginResourceDir/u);
  const fixtureRoot = path.join("fixture", "bundle");
  assert.equal(
    macosBundleLayout(fixtureRoot).pluginResourceDir,
    path.join(fixtureRoot, "licoup.app", "Contents", "Resources"),
  );
  assert.equal(
    linuxBundleLayout(fixtureRoot).pluginResourceDir,
    path.join(fixtureRoot, "resources"),
  );
  assert.equal(
    windowsBundleLayout(fixtureRoot).pluginResourceDir,
    path.join(fixtureRoot, "resources"),
  );
});

test("MCP bounds prompts, local directories, conversation locations, concurrency, and quota fallbacks", () => {
  assert.match(source, /MAX_PROMPT_BYTES: usize = 48 \* 1024/u);
  assert.match(source, /MAX_CONVERSATION_PATH_BYTES: usize = 4096/u);
  assert.match(source, /MAX_WORKING_DIRECTORY_BYTES: usize = 4096/u);
  assert.match(source, /MAX_PENDING_TOOL_CALLS: usize = 32/u);
  assert.match(source, /MAX_TOOL_WORKERS: usize = 8/u);
  assert.match(source, /"sameFramework"/u);
  assert.match(source, /runtime\.message\.send/u);
  assert.match(source, /"conversationPath"/u);
  assert.match(source, /session_id_candidates/u);
  assert.match(source, /exact_session_id_for_path/u);
  assert.match(source, /"workingDirectory"/u);
  assert.match(source, /"fallbackCandidates"/u);
  assert.match(source, /MAX_FALLBACK_CANDIDATES: usize = 8/u);
  assert.match(source, /MIN_SUBAGENT_TIMEOUT_MS: u64 = 1_000/u);
  assert.match(source, /MAX_SUBAGENT_TIMEOUT_MS: u64 = 30 \* 60 \* 1_000/u);
  assert.match(source, /MAX_SUBAGENT_STDOUT_BYTES: u64 = 64 \* 1024 \* 1024/u);
  assert.match(source, /MAX_SUBAGENT_STDERR_BYTES: u64 = 4 \* 1024 \* 1024/u);
  assert.match(source, /params\["timeoutMs"\]/u);
  assert.match(source, /params\["allowAll"\]/u);
  assert.match(source, /params\["permissionMode"\]/u);
  assert.match(source, /params\["maxStdoutBytes"\]/u);
  assert.match(source, /params\["maxStderrBytes"\]/u);
  assert.match(source, /MAX_QUOTA_COOLDOWNS: usize = 64/u);
  assert.match(source, /quota_or_capacity_failure/u);
  assert.doesNotMatch(source, /"output": output/u);
  assert.doesNotMatch(source, /"sessionId": source\.get/u);
});
