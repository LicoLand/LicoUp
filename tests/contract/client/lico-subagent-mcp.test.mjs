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
const conversationRuntimeProduction = conversationRuntime.slice(
  0,
  conversationRuntime.indexOf("#[cfg(test)]"),
);
const conversationHost = read(
  "crates/licoup-native/src/bin/licoup/stdio_rpc/server/conversation.rs",
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
  assert.match(conversationRuntimeProduction, /DeliveryPlanEngine/u);
  assert.match(conversationRuntimeProduction, /workflow_ledger/u);
  assert.match(source, /ConversationService::open/u);
  assert.match(conversationRuntimeProduction, /ConversationAdmissionFailure/u);
  for (const code of [
    "conversation_location_relative",
    "conversation_location_missing",
    "conversation_location_outside_catalog",
    "conversation_location_ambiguous",
    "conversation_location_unbounded",
  ]) {
    assert.match(conversationRuntimeProduction, new RegExp(code, "u"));
  }
  assert.match(conversationRuntimeProduction, /dispatch_lane_operation\(\s*"open"/u);
  // Delivery dispatch, reconciliation, and cancellation run through the
  // process-owned persistent host door under the durable Delivery dispatch
  // identity; the canonical dispatch record is the terminal evidence source.
  // The retired one-shot lane send, the duplicate dispatch bookkeeping, and
  // the admission-cause scope are gone from the Delivery path.
  assert.match(conversationRuntimeProduction, /agent\.conversation\.dispatch/u);
  assert.match(conversationRuntimeProduction, /agent\.conversation\.cancel/u);
  assert.match(conversationRuntimeProduction, /request\.dispatch_id/u);
  assert.match(conversationRuntimeProduction, /dispatch_record/u);
  assert.match(conversationRuntimeProduction, /persistent_conversation_transport_required/u);
  assert.match(conversationRuntimeProduction, /DeliveryHostRequest/u);
  assert.doesNotMatch(conversationRuntimeProduction, /dispatch_lane_operation\("send"/u);
  assert.doesNotMatch(conversationRuntimeProduction, /dispatch_lane_operation\(\s*"cancel"/u);
  assert.doesNotMatch(conversationRuntimeProduction, /create_dispatch\(/u);
  assert.doesNotMatch(conversationRuntimeProduction, /update_dispatch\(/u);
  assert.doesNotMatch(conversationRuntimeProduction, /prepare_runtime_dispatch/u);
  assert.doesNotMatch(conversationRuntimeProduction, /delivery-conversation-admission/u);
  assert.match(deliveryScheduler, /reconcile\(\s*&dispatch\.dispatch_id/u);
  assert.doesNotMatch(deliveryScheduler, /dispatch_lane_operation/u);
  assert.doesNotMatch(deliveryScheduler, /create_dispatch\(/u);
  assert.doesNotMatch(deliveryScheduler, /update_dispatch\(/u);
  assert.doesNotMatch(deliveryScheduler, /prepare_runtime_dispatch/u);
  assert.doesNotMatch(deliveryScheduler, /delivery-conversation-admission/u);
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
  assert.match(source, /agent\.conversation\.cancel/u);
  // The runner and explicit Delivery cancellation share one composed
  // persistent host door, drive cancellation by the durable dispatch
  // identity, and never spend the runner's progress budget on live turns.
  assert.match(source, /compose_delivery_runtime/u);
  assert.match(source, /delivery_host_request/u);
  assert.match(source, /conversation_host_transport::connect_existing/u);
  assert.match(source, /PERSISTENT_TRANSPORT_REQUIRED/u);
  assert.match(source, /delivery_pass_outcome/u);
  assert.match(source, /DeliveryPassOutcome::WaitPending/u);
  assert.match(source, /cancel\(&record\.dispatch_id\)/u);
  assert.match(source, /RunningDeliveryGuard::claim/u);
  assert.match(source, /"accepted": true/u);
  assert.match(source, /DispatchSessionMode::Resume/u);
  // Delegation and cancellation enter the persistent host's one turn registry;
  // the MCP process owns no parallel frame stream or terminal writer.
  const dispatchDoor = source.slice(
    source.indexOf("fn dispatch_subagent("),
    source.indexOf("fn conversation_dispatch_context("),
  );
  assert.match(dispatchDoor, /agent\.conversation\.dispatch/u);
  assert.match(dispatchDoor, /execute_persistent_conversation_method/u);
  assert.match(dispatchDoor, /streamEvents": true/u);
  assert.match(dispatchDoor, /validate_dispatch_selection/u);
  assert.match(dispatchDoor, /params\["model"\]/u);
  assert.match(dispatchDoor, /params\["reasoningEffort"\]/u);
  assert.doesNotMatch(dispatchDoor, /dispatch_lane_operation\("send"/u);
  assert.doesNotMatch(dispatchDoor, /prepare_runtime_dispatch/u);
  assert.doesNotMatch(dispatchDoor, /append_runtime_frame/u);
  assert.doesNotMatch(dispatchDoor, /finish_runtime_dispatch/u);
  assert.doesNotMatch(source, /create_dispatch/u);
  assert.match(conversationStore, /CREATE TABLE IF NOT EXISTS conversation_dispatches/u);
  assert.match(conversationStore, /latest_resumable_dispatch/u);
  assert.match(conversationStore, /requested_dispatch_id/u);
  assert.match(source, /ConversationService::open/u);
  assert.match(source, /conversation_dispatch_context/u);
  assert.match(source, /"conversationId"/u);
  assert.match(source, /"membershipId"/u);
  assert.match(source, /"licoup\.subagent\.receipt\.v2"/u);
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
});

test("subagent readiness observation never sends Agent input", () => {
  assert.match(source, /"lico_subagent_probe"/u);
  assert.match(source, /licoup\.subagent\.readiness\.v1/u);
  assert.match(source, /"subagent\.readiness"/u);
  // The readiness door is one bounded read-only host request filtered by the
  // admitted Agent with zero change-wait; the receipt projects target facts
  // plus the turn count and no private runtime identifier.
  const readinessDoor = source.slice(
    source.indexOf("fn probe_subagent("),
    source.indexOf("fn delivery_start("),
  );
  assert.match(readinessDoor, /targets::inspect_target_read_only/u);
  assert.match(readinessDoor, /agent\.conversation\.active/u);
  assert.match(
    readinessDoor,
    /execute_read_only_persistent_conversation_method/u,
  );
  assert.doesNotMatch(readinessDoor, /targets::inspect_target\(/u);
  assert.match(readinessDoor, /"waitForChangeMs": 0/u);
  assert.match(readinessDoor, /"hostTransport"/u);
  assert.match(readinessDoor, /"hostActiveTurns"/u);
  assert.match(readinessDoor, /"integrationStatus"/u);
  assert.match(readinessDoor, /"conversationDriver"/u);
  assert.match(readinessDoor, /"conversationReadiness"/u);
  assert.match(readinessDoor, /"blockerCode"/u);
  assert.doesNotMatch(readinessDoor, /dispatch_lane_operation/u);
  assert.doesNotMatch(readinessDoor, /agent\.conversation\.dispatch/u);
  assert.doesNotMatch(readinessDoor, /"prompt"/u);
  assert.doesNotMatch(readinessDoor, /"text"/u);
  assert.doesNotMatch(readinessDoor, /"model"/u);
  assert.doesNotMatch(readinessDoor, /"reasoningEffort"/u);
  assert.doesNotMatch(readinessDoor, /"workingDirectory"/u);
  assert.doesNotMatch(readinessDoor, /"timeoutMs"/u);
  assert.doesNotMatch(readinessDoor, /conversation_list/u);
  assert.doesNotMatch(readinessDoor, /trash::/u);

  const activeObservationDoor = conversationHost.slice(
    conversationHost.indexOf("pub(super) fn active("),
    conversationHost.indexOf("fn record_event("),
  );
  assert.match(activeObservationDoor, /turn\.agent_id != agent/u);
  assert.match(activeObservationDoor, /terminal\.is_some\(\)/u);
  assert.doesNotMatch(activeObservationDoor, /dispatch_lane_operation/u);
  assert.doesNotMatch(activeObservationDoor, /append_runtime_frame/u);
  assert.doesNotMatch(activeObservationDoor, /bind_runtime_session/u);
  assert.doesNotMatch(activeObservationDoor, /turn\.store/u);
});

test("driver-owned conversation cleanup remains framework-specific without role policy", () => {
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
  assert.match(source, /"timeoutMs": timeout_ms\.unwrap_or\(0\)/u);
  assert.match(source, /params\["allowAll"\]/u);
  assert.match(source, /params\["permissionMode"\]/u);
  assert.match(source, /params\["maxStdoutBytes"\]/u);
  assert.match(source, /params\["maxStderrBytes"\]/u);
  assert.match(source, /agent\.conversation\.dispatch/u);
  assert.match(source, /agent\.conversation\.cancel/u);
  assert.doesNotMatch(source, /fn execute_subagent_send/u);
  assert.doesNotMatch(source, /"output":\s*output/u);
  assert.doesNotMatch(source, /"sessionId": source\.get/u);
});
