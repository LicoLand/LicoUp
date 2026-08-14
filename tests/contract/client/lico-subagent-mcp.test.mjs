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
const deliveryPlan = read("crates/licoup-native/src/domain/delivery_plan/mod.rs");
const deliveryScheduler = read("crates/licoup-native/src/domain/delivery_scheduler.rs");
const deliveryState = read("crates/licoup-native/src/domain/delivery_state.rs");
const workflowLedger = read(
  "crates/licoup-native/src/domain/agent_usage/workflow_ledger.rs",
);
const conversationRuntime = read(
  "crates/licoup-native/src/platform/conversation_runtime.rs",
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

test("MCP exposes native delivery lifecycle and direct one-off tools", () => {
  for (const name of [
    "lico_delivery_start",
    "lico_delivery_authorize",
    "lico_delivery_status",
    "lico_delivery_cancel",
    "lico_subagents_list",
    "lico_subagent_delegate",
    "lico_subagent_continue",
    "lico_subagent_cancel",
  ]) {
    assert.match(source, new RegExp(`"${name}"`, "u"));
  }
  assert.match(source, /conversation_runtime/u);
  assert.match(source, /DeliveryPlanEngine/u);
  assert.match(source, /inputSchema[\s\S]*additionalProperties": false/u);
  assert.match(source, /MAX_PENDING_TOOL_CALLS: usize = 32/u);
  assert.match(source, /MAX_TOOL_WORKERS: usize = 8/u);
  assert.match(source, /MAX_PROMPT_BYTES: usize = 48 \* 1024/u);
  assert.match(source, /MAX_LOCATION_BYTES: usize = 4096/u);
  assert.match(source, /MAX_WORKING_DIRECTORY_BYTES: usize = 4096/u);

  // A caller starts and authorizes a Plan; it cannot submit frontier, route,
  // worker/reviewer acceptance, or another owner to the delivery scheduler.
  assert.doesNotMatch(source, /required_workflow_role|CodeEngineeringLane/u);
});

test("delivery uses the Plan and numeric ledger through the Conversation runtime", () => {
  assert.match(deliveryPlan, /pub struct DeliveryPlanEngine/u);
  assert.match(deliveryPlan, /eligible_tasks\(\)/u);
  assert.match(deliveryPlan, /bind_dispatch\(/u);
  assert.match(deliveryPlan, /complete_dispatch\(/u);
  assert.match(deliveryPlan, /fail_dispatch\(/u);
  assert.match(workflowLedger, /pub fn begin_delivery/u);
  assert.match(workflowLedger, /pub fn bind_conversation_baseline/u);
  assert.match(workflowLedger, /pub fn settle_turn/u);
  assert.match(workflowLedger, /pub fn mark_terminal/u);
  assert.match(conversationRuntime, /DeliveryPlanEngine/u);
  assert.match(conversationRuntime, /workflow_ledger/u);
  assert.match(conversationRuntime, /ConversationService/u);
  assert.match(conversationRuntime, /ConversationAdmissionFailure/u);
  for (const code of [
    "conversation_location_relative",
    "conversation_location_missing",
    "conversation_location_outside_catalog",
    "conversation_location_ambiguous",
    "conversation_location_unbounded",
  ]) {
    assert.match(conversationRuntime, new RegExp(code, "u"));
  }
  assert.match(conversationRuntime, /dispatch_lane_operation\("send"/u);
  assert.match(conversationRuntime, /dispatch_lane_operation\(\s*"cancel"/u);
});

test("accepted delivery failures and cancellation roots stay durable and typed", () => {
  assert.match(source, /persist_runner_failure_until_durable/u);
  assert.match(source, /delivery_runner_pass_uncommitted/u);
  assert.match(source, /DeliveryRunnerState::InDoubt/u);
  assert.match(source, /delivery_runner_interrupted/u);
  assert.match(
    source,
    /fn delivery_status[\s\S]*DeliveryRunnerState::Running[\s\S]*!runner_active[\s\S]*delivery_runner_interrupted[\s\S]*persist_runner_failure/u,
  );
  assert.match(source, /delivery_state_root_mismatch/u);
  assert.match(deliveryScheduler, /ensure_not_cancelled/u);
  assert.match(deliveryScheduler, /reconcile_cancelled_ledger/u);
  assert.match(deliveryScheduler, /usage_ledger_terminal_state_conflict/u);
  assert.match(deliveryState, /licoup\.delivery-dispatch\.v1/u);
  assert.match(deliveryState, /licoup\.delivery-control\.v1/u);
  assert.match(deliveryState, /delivery-state/u);
  assert.match(deliveryState, /persist_delivery_dispatch/u);
  assert.match(deliveryState, /persist_delivery_control/u);
  assert.match(deliveryState, /ledger_state_root/u);
  assert.match(deliveryState, /public_projection/u);
  assert.match(source, /set_delivery_runner/u);
  assert.match(source, /delivery_state::persist_delivery_control/u);
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

test("Codex plugin readiness is packaged independently from delivery ownership", () => {
  assert.match(codexPluginManager, /PLUGIN_NAME: &str = "lico-up-codex"/u);
  assert.match(codexPluginManager, /PLUGIN_VERSION: &str = "0\.1\.0"/u);
  assert.match(codexPluginManager, /MARKETPLACE_NAME: &str = "licoup-plugins"/u);
  assert.match(codexPluginManager, /MARKETPLACE_SOURCE: &str = "LicoLand\/LicoUp-Plugins"/u);
  assert.match(codexPluginManager, /MARKETPLACE_RELEASE: &str = "v0\.1\.0"/u);
  assert.match(codexPluginManager, /"marketplace",\s*"add"/u);
  assert.match(codexPluginManager, /"--ref",\s*MARKETPLACE_REF/u);
  assert.equal(packaging.modules["subagents-mcp"].cargoBin, "lico-subagent-mcp");
  assert.deepEqual(packaging.modules["codex-plugin"].requires, ["subagents-mcp"]);
  assert.equal(packaging.modules["codex-plugin"].embeddedCargoBin, "lico-subagent-mcp");
  assert.equal(
    packaging.modules["codex-plugin"].embeddedCargoTarget,
    "plugins/lico-up-codex/bin/lico-subagent-mcp",
  );
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
