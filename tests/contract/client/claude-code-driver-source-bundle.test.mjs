import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const driverRoot = "crates/lico-client-native/src/platform/claude_code_driver";

const productionLeaves = Object.freeze([
  "command.rs",
  "control.rs",
  "errors.rs",
  "events.rs",
  "execution.rs",
  "io.rs",
  "model.rs",
  "params.rs",
  "probe.rs",
  "protocol.rs",
  "supervision.rs",
  "transport.rs",
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

test("Claude Code driver facade is thin and owns every production leaf", async () => {
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
    "struct TurnState",
    "struct PersistentTransport",
    "struct DriverConfig",
    "Command::new",
    "fn run_turn_loop",
    "include!(",
    "#[path",
  ]) {
    assert.equal(facade.includes(implementationToken), false);
  }
});

test("Claude Code keeps the fixed streaming-input lane without argv resume or shell fallback", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.ok(source["model.rs"].includes(
    'RUNTIME_PROTOCOL: &str = "claude-code-cli-stream-json"',
  ));
  for (const token of [
    '"--input-format"',
    '"stream-json"',
    '"--output-format"',
    '"--include-partial-messages"',
    '"--no-session-persistence"',
    "Command::new(&self.executable)",
  ]) {
    assert.ok(source["command.rs"].includes(token), `missing fixed command token: ${token}`);
  }
  assert.ok(source["params.rs"].includes("stdin_message"));
  for (const forbidden of [
    '"--resume"',
    '"--continue"',
    'Command::new("sh")',
    'Command::new("bash")',
    'Command::new("cmd")',
    'Command::new("powershell")',
  ]) {
    assert.equal(joined.includes(forbidden), false);
  }
});

test("Claude Code exact continuation remains bound to one bounded live transport", async () => {
  const source = await sources();
  for (const token of [
    "MAX_POOLED_TRANSPORTS",
    "MAX_TRACKED_SESSIONS",
    "lookup_session_transport",
    "bind_session",
    "has_live_session",
    "cleanup_session",
    "Arc::downgrade",
  ]) {
    assert.ok(source["supervision.rs"].includes(token), `missing supervisor token: ${token}`);
  }
  for (const token of [
    "expected_session_id",
    "observed_session_id",
    "claude_code_session_mismatch",
    "claude_code_session_id_missing",
  ]) {
    assert.ok(source["protocol.rs"].includes(token), `missing session token: ${token}`);
  }
  assert.ok(source["transport.rs"].includes("impl Drop for PersistentTransport"));
  assert.ok(source["transport.rs"].includes("finish_protocol_transport"));
});

test("Claude Code IO, events, controls, probe, and failures stay bounded and redacted", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  for (const token of [
    "MAX_PROTOCOL_LINE_BYTES",
    "LineLimitExceeded",
    "BoundedStdinWriter",
    "max_stdout",
    "max_stderr",
    "CONTROL_QUEUE_CAPACITY",
    "IO_THREAD_EXIT_GRACE",
    "claude_code_timeout",
    "PROCESS_POLL_INTERVAL",
  ]) {
    assert.ok(joined.includes(token), `missing bounded lifecycle token: ${token}`);
  }
  assert.ok(source["events.rs"].includes("project_event"));
  assert.ok(source["errors.rs"].includes("message: &'static str"));
  for (const rawProjection of [
    "stderr: String",
    "stderr: Vec",
    "String::from_utf8_lossy(&stderr",
    '"tool_input": message',
    '"message": message',
    '"session_id": message',
  ]) {
    assert.equal(joined.includes(rawProjection), false);
  }
});

test("Claude Code split contains no production unsafe or hidden compatibility include", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.equal(joined.includes("unsafe {"), false);
  assert.equal(joined.includes("include!("), false);
  assert.equal(joined.includes("#[path"), false);
});
