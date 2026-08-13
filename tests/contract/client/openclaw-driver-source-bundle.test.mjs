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

const productionLeaves = Object.freeze([
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

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${driverRoot}/${leaf}`),
  ])));
}

test("OpenClaw driver facade is thin and owns every production leaf", async () => {
  const facade = await read(`${driverRoot}.rs`);
  assert.deepEqual(
    [...facade.matchAll(/^mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((moduleName) => moduleName !== "tests")
      .map((moduleName) => `${moduleName}.rs`)
      .sort(),
    [...productionLeaves].sort(),
  );
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
});

test("OpenClaw retains one fixed Gateway ACP lane without shell fallback", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.ok(source["model.rs"].includes(
    'RUNTIME_PROTOCOL: &str = "openclaw-acp-stdio-jsonrpc"',
  ));
  assert.ok(source["supervision.rs"].includes(
    'ATTACH_ARGS_PREFIX: &[&str] = &["acp", "--url"]',
  ));
  assert.ok(source["supervision.rs"].includes("Command::new(&self.executable)"));
  assert.ok(source["probe.rs"].includes('&["acp", "--help"]'));
  assert.ok(source["probe.rs"].includes('&["--version"]'));
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

test("OpenClaw continuity keeps protocol and resumable Gateway identities exact", async () => {
  const source = await sources();
  const continuity = source["continuity.rs"];
  const params = source["params.rs"];
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
  assert.ok(source["errors.rs"].includes("message: &'static str"));
  assert.ok(source["events.rs"].includes("projected_event"));
  assert.equal(source["protocol.rs"].includes("update.payload().clone()"), false);
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

test("OpenClaw split contains no production unsafe or hidden compatibility include", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.equal(joined.includes("unsafe {"), false);
  assert.equal(joined.includes("include!("), false);
  assert.equal(joined.includes("#[path"), false);
});
