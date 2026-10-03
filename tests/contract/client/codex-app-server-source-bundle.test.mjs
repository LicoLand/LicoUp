import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
// The process half of the Codex driver, still composed by the client.
const facadePath = "crates/licoup-native/src/platform/codex_app_server.rs";
const moduleRoot = "crates/licoup-native/src/platform/codex_app_server";
// The wire half, owned by the Codex adapter package since CODEX-PACKAGE moved
// it out of the kernel. One package carries one Agent's protocol; the client
// names the package for its vocabulary instead of keeping a second copy.
const packageRoot = "crates/licoup-agent-codex/src";
const appServerRoot = `${packageRoot}/app_server`;
const parserRoot = `${packageRoot}/parser`;
const productionLeaves = Object.freeze([
  "active_control.rs",
  "io.rs",
  "launch.rs",
  "model_catalog.rs",
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

async function readLeaves(leaves) {
  return Object.fromEntries(await Promise.all([
    ...leaves.map(async (leaf) => [leaf, await read(`${moduleRoot}/${leaf}`)]),
    ["protocol.rs", await read(`${appServerRoot}.rs`)],
    ...protocolLeaves.map(async (leaf) =>
      [`protocol/${leaf}`, await read(`${appServerRoot}/${leaf}`)]),
    ["parser.rs", await read(`${parserRoot}.rs`)],
    ...parserLeaves.map(async (leaf) => [`parser/${leaf}`, await read(`${parserRoot}/${leaf}`)]),
  ]));
}

test("the client keeps a thin Codex facade and names the package for the protocol", async () => {
  const facade = await read(facadePath);
  assert.deepEqual(
    [...facade.matchAll(/^(?:pub\(in crate::platform\) )?mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((name) => name !== "tests")
      .sort(),
    ["active_control", "io", "launch", "model_catalog", "supervision", "transport"],
  );
  // The protocol vocabulary is read from the package rather than declared here:
  // one Agent, one copy.
  assert.ok(facade.includes("licoup_agent_codex::app_server"));
  for (const implementationToken of [
    "struct CodexProtocol",
    "struct ProtocolConfig",
    "Command::new",
    "fn run_protocol_loop",
    "fn read_protocol_messages",
    // The protocol modules may not be re-declared beside the package that owns
    // them: a `mod config;` here would be a second copy.
    "mod config;",
    "mod contract;",
    "mod limits;",
    "mod model;",
    "mod reserve;",
  ]) {
    assert.equal(facade.includes(implementationToken), false, implementationToken);
  }
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
  const entries = await fs.readdir(path.join(repoRoot, moduleRoot, "tests"), {
    withFileTypes: true,
  });
  assert.deepEqual(
    entries
      .filter((entry) => entry.isFile() && entry.name.endsWith(".rs"))
      .map((entry) => entry.name)
      .sort(),
    [...testLeaves].sort(),
  );
  const testFacade = await read(`${moduleRoot}/tests.rs`);
  assert.equal(testFacade.includes("mod tests {"), false);
  assert.equal(testFacade.includes("#[path"), false);
});
