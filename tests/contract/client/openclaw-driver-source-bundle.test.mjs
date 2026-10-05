// The OpenClaw adapter's source split, across the client and its package.
//
// OpenClaw's protocol vocabulary moved into `crates/licoup-agent-openclaw`: the
// Gateway ACP state machine, the byte-line codec, the allowlisted update
// projection, the run and failure vocabulary, the session continuity binding and
// the request validation. The client keeps the process half — the reviewed
// bounded capability probe, the Gateway attach, the bounded transport and the
// cleanup — and re-exports each moved leaf at its former path.
//
// This contract states that split: the client facade binds its own process
// leaves and no copy of the protocol, every moved leaf is one re-export of the
// package that owns it, the package reaches no client crate, and the process
// half still carries the fixed Gateway ACP lane, exact continuity, bounded IO,
// cleanup and privacy the client has always required.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const driverRoot = "crates/licoup-native/src/platform/openclaw_driver";
const packageRoot = "crates/licoup-agent-openclaw/src";

/// The leaves the client still composes: the process half plus the re-export
/// shims that keep the driver on one name.
const driverLeaves = Object.freeze([
  "codec.rs",
  "continuity.rs",
  "errors.rs",
  "events.rs",
  "execution.rs",
  "io.rs",
  "model.rs",
  "params.rs",
  "probe.rs",
  "protocol.rs",
  "supervision.rs",
]);

/// The leaves the package now owns.
const parserLeaves = Object.freeze(["codec.rs", "events.rs", "protocol.rs"]);
const vocabularyLeaves = Object.freeze([
  "continuity.rs",
  "errors.rs",
  "model.rs",
  "params.rs",
]);

/// The client leaves that re-export a package module rather than implement it.
const shimLeaves = Object.freeze([
  "codec.rs",
  "continuity.rs",
  "errors.rs",
  "events.rs",
  "model.rs",
  "params.rs",
  "protocol.rs",
]);

/// The client leaves that are still the reviewed process implementation.
const processLeaves = Object.freeze(["execution.rs", "io.rs", "probe.rs", "supervision.rs"]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all([
    ...driverLeaves.map(async (leaf) => [
      `driver/${leaf}`,
      await read(`${driverRoot}/${leaf}`),
    ]),
    ...parserLeaves.map(async (leaf) => [
      `parser/${leaf}`,
      await read(`${packageRoot}/parser/${leaf}`),
    ]),
    ["parser/root.rs", await read(`${packageRoot}/parser.rs`)],
    ...vocabularyLeaves.map(async (leaf) => [
      `vocabulary/${leaf}`,
      await read(`${packageRoot}/gateway_acp/${leaf}`),
    ]),
    ["gateway_acp.rs", await read(`${packageRoot}/gateway_acp.rs`)],
    ["gateway_acp/contract.rs", await read(`${packageRoot}/gateway_acp/contract.rs`)],
    ["gateway.rs", await read(`${packageRoot}/gateway.rs`)],
  ]));
}

test("OpenClaw facade binds its process leaves and re-exports the package protocol", async () => {
  const facade = await read(`${driverRoot}.rs`);
  for (const leaf of driverLeaves) {
    assert.ok(facade.includes(`mod ${leaf.replace(".rs", "")};`));
  }
  for (const implementationToken of [
    "struct OpenClawProtocol",
    "struct ProtocolConfig",
    "Command::new",
    "fn run_protocol_loop",
    "include!(",
    "#[path",
  ]) {
    assert.equal(facade.includes(implementationToken), false);
  }
  for (const leaf of shimLeaves) {
    const shim = await read(`${driverRoot}/${leaf}`);
    assert.ok(
      shim.includes("licoup_agent_openclaw"),
      `${leaf} must re-export the package that owns it`,
    );
    for (const owned of [
      "struct OpenClawProtocol",
      "impl ProtocolConfig",
      "struct SessionBinding",
      "Command::new",
      "include!(",
      "#[path",
    ]) {
      assert.equal(
        shim.includes(owned),
        false,
        `${leaf} must not keep a second implementation`,
      );
    }
  }
  for (const leaf of processLeaves) {
    const source = await read(`${driverRoot}/${leaf}`);
    assert.equal(
      source.includes("licoup_agent_openclaw"),
      false,
      `${leaf} is client process code and must not become a package re-export`,
    );
  }
});

test("OpenClaw retains one fixed Gateway ACP lane without shell fallback", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.ok(source["vocabulary/model.rs"].includes(
    'RUNTIME_PROTOCOL: &str = "openclaw-acp-stdio-jsonrpc"',
  ));
  // The published format identity the release declaration names is declared
  // once, in the package, beside the protocol it describes.
  assert.ok(source["gateway_acp/contract.rs"].includes(
    'PROTOCOL_FORMAT: &str = "openclaw.gateway-acp.v1"',
  ));
  assert.ok(source["driver/supervision.rs"].includes(
    'ATTACH_ARGS_PREFIX: &[&str] = &["acp", "--url"]',
  ));
  assert.ok(source["driver/supervision.rs"].includes("Command::new(&self.executable)"));
  assert.ok(source["driver/probe.rs"].includes('&["acp", "--help"]'));
  assert.ok(source["driver/probe.rs"].includes('&["--version"]'));
  assert.ok(source["driver/probe.rs"].includes(".stderr(Stdio::null())"));
  for (const fallback of [
    'Command::new("sh")',
    'Command::new("bash")',
    'Command::new("cmd")',
    'Command::new("powershell")',
    'args: ["run"]',
    'args: ["chat"]',
  ]) {
    assert.equal(joined.includes(fallback), false);
  }
});

test("OpenClaw continuity keeps protocol and resumable Gateway identities exact", async () => {
  const source = await sources();
  const continuity = source["vocabulary/continuity.rs"];
  const params = source["vocabulary/params.rs"];
  for (const token of [
    "SessionBinding",
    "capture_opening_update",
    "reconcile_open_response",
    "openclaw_acp_session_mismatch",
    "openclaw_acp_native_session_id_missing",
    "AcpSessionMethod::Load",
  ]) {
    assert.ok(continuity.includes(token), `missing OpenClaw continuity token: ${token}`);
  }
  assert.ok(params.includes('meta.insert("sessionKey"'));
  assert.ok(params.includes('meta.insert("requireExisting"'));
  // The one client fact the package may not reach arrives as an explicit lazy
  // argument, so the package names no client crate for it.
  assert.ok(params.includes("local_mcp"));
  assert.equal(params.includes("crate::domain"), false);
  assert.equal(params.includes("acp_servers_for_runtime"), false);
  assert.ok(
    source["driver/params.rs"].includes('acp_servers_for_runtime("openclaw")'),
    "the client answers the MCP registration at its own boundary",
  );
});

test("OpenClaw IO, cleanup, events, and errors stay bounded and non-projecting", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  for (const token of [
    "BoundedStdinWriter",
    "StdoutLimitExceeded",
    "max_stdout",
    "max_stderr",
    "finish_protocol_transport",
    "TransportFinishFailure::Lifecycle",
    "openclaw_acp_timeout",
    "PROCESS_POLL_INTERVAL",
  ]) {
    assert.ok(joined.includes(token), `missing OpenClaw lifecycle token: ${token}`);
  }
  assert.ok(source["vocabulary/errors.rs"].includes("message: &'static str"));
  assert.ok(source["parser/events.rs"].includes("projected_event"));
  assert.ok(source["parser/protocol.rs"].includes("handle_frame"));
  assert.equal(source["driver/io.rs"].includes("decode_message"), false);
  assert.equal(source["parser/protocol.rs"].includes("update.payload().clone()"), false);
  for (const rawProjection of [
    "stderr: String",
    "stderr: Vec",
    "combined.extend(stderr",
    "String::from_utf8_lossy(&stderr",
    '"rawInput": update',
    '"_meta": update',
  ]) {
    assert.equal(joined.includes(rawProjection), false);
  }
});

test("OpenClaw split contains no production unsafe or client reach from the package", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.equal(joined.includes("unsafe {"), false);
  assert.equal(joined.includes("include!("), false);
  assert.equal(joined.includes("#[path"), false);
  const packageOnly = Object.entries(source)
    .filter(([key]) => !key.startsWith("driver/"))
    .map(([, value]) => value)
    .join("\n");
  for (const clientReach of ["licoup_native", "crate::platform", "crate::domain"]) {
    assert.equal(
      packageOnly.includes(clientReach),
      false,
      `the OpenClaw adapter package must not reach the client: ${clientReach}`,
    );
  }
});
