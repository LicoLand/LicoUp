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
const production = source.slice(0, source.indexOf("#[cfg(test)]"));
const stdioServer = read("crates/licoup-native/src/bin/licoup/stdio_rpc/server.rs");
const conversationStore = read(
  "crates/licoup-native/src/domain/client_conversation/store.rs",
);
const conversationService = read(
  "crates/licoup-native/src/domain/client_conversation/service.rs",
);
const strategyService = read("crates/licoup-native/src/domain/adaptive_flywheel/service.rs");
const conversationHost = read(
  "crates/licoup-native/src/bin/licoup/stdio_rpc/server/conversation.rs",
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

const FORBIDDEN_PRIVATE = [
  /prompt body/u,
  /secret_token/u,
  /authorization: Bearer/u,
  /<user-home>\/private-workspace-sentinel/u,
  /<windows-user-home>\\private-workspace-sentinel/u,
  /machine-id/u,
  /endpoint-token/u,
];

const ASSISTANT_TOOLS = [
  "lico_assistant_profiles",
  "lico_assistant_workflow_execute",
  "lico_assistant_workflow_inspect",
  "lico_assistant_workflow_cancel",
];

const SUBAGENT_TOOLS = [
  "lico_subagents_list",
  "lico_subagent_probe",
  "lico_subagent_delegate",
  "lico_subagent_continue",
  "lico_subagent_cancel",
];

test("MCP exposes the closed Assistant facade and direct Membership tools only", () => {
  for (const name of [...ASSISTANT_TOOLS, ...SUBAGENT_TOOLS]) {
    assert.match(source, new RegExp(`"${name}"`, "u"), name);
  }
  const names = source.slice(
    source.indexOf("fn tool_names()"),
    source.indexOf("fn validate_tool_arguments("),
  );
  assert.deepEqual(
    [...names.matchAll(/"(lico_[^"]+)"/gu)].map((match) => match[1]),
    [...ASSISTANT_TOOLS, ...SUBAGENT_TOOLS],
  );
  const catalog = source.slice(
    source.indexOf("fn tool_catalog()"),
    source.indexOf("fn closed_object("),
  );
  assert.match(catalog, /closed_object\(/u);
  assert.match(
    source.slice(
      source.indexOf("fn closed_object("),
      source.indexOf("fn bounded_string("),
    ),
    /additionalProperties": false/u,
  );
  assert.doesNotMatch(catalog, /conversationPath/u);
  assert.doesNotMatch(catalog, /sessionMode/u);
  assert.match(source, /MAX_PENDING_TOOL_CALLS: usize = 32/u);
  assert.match(source, /MAX_TOOL_WORKERS: usize = 8/u);
  for (const pattern of FORBIDDEN_PRIVATE) {
    assert.doesNotMatch(production, pattern, pattern.toString());
  }
});

test("Profile tools project only bounded conversation facts", () => {
  assert.match(conversationService, /conversation\.profile\.candidates/u);
  assert.doesNotMatch(conversationService, /conversation\.profile\.snapshots/u);
  const profileDoor = source.slice(
    source.indexOf("fn assistant_profiles("),
    source.indexOf("fn project_conversation_service_failure("),
  );
  assert.match(profileDoor, /ConversationService/u);
  assert.match(profileDoor, /service\s*\.\s*execute/u);
  assert.match(profileDoor, /"conversationId"/u);
  assert.match(profileDoor, /"filters"/u);
  assert.match(profileDoor, /project_conversation_service_failure/u);
  // Raw database messages, paths and adapter details never cross the owner.
  assert.match(
    source,
    /fn project_conversation_service_failure[\s\S]*conversation_state_unavailable/u,
  );
  assert.doesNotMatch(profileDoor, /runtime_conversation_path/u);
  assert.doesNotMatch(profileDoor, /sessionId/u);
});

test("Assistant workflow tools route through the persistent strategy host only", () => {
  for (const action of [
    "strategy.assistant.workflow.execute",
    "strategy.assistant.workflow.inspect",
    "strategy.assistant.workflow.cancel",
  ]) {
    assert.match(strategyService, new RegExp(action, "u"), action);
    assert.match(source, new RegExp(action, "u"), action);
  }
  assert.match(
    source,
    /execute_persistent_conversation_method\("strategy\.execute", &request\)/u,
  );
  assert.match(source, /fn assistant_workflow_request/u);
  assert.match(source, /fn ensure_designated_assistant_manager/u);
  assert.match(source, /fn ensure_assistant_run_manager/u);
  // The host must fail closed for Assistant Graph admission when no
  // persistent runtime is mounted.
  const requiresRuntime = stdioServer.slice(
    stdioServer.indexOf("fn strategy_requires_persistent_runtime"),
    stdioServer.indexOf("/// Open (once per portable data dir)"),
  );
  assert.match(requiresRuntime, /strategy\.assistant\.workflow\.execute/u);
  // Rejection keeps the stable preflight code; private host details never
  // cross the facade.
  assert.match(source, /fn project_graph_rejection/u);
  assert.match(source, /graph_preflight_rejected/u);
  assert.match(strategyService, /fn assistant_run_projection/u);
  const assistantProjection = strategyService.slice(
    strategyService.indexOf("fn assistant_run_projection"),
    strategyService.indexOf("fn validate_import_identity"),
  );
  assert.doesNotMatch(assistantProjection, /entrySessionId|allowedOperations/u);
  assert.doesNotMatch(assistantProjection, /generic\.get\("definition"\)/u);
  for (const pattern of FORBIDDEN_PRIVATE) {
    assert.doesNotMatch(production, pattern, pattern.toString());
  }
});

test("subagent delegation keeps exact topology-neutral Membership semantics", () => {
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
  assert.match(source, /agent\.conversation\.cancel/u);
  assert.match(source, /"licoup\.subagent\.receipt\.v2"/u);
  assert.doesNotMatch(dispatchDoor, /dispatch_lane_operation\("send"/u);
  assert.doesNotMatch(dispatchDoor, /prepare_runtime_dispatch/u);
  assert.doesNotMatch(dispatchDoor, /append_runtime_frame/u);
  assert.doesNotMatch(dispatchDoor, /finish_runtime_dispatch/u);
  assert.doesNotMatch(source, /create_dispatch/u);
  assert.match(conversationStore, /CREATE TABLE IF NOT EXISTS conversation_dispatches/u);
  assert.match(conversationStore, /latest_resumable_dispatch/u);
  assert.match(source, /conversation_dispatch_context/u);
  assert.match(source, /conversation_access_denied/u);
});

test("subagent readiness observation never sends Agent input", () => {
  assert.match(source, /"lico_subagent_probe"/u);
  assert.match(source, /licoup\.subagent\.readiness\.v1/u);
  const readinessDoor = source.slice(
    source.indexOf("fn probe_subagent("),
    source.indexOf("fn assistant_profiles("),
  );
  assert.match(readinessDoor, /targets::inspect_target_read_only/u);
  assert.match(readinessDoor, /agent\.conversation\.active/u);
  assert.match(readinessDoor, /execute_read_only_persistent_conversation_method/u);
  assert.doesNotMatch(readinessDoor, /targets::inspect_target\(/u);
  assert.match(readinessDoor, /"waitForChangeMs": 0/u);
  assert.match(readinessDoor, /"hostTransport"/u);
  assert.match(readinessDoor, /"hostActiveTurns"/u);
  assert.match(readinessDoor, /"integrationStatus"/u);
  assert.match(readinessDoor, /"conversationDriver"/u);
  assert.match(readinessDoor, /"conversationReadiness"/u);
  assert.match(readinessDoor, /"blockerCode"/u);
  assert.doesNotMatch(readinessDoor, /agent\.conversation\.dispatch/u);
  assert.doesNotMatch(readinessDoor, /"prompt"/u);
  assert.doesNotMatch(readinessDoor, /"text"/u);
  assert.doesNotMatch(readinessDoor, /"model"/u);
  assert.doesNotMatch(readinessDoor, /"reasoningEffort"/u);
  assert.doesNotMatch(readinessDoor, /"workingDirectory"/u);
  assert.doesNotMatch(readinessDoor, /"timeoutMs"/u);

  const activeObservationDoor = conversationHost.slice(
    conversationHost.indexOf("pub(super) fn active("),
    conversationHost.indexOf("fn record_event("),
  );
  assert.match(activeObservationDoor, /turn\.agent_id != agent/u);
  assert.match(activeObservationDoor, /terminal\.is_some\(\)/u);
  assert.doesNotMatch(activeObservationDoor, /append_runtime_frame/u);
});

test("driver-owned conversation cleanup remains framework-specific without role policy", () => {
  assert.match(cursorControl, /trash::delete\(&leaf\)/u);
  assert.match(cursorControl, /trash::delete\(&target\)/u);
  assert.match(antigravityControl, /trash::delete\(&brain\)/u);
});

test("Codex plugin readiness is packaged independently from workflow ownership", () => {
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
  assert.match(source, /ConversationService::open/u);
});
