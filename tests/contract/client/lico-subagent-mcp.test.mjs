import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const read = (path) => readFileSync(path, "utf8");
const application = read("crates/licoup-native/src/domain/subagents/mod.rs");
const production = read("crates/licoup-native/src/domain/subagents/production.rs");
const engine = read("crates/licoup-mcp/src/server.rs");
const library = read("crates/licoup-mcp/src/lib.rs");
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
const cliSurface = read("crates/licoup-native/src/ffi/commands/subagents.rs");
const commandTable = read("crates/licoup-native/src/ffi/commands/mod.rs");
const applicationPorts = read("crates/licoup-native/src/domain/application_port.rs");
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
  const dependencies = mcpCargo.split("[[bin]]")[0];
  const foundation = /^licoup-foundation = \{ path = "\.\.\/licoup-foundation" \}$/mu;
  assert.match(dependencies, foundation);
  assert.doesNotMatch(
    dependencies.replace(foundation, ""),
    /(?:licoup-[\w-]+\s*=|path\s*=|workspace\s*=)/u,
    "only neutral Foundation may be shared; runtime and domain authority stay behind the CLI",
  );
  assert.match(application, /"additionalProperties": false/u);
  assert.equal(schema.properties.protocolRevision.const, "2025-06-18");
  assert.equal(schema.properties.server.properties.version.const, "0.14.0");
  assert.equal(schema.properties.tools.minItems, TOOLS.length);
  assert.equal(schema.properties.tools.maxItems, TOOLS.length);
  assert.deepEqual(schema.properties.tools.prefixItems.map((item) => item.const), TOOLS);
});

test("delegated work is reached through the shared facade and nothing else", () => {
  // One door. The CLI surface decodes its own wire shape and hands the command
  // to the shared facade; a domain owner reached from here would be a second
  // path, and the MCP would stop sharing the CLI's semantics.
  const implementation = cliSurface.slice(0, cliSurface.indexOf("mod tests"));
  assert.match(implementation, /application_port::execute_as/u);
  assert.doesNotMatch(
    implementation,
    /production_application|subagents::local/u,
    "the CLI surface must not reach a domain owner directly",
  );
  // The ports behind the facade are the only place that names the owner, and
  // both delegated families have a real implementation there — a family that
  // only ever answers "unsupported" would be a door that leads nowhere.
  assert.match(applicationPorts, /impl ActorPort for/u);
  assert.match(applicationPorts, /impl SubagentPort for/u);
  assert.match(applicationPorts, /impl AssistantPort for/u);
  assert.match(applicationPorts, /production_application\(\)/u);
  assert.doesNotMatch(applicationPorts, /UnsupportedFamily|application_family_unsupported/u);
});

test("CLI and MCP meet at one argv envelope for the same tool call", () => {
  // The MCP crate deliberately shares no type with `licoup-native`, so the seam
  // the two interfaces meet at is the JSON the MCP puts on the CLI argv and the
  // CLI decodes. If one side renamed a field, the two interfaces would quietly
  // stop asking for the same thing.
  const mcpEnvelope = remoteApplication.slice(
    remoteApplication.indexOf("fn cli_invocation"),
    remoteApplication.indexOf("// Validate the closed scalar schemas"),
  );
  const cliEnvelope = cliSurface.slice(
    cliSurface.indexOf("struct Invocation"),
    cliSurface.indexOf("impl CallerScope"),
  );
  for (const field of ["name", "arguments", "caller"]) {
    assert.ok(mcpEnvelope.includes(`"${field}"`), `the MCP envelope names ${field}`);
    assert.ok(cliEnvelope.includes(field), `the CLI decodes ${field}`);
  }
  for (const field of [
    "provider_id",
    "conversation_id",
    "membership_id",
    "parent_dispatch_id",
  ]) {
    assert.ok(cliEnvelope.includes(field), `the CLI decodes ${field}`);
  }
  assert.match(cliEnvelope, /rename_all = "camelCase"/u);
  assert.match(mcpEnvelope, /"providerId"[\s\S]*caller\.provider_id/u);
  assert.match(mcpEnvelope, /"conversationId"[\s\S]*caller\.conversation_id/u);
  assert.match(mcpEnvelope, /"membershipId"[\s\S]*caller\.membership_id/u);
  assert.match(mcpEnvelope, /"parentDispatchId"[\s\S]*caller\.parent_dispatch_id/u);
  assert.match(mcpEnvelope, /insert_optional/u);
  assert.doesNotMatch(mcpEnvelope, /authenticated/u);
  // Both sides address the operation by the same tool name, and the MCP reaches
  // the CLI through the one route the facade serves.
  assert.match(remoteApplication, /"subagents"\.into\(\).*"execute"\.into\(\)/su);
  assert.match(
    commandTable,
    /path: &\["subagents", "execute"\][\s\S]*?handler: subagents::handle_subagents_execute/u,
  );
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

// The workspace dependency graph, read from Cargo rather than from a hand-kept
// list. Only normal and build edges are traversed: a dev-dependency is a test's
// own input and enters no binary.
function workspaceEdges() {
  const result = spawnSync("cargo",
    ["metadata", "--offline", "--no-deps", "--format-version", "1"], {
      cwd: repoRoot,
      encoding: "utf8",
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 60_000,
      maxBuffer: 64 * 1024 * 1024,
    });
  assert.equal(result.status, 0, `cargo metadata must succeed: ${result.stderr}`);
  const metadata = JSON.parse(result.stdout);
  const members = new Set(metadata.workspace_members);
  const workspace = metadata.packages.filter((entry) => members.has(entry.id));
  const byName = new Map(workspace.map((entry) => [entry.name, entry]));
  return {
    workspace,
    byName,
    edges: new Map(workspace.map((entry) => [entry.name, entry.dependencies
      .filter((dependency) => dependency.kind !== "dev" && dependency.kind !== "build")
      .map((dependency) => dependency.name)
      .filter((name) => byName.has(name))])),
  };
}

function reachableFrom(edges, origin) {
  const seen = new Set();
  const queue = [origin];
  while (queue.length > 0) {
    const name = queue.shift();
    for (const next of edges.get(name) || []) {
      if (seen.has(next)) continue;
      seen.add(next);
      queue.push(next);
    }
  }
  return seen;
}

test("no kernel crate reaches the optional MCP payload, and the neutral engine stands alone", () => {
  const { workspace, edges } = workspaceEdges();
  const payload = "licoup-mcp";
  assert.ok(edges.has(payload), `${payload} is a workspace member`);

  // Dependency traversal, not a text search: no workspace member reaches the
  // optional payload along any chain of normal or build dependencies. The kernel
  // is a complete product without the package, and it does not link one.
  for (const member of workspace) {
    if (member.name === payload) continue;
    const closure = reachableFrom(edges, member.name);
    assert.equal(closure.has(payload), false,
      `${member.name} must not depend on the optional MCP payload`);
  }

  // The optional payload's own in-repo edges go one way, to the neutral
  // Foundation every crate may share, and nowhere else.
  assert.deepEqual([...edges.get(payload)].sort(), ["licoup-foundation"]);
  // A test-only reading of the host's contract does not become a link either:
  // the edge is a dev-dependency, and the traversal above never sees it.
  assert.equal(reachableFrom(edges, "licoup-native").has(payload), false);

  // The crate's own boundary is declared, not implied: the neutral engine is
  // built by default with the payload and on its own without it, and the
  // optional binary is not built at all without the feature.
  assert.match(mcpCargo, /\[features\]\n(?:.*\n)*?default = \["service"\]\nservice = \[\]/u);
  assert.match(mcpCargo, /required-features = \["service"\]/u);
  const neutral = ["pub mod wire;", "mod server;"];
  for (const declaration of neutral) {
    assert.ok(library.includes(declaration), declaration);
    assert.doesNotMatch(library,
      new RegExp(`#\\[cfg\\(feature = "service"\\)\\]\\s*${declaration}`, "u"),
      `${declaration} is the neutral layer and is not gated`);
  }
  for (const service of ["pub mod application;", "pub mod lifecycle;",
    "pub mod private_state;", "pub mod transport;"]) {
    assert.match(library,
      new RegExp(`#\\[cfg\\(feature = "service"\\)\\]\\s*${service}`, "u"),
      `${service} is the optional service payload and is gated`);
  }

  // The neutral MCP consumers live in the kernel and keep their own identity:
  // the service-neutral message adapter with its outbound transfer approval
  // gate, the bounded outbound HTTP transport, the approval plan store, and the
  // shared guide resource. None of them names the payload crate.
  const neutralOwners = [
    "crates/licoup-native/src/core/mcp.rs",
    "crates/licoup-native/src/core/mcp/wire.rs",
    "crates/licoup-native/src/core/mcp/transfer.rs",
    "crates/licoup-native/src/platform/mcp_streamable_http.rs",
    "crates/licoup-native/src/platform/mcp_approval_plan_store.rs",
    "crates/licoup-native/resources/licoup-guide/SKILL.md",
  ];
  for (const relative of neutralOwners) {
    const source = read(relative);
    assert.ok(source.length > 0, relative);
    assert.equal(source.includes("licoup_mcp"), false,
      `${relative} is a neutral owner and must not name the optional payload`);
    assert.equal(source.includes("licoup-mcp"), false,
      `${relative} is a neutral owner and must not name the optional payload`);
  }
  assert.match(read("crates/licoup-native/src/core/mcp.rs"), /Service-neutral/u);
  assert.match(read("crates/licoup-native/src/core/mcp.rs"), /McpExternalTransferGate/u);
  assert.match(read("crates/licoup-native/src/core/mcp.rs"), /DEFAULT_TRANSFER_APPROVAL_TTL/u);
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
