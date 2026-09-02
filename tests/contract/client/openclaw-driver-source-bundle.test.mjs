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
const parserRoot =
  "crates/licoup-native/src/platform/native_agent_parser/adapters/openclaw";

const driverLeaves = Object.freeze([
  "continuity.rs",
  "errors.rs",
  "execution.rs",
  "io.rs",
  "model.rs",
  "params.rs",
  "probe.rs",
  "supervision.rs",
]);
const parserLeaves = Object.freeze(["codec.rs", "events.rs", "protocol.rs"]);

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
      await read(`${parserRoot}/${leaf}`),
    ]),
  ]));
}

test("OpenClaw facade routes decoding leaves to the parser boundary", async () => {
  const facade = await read(`${driverRoot}.rs`);
  for (const leaf of driverLeaves) {
    assert.ok(facade.includes(`mod ${leaf.replace(".rs", "")};`));
  }
  for (const leaf of parserLeaves) {
    const moduleName = leaf.replace(".rs", "");
    assert.ok(facade.includes(`native_agent_parser/adapters/openclaw/${leaf}`));
    assert.ok(facade.includes(`mod ${moduleName};`));
  }
  for (const implementationToken of [
    "struct OpenClawProtocol",
    "struct ProtocolConfig",
    "Command::new",
    "fn run_protocol_loop",
    "include!(",
  ]) {
    assert.equal(facade.includes(implementationToken), false);
  }
});

test("OpenClaw retains one fixed Gateway ACP lane without shell fallback", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.ok(source["driver/model.rs"].includes(
    'RUNTIME_PROTOCOL: &str = "openclaw-acp-stdio-jsonrpc"',
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
  const continuity = source["driver/continuity.rs"];
  const params = source["driver/params.rs"];
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
  assert.ok(source["driver/errors.rs"].includes("message: &'static str"));
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

test("OpenClaw split contains no production unsafe or hidden compatibility include", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.equal(joined.includes("unsafe {"), false);
  assert.equal(joined.includes("include!("), false);
  assert.equal(joined.includes("#[path"), false);
});
