import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const driverRoot = "crates/licoup-native/src/platform/pi_driver";

const productionLeaves = Object.freeze([
  "errors.rs",
  "events.rs",
  "execution.rs",
  "io.rs",
  "model.rs",
  "params.rs",
  "probe.rs",
  "protocol.rs",
  "sessions.rs",
  "supervision.rs",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${driverRoot}/${leaf}`),
  ])));
}

test("Pi driver facade is thin and owns every production leaf", async () => {
  const facade = await read(`${driverRoot}.rs`);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 30);
  assert.deepEqual(
    [...facade.matchAll(/^mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((moduleName) => moduleName !== "tests")
      .map((moduleName) => `${moduleName}.rs`)
      .sort(),
    [...productionLeaves].sort(),
  );
  for (const implementationToken of [
    "struct PiProtocol",
    "struct ProtocolConfig",
    "Command::new",
    "fn run_protocol_loop",
    "include!(",
    "#[path",
  ]) {
    assert.equal(facade.includes(implementationToken), false);
  }
});

test("Pi keeps the official fixed RPC JSONL lane without shell fallback", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.ok(source["model.rs"].includes('RUNTIME_PROTOCOL: &str = "pi-rpc-stdio-jsonl"'));
  assert.ok(source["supervision.rs"].includes(
    'LAUNCH_ARGS: &[&str] = &["--mode", "rpc", "--offline"]',
  ));
  assert.ok(source["supervision.rs"].includes("Command::new(&self.executable)"));
  assert.ok(source["protocol.rs"].includes('"type": "switch_session"'));
  assert.ok(source["protocol.rs"].includes('"type": "prompt"'));
  assert.ok(source["probe.rs"].includes('"--version"'));
  assert.ok(source["probe.rs"].includes('"--help"'));
  assert.ok(source["probe.rs"].includes(".stdout(Stdio::null())"));
  assert.ok(source["probe.rs"].includes(".stderr(Stdio::null())"));

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

test("Pi exact-session resolution remains bounded and fails closed", async () => {
  const source = await sources();
  const sessions = source["sessions.rs"];
  const protocol = source["protocol.rs"];
  for (const token of [
    "MAX_SESSION_SCAN_FILES",
    "MAX_HEADER_BYTES",
    "resolve_session_path_in_roots",
    "session_roots_from_sources",
    "pi_session_identity_ambiguous",
    "pi_session_not_found",
  ]) {
    assert.ok(sessions.includes(token), `missing Pi session boundary: ${token}`);
  }
  for (const token of [
    "switch_session",
    "pi_session_identity_mismatch",
    "pi_session_id_missing",
  ]) {
    assert.ok(protocol.includes(token), `missing Pi continuity boundary: ${token}`);
  }
  assert.ok(source["params.rs"].includes("resolve_session_path(&requested_session_id)"));
});

test("Pi IO, cleanup, events, and errors remain bounded and non-projecting", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  for (const token of [
    "BoundedStdinWriter",
    "StdoutLimitExceeded",
    "max_stdout",
    "max_stderr",
    "finish_protocol_transport",
    "TransportFinishFailure::Lifecycle",
    "finish_or_terminate_tree",
    "pi_rpc_timeout",
    "PROCESS_POLL_INTERVAL",
  ]) {
    assert.ok(joined.includes(token), `missing Pi bounded lifecycle token: ${token}`);
  }
  assert.ok(source["errors.rs"].includes("message: &'static str"));
  assert.ok(source["events.rs"].includes("sanitized_event"));
  for (const rawProjection of [
    "stderr: String",
    "stderr: Vec",
    "String::from_utf8_lossy(&stderr",
    '"arguments": message',
    '"message": message',
  ]) {
    assert.equal(joined.includes(rawProjection), false);
  }
});

test("Pi split contains no production unsafe or hidden compatibility include", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.equal(joined.includes("unsafe {"), false);
  assert.equal(joined.includes("include!("), false);
  assert.equal(joined.includes("#[path"), false);
});
