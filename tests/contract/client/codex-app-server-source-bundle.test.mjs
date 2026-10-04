import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
// The client keeps no Codex module at all since CODEX-PACKAGE moved the whole
// app-server into its adapter package. These two paths are the ones the move
// removed; the first test asserts they are gone rather than assuming it.
const kernelPlatformRoot = "crates/licoup-native/src/platform";
const retiredFacadePath = `${kernelPlatformRoot}/codex_app_server.rs`;
const retiredModuleRoot = `${kernelPlatformRoot}/codex_app_server`;
// One package carries one Agent: the wire half, the process half and the
// program an extension host starts.
const packageRoot = "crates/licoup-agent-codex/src";
const appServerRoot = `${packageRoot}/app_server`;
const driverRoot = `${appServerRoot}/driver`;
const parserRoot = `${packageRoot}/parser`;
const productionLeaves = Object.freeze([
  "active_control.rs",
  "io.rs",
  "launch.rs",
  "model_catalog.rs",
  "reserve.rs",
  "supervision.rs",
  "transport.rs",
]);
const protocolLeaves = Object.freeze([
  "config.rs",
  "contract.rs",
  "failure.rs",
  "limits.rs",
  "model.rs",
  "reserve.rs",
]);
const parserLeaves = Object.freeze([
  "control.rs",
  "events.rs",
  "helpers.rs",
  "session.rs",
]);
const testLeaves = Object.freeze([
  "config.rs",
  "control.rs",
  "events.rs",
  "io.rs",
  "launch.rs",
  "model_catalog.rs",
  "session.rs",
  "support.rs",
  "transport.rs",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function missing(relativePath) {
  try {
    await fs.stat(path.join(repoRoot, relativePath));
    return false;
  } catch {
    return true;
  }
}

async function readLeaves(leaves) {
  return Object.fromEntries(await Promise.all([
    ...leaves.map(async (leaf) => [leaf, await read(`${driverRoot}/${leaf}`)]),
    ["protocol.rs", await read(`${appServerRoot}.rs`)],
    ...protocolLeaves.map(async (leaf) =>
      [`protocol/${leaf}`, await read(`${appServerRoot}/${leaf}`)]),
    ["parser.rs", await read(`${parserRoot}.rs`)],
    ...parserLeaves.map(async (leaf) => [`parser/${leaf}`, await read(`${parserRoot}/${leaf}`)]),
  ]));
}

test("the client keeps no Codex module and the package owns the driver", async () => {
  // The retired client half is absent, not empty: neither the facade file nor
  // the module directory survives, so no second copy can drift from the
  // package's.
  assert.ok(await missing(retiredFacadePath), retiredFacadePath);
  assert.ok(await missing(retiredModuleRoot), retiredModuleRoot);
  const platformFacade = await read(`${kernelPlatformRoot}/mod.rs`);
  assert.equal(platformFacade.includes("mod codex_app_server;"), false);
  assert.equal(platformFacade.includes("codex_app_server::"), false);

  // The package declares the one driver module and the program the extension
  // host starts, and neither reaches back into the client.
  const appServerFacade = await read(`${appServerRoot}.rs`);
  assert.ok(appServerFacade.includes("pub mod driver;"));
  const program = await read(`${packageRoot}/bin/lico-agent-codex.rs`);
  for (const executionVerb of [
    "extension.initialize",
    "extension.ready",
    "agent.describe",
    "agent.execute",
    "agent.cancel",
    "extension.shutdown",
  ]) {
    assert.ok(program.includes(executionVerb), executionVerb);
  }
  assert.ok(program.includes("driver::execute"));
});

test("Codex protocol, state, events, and approval control have single owners", async () => {
  const sources = await readLeaves(productionLeaves);
  const joined = Object.values(sources).join("\n");
  const protocolFacade = sources["parser.rs"];

  for (const moduleName of ["control", "events", "helpers", "session"]) {
    assert.ok(protocolFacade.includes(`mod ${moduleName};`));
  }
  assert.ok(sources["protocol/contract.rs"].includes('"codex-app-server-stdio-jsonrpc"'));
  assert.ok(sources["protocol/config.rs"].includes("ProtocolConfig::from_params") === false);
  assert.ok(sources["protocol/config.rs"].includes("fn from_params"));
  assert.ok(sources["parser/session.rs"].includes('"thread/start"'));
  assert.ok(sources["parser/session.rs"].includes('"thread/resume"'));
  assert.ok(sources["parser/session.rs"].includes('"turn/start"'));
  assert.ok(sources["parser/events.rs"].includes('"turn/completed"'));
  assert.ok(sources["parser/events.rs"].includes("matches_current_ids"));
  assert.ok(sources["parser/control.rs"].includes("fn decline_server_request"));
  assert.ok(sources["parser/control.rs"].includes("ProtocolEffect::Send"));
  assert.equal(sources["parser/control.rs"].includes("ProtocolEffect::Fail"), false);
  assert.equal(sources["parser/control.rs"].includes("ProtocolFailure::user_interaction"), false);
  assert.ok(sources["protocol/failure.rs"].includes("message: &'static str"));
  assert.ok(sources["parser/session.rs"].includes("self.session_id = Some(thread_id.to_string())"));
  assert.ok(sources["parser.rs"].includes("fn parse_line"));
  assert.ok(sources["protocol/reserve.rs"].includes("authorized_luna_reserve_model"));
  assert.ok(sources["protocol/reserve.rs"].includes("ordinaryUsageAllowed"));
  assert.equal(sources["io.rs"].includes("serde_json::from"), false);

  for (const duplicatedCodec of ["AcpProtocol", "AcpSessionPlan", '"session/new"']) {
    assert.equal(joined.includes(duplicatedCodec), false);
  }
  for (const retiredModulePattern of ["#[path", "include!("]) {
    assert.equal(joined.includes(retiredModulePattern), false);
  }

  // The package owns the protocol and no part of the client: a client path in
  // the package's sources would be the kernel reaching back in through it.
  const packageSources = [
    sources["protocol.rs"],
    ...protocolLeaves.map((leaf) => sources[`protocol/${leaf}`]),
    ...parserLeaves.map((leaf) => sources[`parser/${leaf}`]),
    ...productionLeaves.map((leaf) => sources[leaf]),
  ].join("\n");
  for (const clientPath of ["crate::platform", "licoup_native", "licoup-native"]) {
    assert.equal(packageSources.includes(clientPath), false, clientPath);
  }
});

test("Codex transport stays bounded, supervised, and redacted", async () => {
  const sources = await readLeaves(productionLeaves);
  const ioSource = sources["io.rs"];
  const supervision = sources["supervision.rs"];
  const transport = sources["transport.rs"];
  const launch = sources["launch.rs"];

  for (const token of [
    "max_bytes",
    "StdoutLimitExceeded",
    "drain_stderr",
    "AtomicBool",
  ]) {
    assert.ok(ioSource.includes(token), `missing bounded IO token: ${token}`);
  }
  assert.ok(transport.includes("finish_protocol_transport"));
  // The execution entry is the package's, and it is public because the program
  // the extension host starts is what calls it.
  assert.ok(transport.includes("pub fn execute("));
  assert.ok(transport.includes("licoup_foundation::platform::process_supervisor"));
  for (const token of ["PROCESS_POLL_INTERVAL", "contextualize", "terminate_tree"]) {
    assert.ok(supervision.includes(token), `missing supervision token: ${token}`);
  }
  assert.ok(launch.includes('"app-server"'));
  assert.ok(launch.includes('"--stdio"'));
  assert.ok(launch.includes("apply_subagent_caller_context"));
  assert.equal(launch.includes("apply_mcp_runtime_root"), false);
  for (const rawProjection of [
    "stderr: String",
    "stderr: Vec",
    "String::from_utf8_lossy(&stderr",
    "read_to_string",
    "eprintln!",
  ]) {
    assert.equal(ioSource.includes(rawProjection), false);
    assert.equal(supervision.includes(rawProjection), false);
    assert.equal(transport.includes(rawProjection), false);
  }
});

test("Codex regressions remain independently selectable ordinary leaves", async () => {
  const entries = await fs.readdir(path.join(repoRoot, driverRoot, "tests"), {
    withFileTypes: true,
  });
  assert.deepEqual(
    entries
      .filter((entry) => entry.isFile() && entry.name.endsWith(".rs"))
      .map((entry) => entry.name)
      .sort(),
    [...testLeaves].sort(),
  );
  const testFacade = await read(`${driverRoot}/tests.rs`);
  assert.equal(testFacade.includes("mod tests {"), false);
  assert.equal(testFacade.includes("#[path"), false);
});
