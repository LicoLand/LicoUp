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
const workflow = read("crates/licoup-native/src/domain/delivery_workflow.rs");
const runtime = read("crates/licoup-native/src/platform/delivery_workflow_runtime.rs");
const handoff = read("crates/licoup-native/src/domain/subagent_handoff.rs");
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
  assert.match(source, /delivery_workflow_runtime::run_once/u);
  assert.match(source, /delivery_workflow::start/u);
  assert.match(source, /delivery_workflow::authorize/u);
  assert.match(source, /delivery_workflow::status/u);
  assert.match(source, /delivery_workflow::cancel/u);
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

test("delivery scheduler consumes the Plan and workflow ledger with Adaptive routing", () => {
  assert.match(workflow, /pub const DELIVERY_AUTHORITY: &str = "licoup"/u);
  assert.match(
    workflow,
    /pub const ROUTE_SELECTION_AUTHORITY: &str = "adaptive-flywheel"/u,
  );
  assert.match(workflow, /pub struct DeliveryScheduler/u);
  assert.match(workflow, /DeliveryPlanEngine/u);
  assert.match(workflow, /eligible_tasks\(\)/u);
  assert.match(workflow, /bind_dispatch\(/u);
  assert.match(workflow, /complete_dispatch\(/u);
  assert.match(workflow, /fail_dispatch\(/u);
  assert.match(workflow, /workflow_ledger::begin_delivery/u);
  assert.match(workflow, /workflow_ledger::bind_conversation_baseline/u);
  assert.match(workflow, /workflow_ledger::settle_turn/u);
  assert.match(workflow, /workflow_ledger::mark_terminal/u);
  assert.match(workflow, /RouteReceipt/u);
  assert.match(workflow, /child\.binding|child_conversation_binding/u);
  assert.match(runtime, /ConversationAdmissionFailure/u);
  for (const code of [
    "conversation_location_relative",
    "conversation_location_missing",
    "conversation_location_outside_catalog",
    "conversation_location_ambiguous",
    "conversation_location_unbounded",
  ]) {
    assert.match(runtime, new RegExp(code, "u"));
  }
  assert.match(runtime, /dispatch_lane_operation\("send"/u);
  assert.match(runtime, /dispatch_lane_operation\(\s*"cancel"/u);
  assert.match(runtime, /conversations::conversation_list/u);
});

test("accepted delivery failures and cancellation roots stay durable and typed", () => {
  assert.match(source, /persist_runner_failure_until_durable/u);
  assert.match(source, /delivery_runner_pass_uncommitted/u);
  assert.match(source, /DeliveryRunnerState::InDoubt/u);
  assert.match(source, /delivery_runner_interrupted/u);
  assert.match(source, /project_runner_status/u);
  assert.match(source, /delivery_state_root_mismatch/u);
  assert.match(workflow, /WORKFLOW_TERMINAL_LOCK_STRIPES/u);
  assert.match(workflow, /ensure_not_cancelled/u);
  assert.match(workflow, /reconcile_cancelled_ledger/u);
  assert.match(handoff, /DELIVERY_CONTROL_SCHEMA_VERSION/u);
  assert.match(handoff, /ledger_state_root/u);
  assert.match(handoff, /public_projection/u);
  assert.match(workflow, /usage_ledger_terminal_state_conflict/u);
  assert.doesNotMatch(
    source,
    /let _ = persist_runner_failure\(/u,
    "background delivery errors must never be discarded",
  );
});

test("handoff acknowledgements are path-free while private records retain bindings", () => {
  const ackStart = handoff.indexOf("pub fn ack_receipt");
  assert.notEqual(ackStart, -1);
  const ackBody = handoff.slice(ackStart, handoff.indexOf("\n}", ackStart) + 2);
  assert.match(ackBody, /"accepted": true/u);
  assert.doesNotMatch(ackBody, /mainConversationPath|conversationPath/u);
  assert.match(handoff, /child_conversation_binding/u);
  assert.match(handoff, /conversation_path/u);
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
