import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(path, "utf8");
const application = read("crates/licoup-native/src/domain/subagents/mod.rs");
const production = read("crates/licoup-native/src/domain/subagents/production.rs");
const engine = read("crates/licoup-mcp/src/server.rs");
const core = read("crates/licoup-native/src/core/mcp.rs");
const connector = read("crates/licoup-mcp/src/connector.rs");
const transport = read("crates/licoup-mcp/src/transport.rs");
const remoteApplication = read("crates/licoup-mcp/src/application.rs");
const lifecycle = read("crates/licoup-native/src/platform/mcp_service_process.rs");
const mcpCargo = read("crates/licoup-mcp/Cargo.toml");
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
  "lico_subagents_list",
  "lico_subagent_probe",
  "lico_subagent_delegate",
  "lico_subagent_continue",
  "lico_subagent_cancel",
];

test("independent MCP freezes its protocol, identity, and five public operations", () => {
  assert.match(remoteApplication, /PROTOCOL_REVISION: &str = "2025-06-18"/u);
  assert.match(remoteApplication, /SERVER_NAME: &str = "lico-up-subagents"/u);
  assert.match(remoteApplication, /SERVER_VERSION: &str = "0.14.0"/u);
  const list = remoteApplication.slice(
    remoteApplication.indexOf("pub const REMOTE_TOOL_NAMES"),
    remoteApplication.indexOf("pub const TOOL_NAMES"),
  );
  assert.deepEqual(
    [...list.matchAll(/"(lico_[^"]+)"/gu)].map((match) => match[1]),
    TOOLS,
  );
  assert.match(remoteApplication, /REMOTE_TOOL_NAMES\.contains/u);
  assert.match(remoteApplication, /"subagents"\.into\(\).*"execute"\.into\(\)/su);
  assert.match(remoteApplication, /"rpc", "stdio"/u);
  assert.doesNotMatch(mcpCargo.split("[[bin]]")[0], /(?:licoup-native|licoup-conversation|licoup-agent-runtime|path\s*=|workspace\s*=)/u);
  assert.match(application, /"additionalProperties": false/u);
  assert.equal(schema.properties.protocolRevision.const, "2025-06-18");
  assert.equal(schema.properties.server.properties.version.const, "0.14.0");
  assert.equal(schema.properties.tools.minItems, TOOLS.length);
  assert.equal(schema.properties.tools.maxItems, TOOLS.length);
  assert.deepEqual(schema.properties.tools.prefixItems.map((item) => item.const), TOOLS);
});

test("independent engine owns inbound framing, initialization, calls, and cancellation", () => {
  for (const marker of [
    "pub struct McpServerDefinition",
    "pub struct McpServerEngine",
    "notifications/cancelled",
    "tools/list",
    "tools/call",
    "Request cancelled",
  ]) assert.ok(engine.includes(marker), marker);
  assert.match(core, /OUTBOUND_TRANSFER_PROTOCOL_REVISION/u);
  assert.match(lifecycle, /Command::new\(binary\)/u);
  assert.match(lifecycle, /"service",\s*action/u);
});

test("connector performs one authenticated HTTP exchange through the independent service", () => {
  assert.match(connector, /connector_exchange/u);
  assert.match(connector, /load_connector_discovery/u);
  const implementation = connector.slice(0, connector.indexOf("mod tests"));
  assert.doesNotMatch(implementation, /fn tool_catalog|fn call_tool|tools\/list/u);
  assert.doesNotMatch(connector, /thread::sleep|TcpListener/u);
  assert.match(transport, /Ipv4Addr::LOCALHOST/u);
  assert.match(transport, /authorization/u);
  assert.match(transport, /mcp-session-id/u);
  assert.match(transport, /MAX_HTTP_CONNECTIONS/u);
  assert.match(transport, /atomic_write_private_text_bounded/u);
});

test("mesh caller membership comes from the native registry through the CLI catalog", () => {
  assert.match(adapters, /pub fn caller_providers/u);
  assert.match(application, /pub fn caller_providers/u);
  assert.match(remoteApplication, /get\("callers"\)/u);
  assert.match(transport, /\.caller_providers\(\)/u);
  assert.match(connector, /published_callers/u);
  assert.match(production, /adapters: AdapterRegistry/u);
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
