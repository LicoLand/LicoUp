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
const conversationStore = read(
  "crates/licoup-native/src/domain/client_conversation/store.rs",
);
const providerPricing = read("crates/licoup-native/src/domain/provider_model_pricing.rs");
const pricingCatalog = JSON.parse(
  read("crates/licoup-native/src/domain/provider_model_pricing/pricing_catalog.json"),
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
  assert.match(source, /"accepted": true/u);
  assert.match(source, /DispatchState::Running/u);
  assert.match(source, /DispatchSessionMode::Resume/u);
  assert.match(conversationStore, /CREATE TABLE IF NOT EXISTS conversation_dispatches/u);
  assert.match(conversationStore, /latest_resumable_dispatch/u);
  assert.match(source, /thread::spawn/u);
  assert.match(source, /ConversationService::open/u);
  assert.match(source, /conversation_dispatch_context/u);
  assert.match(source, /"conversationId"/u);
  assert.match(source, /"membershipId"/u);
  assert.match(source, /"licoup\.subagent\.receipt\.v2"/u);
  assert.match(source, /AgentIntelligenceCatalog::embedded\(\)/u);
  assert.match(source, /provider_model_pricing::refresh_official_sources\(\)/u);
  assert.match(source, /provider_model_pricing::quote_probe/u);
  assert.match(providerPricing, /Refresh every pricing table concurrently/u);
  assert.deepEqual(
    [...pricingCatalog.providers, ...pricingCatalog.agents].map((table) => table.id),
    [
      "deepseek",
      "kimi",
      "google",
      "openai",
      "anthropic",
      "xai",
      "cursor",
      "openai-chatgpt",
      "kilo",
      "opencode-zen",
    ],
  );
  assert.equal(
    pricingCatalog.agents
      .find((provider) => provider.id === "cursor")
      .routes.find((model) => model.model_id === "composer-2.5")
      .included_by_harness,
    true,
  );
  assert.equal(
    pricingCatalog.agents
      .find((provider) => provider.id === "kilo")
      .routes.find((model) => model.model_id === "free")
      .included_by_harness,
    true,
  );
  assert.match(source, /trash::delete\(target\)/u);
  assert.match(source, /moved-to-trash-and-verified/u);
  assert.match(source, /not-persisted-and-verified/u);
});

test("diagnostic probe cleanup remains framework-specific without role policy", () => {
  assert.doesNotMatch(source, /required_workflow_role/u);
  assert.doesNotMatch(source, /subordinate_role_prompt/u);
  assert.match(cursorControl, /trash::delete\(&leaf\)/u);
  assert.match(cursorControl, /trash::delete\(&target\)/u);
  assert.match(antigravityControl, /trash::delete\(&brain\)/u);
});

test("subagent delegation has no fixed collaboration roles or lanes", () => {
  assert.doesNotMatch(source, /WorkflowRole/u);
  assert.doesNotMatch(source, /CodeEngineeringLane/u);
  assert.doesNotMatch(source, /frontend_backend_roles/u);
  assert.doesNotMatch(source, /codeEngineeringStrategy/u);
  assert.doesNotMatch(source, /fallbackCandidates/u);
  assert.doesNotMatch(source, /mainConversationPath/u);
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

test("MCP bounds prompts, local directories, private runtime state, and concurrency", () => {
  assert.match(source, /MAX_PROMPT_BYTES: usize = 48 \* 1024/u);
  assert.match(source, /MAX_WORKING_DIRECTORY_BYTES: usize = 4096/u);
  assert.match(source, /MAX_PENDING_TOOL_CALLS: usize = 32/u);
  assert.match(source, /MAX_TOOL_WORKERS: usize = 8/u);
  assert.match(source, /"sameFramework"/u);
  assert.match(source, /runtime\.message\.send/u);
  const catalog = source.slice(
    source.indexOf("fn tool_catalog()"),
    source.indexOf("fn closed_object("),
  );
  assert.doesNotMatch(catalog, /conversationPath/u);
  assert.doesNotMatch(catalog, /sessionMode/u);
  assert.match(source, /runtime_conversation_path/u);
  assert.match(source, /session_id_candidates/u);
  assert.match(source, /exact_session_id_for_path/u);
  assert.match(source, /"workingDirectory"/u);
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
  assert.match(source, /output:\s*value/u);
  assert.doesNotMatch(source, /"output":\s*output/u);
  assert.doesNotMatch(source, /"sessionId": source\.get/u);
});
