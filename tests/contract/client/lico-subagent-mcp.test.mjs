import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(path, "utf8");
const application = read("crates/licoup-native/src/domain/subagent_mcp/mod.rs");
const engine = read("crates/licoup-native/src/core/mcp/server.rs");
const core = read("crates/licoup-native/src/core/mcp.rs");
const connector = read("crates/licoup-native/src/bin/lico-subagent-mcp.rs");
const supervisor = read("crates/licoup-native/src/platform/subagent_mcp_supervisor.rs");
const runtime = read("crates/licoup-agent-runtime/src/lib.rs");
const adapters = read("crates/licoup-agent-adapters/src/lib.rs");
const claims = read("crates/licoup-conversation/src/store/dispatches.rs");
const providerRuntime = read(
  "crates/licoup-native/src/platform/runtime_adapters/subagent_mesh.rs",
);
const agentHubCatalog = read("crates/licoup-native/src/domain/agent_hub/catalog.rs");
const agentHubVersion = read("crates/licoup-native/src/domain/agent_hub/version_check.rs");
const schema = JSON.parse(read("schemas/subagent_mcp/subagent_mcp.schema.json"));

const TOOLS = [
  "lico_assistant_profiles",
  "lico_assistant_workflow_execute",
  "lico_assistant_workflow_inspect",
  "lico_assistant_workflow_cancel",
  "lico_subagents_list",
  "lico_subagent_probe",
  "lico_subagent_delegate",
  "lico_subagent_continue",
  "lico_subagent_cancel",
];

test("common application freezes protocol, server identity, and ordered catalog", () => {
  assert.match(application, /PROTOCOL_REVISION: &str = "2025-06-18"/u);
  assert.match(application, /SERVER_NAME: &str = "lico-up-subagents"/u);
  assert.match(application, /SERVER_VERSION: &str = "0.11.0"/u);
  const list = application.slice(
    application.indexOf("pub const TOOL_NAMES"),
    application.indexOf("pub fn server_definition"),
  );
  assert.deepEqual(
    [...list.matchAll(/"(lico_[^"]+)"/gu)].map((match) => match[1]),
    TOOLS,
  );
  assert.match(application, /"additionalProperties": false/u);
  assert.doesNotMatch(application, /RuntimeAdapter::Codex|RuntimeAdapter::Cursor/u);
  assert.equal(schema.properties.protocolRevision.const, "2025-06-18");
  assert.equal(schema.properties.tools.minItems, 9);
});

test("one parameterized engine owns framing, initialization, calls, and cancellation", () => {
  for (const marker of [
    "pub struct McpServerDefinition",
    "pub struct McpServerEngine",
    "notifications/cancelled",
    "tools/list",
    "tools/call",
    "Request cancelled",
  ]) assert.match(engine, new RegExp(marker.replaceAll("/", "\\/"), "u"));
  assert.match(core, /OUTBOUND_TRANSFER_PROTOCOL_REVISION/u);
  assert.doesNotMatch(core, /pub const PROTOCOL_REVISION/u);
  const conversationBinding = read(
    "crates/licoup-native/src/bin/lico-conversation-mcp.rs",
  );
  assert.match(conversationBinding, /McpServerEngine::new/u);
  assert.match(conversationBinding, /serve_stdio/u);
  assert.doesNotMatch(conversationBinding, /fn read_line_bounded|fn process_line/u);
});

test("connector is tool-free and performs one authenticated HTTP exchange", () => {
  assert.match(connector, /connector_exchange/u);
  assert.match(connector, /load_connector_discovery/u);
  const production = connector.slice(0, connector.indexOf("mod tests"));
  assert.doesNotMatch(production, /lico_subagent_delegate|tool_catalog|tools\/list/u);
  assert.doesNotMatch(connector, /retry|sleep|TcpListener/u);
  assert.match(supervisor, /Ipv4Addr::LOCALHOST/u);
  assert.match(supervisor, /authorization/u);
  assert.match(supervisor, /mcp-session-id/u);
  assert.match(supervisor, /MAX_HTTP_CONNECTIONS/u);
  assert.match(supervisor, /atomic_write_private_text_bounded/u);
});

test("caller and target ports meet only in one registry", () => {
  assert.match(runtime, /pub trait McpCallerIntegration/u);
  assert.match(runtime, /pub trait SubagentRuntimeAdapter/u);
  assert.match(runtime, /pub enum InstructionPolicy/u);
  assert.match(runtime, /pub fn reduce_readiness/u);
  assert.match(runtime, /pub fn reduce_execution_admission/u);
  assert.match(runtime, /pub struct ExecutionAdmissionEvidence/u);
  assert.match(adapters, /register_pair/u);
  assert.match(adapters, /BTreeMap<ProviderId/u);
  assert.match(providerRuntime, /production_subagent_registry/u);
  for (const provider of ["codex", "cursor", "antigravity"]) {
    assert.match(providerRuntime, new RegExp(`"${provider}"`, "u"));
  }
});

test("execution admission is independent of observational readiness", () => {
  assert.match(application, /reduce_execution_admission/u);
  assert.match(providerRuntime, /executable_message_send_route/u);
  assert.match(providerRuntime, /available_runtime_executable/u);
  assert.doesNotMatch(application, /subagent_readiness_rejected/u);
  assert.doesNotMatch(providerRuntime, /permission_ready: transport_ready/u);
});

test("Agent Hub probes the exact private target binding with the existing parser", () => {
  assert.match(agentHubCatalog, /executable_binding/u);
  assert.match(agentHubVersion, /binding_belongs_to_agent/u);
  assert.match(agentHubVersion, /run_probe\(executable_binding, args\)/u);
  assert.match(agentHubVersion, /parse_output/u);
});

test("durable authority rejects unsafe lineage before adapter effects", () => {
  for (const code of [
    "subagent_self_call_rejected",
    "subagent_caller_membership_inactive",
    "subagent_target_membership_inactive",
    "subagent_duplicate_active_edge",
    "subagent_cross_conversation_rejected",
    "subagent_lineage_cycle",
    "subagent_repeated_ancestor",
    "subagent_depth_exceeded",
  ]) assert.match(claims, new RegExp(code, "u"));
  assert.match(claims, /TransactionBehavior::Immediate/u);
  assert.match(application, /claim_dispatch[\s\S]*runtime\.send/u);
  assert.match(application, /ReconciliationRequired/u);
});

test("generated guidance is adapter-declared and old visible markup is retired", () => {
  const dispatch = read(
    "crates/licoup-native/src/bin/licoup/stdio_rpc/server/conversation.rs",
  );
  assert.match(providerRuntime, /NativeDeveloperInstructions/u);
  assert.match(providerRuntime, /OrdinaryWirePrefix/u);
  assert.match(dispatch, /compose_generated_instruction_delivery/u);
  assert.doesNotMatch(application, /privateInstructions/u);
});

test("independent verification routes retain one target-keyed latest-version Manifest", () => {
  const en = read("docs/protocols/subagent-mcp.md");
  const zh = read("docs/protocols/subagent-mcp.zh-CN.md");
  const upstream = read("tests/product-e2e/cli/subagent-mcp/upstream.mjs");
  const downstream = read("tests/product-e2e/cli/subagent-mcp/downstream.mjs");
  const manifest = read("tests/product-e2e/cli/subagent-mcp/interop-manifest.mjs");
  for (const source of [en, zh]) {
    assert.match(source, /tests\/product-e2e\/cli\/subagent-mcp\/interop-manifest\.yaml/u);
    assert.match(source, /upstream\.mjs/u);
    assert.match(source, /downstream\.mjs/u);
  }
  assert.match(upstream, /Promise\.all/u);
  assert.match(downstream, /options\.live !== true/u);
  assert.match(downstream, /lico_subagent_delegate/u);
  assert.match(downstream, /projectStructuredMcpFailure/u);
  assert.match(downstream, /runtimeAvailable/u);
  assert.doesNotMatch(downstream, /conversationReadiness === "ready"/u);
  assert.match(downstream, /conversation\.subagent\.edge|readCanonicalEdge/u);
  assert.match(manifest, /TARGET_AGENTS/u);
  assert.match(manifest, /Results.*Notes/su);
});
