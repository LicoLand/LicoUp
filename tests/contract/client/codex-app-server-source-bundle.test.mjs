import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const facadePath = "crates/licoup-native/src/platform/codex_app_server.rs";
const moduleRoot = "crates/licoup-native/src/platform/codex_app_server";
const productionLeaves = Object.freeze([
  "config.rs",
  "contract.rs",
  "error.rs",
  "io.rs",
  "launch.rs",
  "limits.rs",
  "model.rs",
  "model_catalog.rs",
  "protocol.rs",
  "protocol/control.rs",
  "protocol/events.rs",
  "protocol/helpers.rs",
  "protocol/session.rs",
  "supervision.rs",
  "transport.rs",
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
  return Object.fromEntries(await Promise.all(leaves.map(async (leaf) => [
    leaf,
    await read(`${moduleRoot}/${leaf}`),
  ])));
}

test("Codex app-server uses a thin facade with no retired monolith", async () => {
  const facade = await read(facadePath);
  assert.deepEqual(
    [...facade.matchAll(/^mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((name) => name !== "tests")
      .sort(),
    ["config", "contract", "error", "io", "launch", "limits", "model", "model_catalog", "protocol", "supervision", "transport"],
  );
  for (const implementationToken of [
    "struct CodexProtocol",
    "struct ProtocolConfig",
    "Command::new",
    "fn run_protocol_loop",
    "fn read_protocol_messages",
  ]) {
    assert.equal(facade.includes(implementationToken), false);
  }
});

test("Codex protocol, state, events, and approval control have single owners", async () => {
  const sources = await readLeaves(productionLeaves);
  const joined = Object.values(sources).join("\n");
  const protocolFacade = sources["protocol.rs"];

  for (const moduleName of ["control", "events", "helpers", "session"]) {
    assert.ok(protocolFacade.includes(`mod ${moduleName};`));
  }
  assert.ok(sources["contract.rs"].includes('"codex-app-server-stdio-jsonrpc"'));
  assert.ok(sources["config.rs"].includes("ProtocolConfig::from_params") === false);
  assert.ok(sources["config.rs"].includes("fn from_params"));
  assert.ok(sources["protocol/session.rs"].includes('"thread/start"'));
  assert.ok(sources["protocol/session.rs"].includes('"thread/resume"'));
  assert.ok(sources["protocol/session.rs"].includes('"turn/start"'));
  assert.ok(sources["protocol/events.rs"].includes('"turn/completed"'));
  assert.ok(sources["protocol/events.rs"].includes("matches_current_ids"));
  assert.ok(sources["protocol/control.rs"].includes("ProtocolFailure::user_interaction"));
  assert.ok(sources["error.rs"].includes('message: &\'static str'));
  assert.ok(sources["protocol/session.rs"].includes("self.session_id = Some(thread_id.to_string())"));

  for (const duplicatedCodec of ["AcpProtocol", "AcpSessionPlan", '"session/new"']) {
    assert.equal(joined.includes(duplicatedCodec), false);
  }
  for (const retiredModulePattern of ["#[path", "include!(", "mod tests {"]) {
    assert.equal(joined.includes(retiredModulePattern), false);
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
