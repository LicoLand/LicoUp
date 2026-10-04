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
// The wire half, owned by the Pi adapter package since PI-PACKAGE moved it out
// of the kernel. One package carries one Agent's protocol; the client names the
// package for its vocabulary instead of keeping a second copy.
const packageRoot = "crates/licoup-agent-pi/src";

// The process half of the Pi driver, still composed by the client.
const productionLeaves = Object.freeze([
  "active_control.rs",
  "execution.rs",
  "io.rs",
  "probe.rs",
  "supervision.rs",
]);
// The protocol vocabulary the package owns: the failure shape, the effective
// settings, the launch configuration and the session records.
const packageDriverLeaves = Object.freeze([
  "errors.rs",
  "model.rs",
  "params.rs",
  "sessions.rs",
]);
const parserLeaves = Object.freeze(["events.rs", "protocol.rs"]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all([
    ["parser/pi.rs", await read(`${packageRoot}/parser.rs`)],
    ...productionLeaves.map(async (leaf) => [
      `driver/${leaf}`,
      await read(`${driverRoot}/${leaf}`),
    ]),
    ...packageDriverLeaves.map(async (leaf) => [
      `driver/${leaf}`,
      await read(`${packageRoot}/driver/${leaf}`),
    ]),
    ...parserLeaves.map(async (leaf) => [
      `parser/${leaf}`,
      await read(`${packageRoot}/parser/${leaf}`),
    ]),
  ]));
}

test("Pi driver facade is thin, names the package, and owns only the process", async () => {
  const facade = await read(`${driverRoot}.rs`);
  assert.deepEqual(
    [...facade.matchAll(/^(?:pub\(in crate::platform\) )?mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((moduleName) => moduleName !== "tests")
      .map((moduleName) => `${moduleName}.rs`)
      .sort(),
    [...productionLeaves].sort(),
  );
  // The protocol vocabulary is read from the package rather than declared here:
  // one Agent, one copy.
  assert.ok(facade.includes("licoup_agent_pi::driver"));
  for (const implementationToken of [
    "struct PiProtocol",
    "struct ProtocolConfig",
    "Command::new",
    "fn run_protocol_loop",
    "include!(",
    "#[path",
    // The vocabulary modules may not be re-declared beside the package that
    // owns them: a `mod model;` here would be a second copy.
    "mod errors;",
    "mod model;",
    "mod params;",
    "mod sessions;",
  ]) {
    assert.equal(facade.includes(implementationToken), false, implementationToken);
  }
});

test("Pi keeps the official fixed RPC JSONL lane without shell fallback", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  assert.ok(source["driver/model.rs"].includes('RUNTIME_PROTOCOL: &str = "pi-rpc-stdio-jsonl"'));
  assert.ok(source["driver/supervision.rs"].includes(
    'LAUNCH_ARGS: &[&str] = &["--mode", "rpc", "--offline"]',
  ));
  assert.ok(source["driver/supervision.rs"].includes("Command::new(&self.executable)"));
  assert.ok(source["parser/protocol.rs"].includes('"type": "switch_session"'));
  assert.ok(source["parser/protocol.rs"].includes('"type": "prompt"'));
  assert.ok(source["driver/probe.rs"].includes('"--version"'));
  assert.ok(source["driver/probe.rs"].includes('"--help"'));
  assert.ok(source["driver/probe.rs"].includes(".stdout(Stdio::null())"));
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

test("Pi exact-session resolution is complete and header parsing fails closed", async () => {
  const source = await sources();
  const activeControl = source["driver/active_control.rs"];
  const sessions = source["driver/sessions.rs"];
  const protocol = source["parser/protocol.rs"];
  for (const token of [
    "MAX_SESSION_HEADER_BYTES",
    "resolve_session_path_in_roots",
    "session_roots_from_sources",
    "pi_session_identity_ambiguous",
    "pi_session_not_found",
    "pi_session_header_line_too_large",
  ]) {
    assert.ok(sessions.includes(token), `missing Pi session boundary: ${token}`);
  }
  assert.equal(sessions.includes("MAX_SESSION_SCAN_FILES"), false);
  for (const token of [
    "switch_session",
    "pi_session_identity_mismatch",
    "pi_session_id_missing",
  ]) {
    assert.ok(protocol.includes(token), `missing Pi continuity boundary: ${token}`);
  }
  assert.ok(source["driver/params.rs"].includes("resolve_session_path(&requested_session_id)"));
  for (const token of [
    "MAX_ACTIVE_TURNS",
    "ACK_TIMEOUT",
    "expected_turn_id",
    "ControlDisposition::NoActiveTurn",
    "recv_timeout",
    "steer_is_bound_to_the_exact_active_turn",
  ]) {
    assert.ok(activeControl.includes(token), `missing Pi active-turn boundary: ${token}`);
  }
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
  assert.ok(source["driver/errors.rs"].includes("message: &'static str"));
  assert.ok(source["parser/events.rs"].includes("sanitized_event"));
  assert.ok(source["parser/pi.rs"].includes("decode_jsonl_line"));
  assert.ok(source["parser/pi.rs"].includes("classify_steer_response"));
  assert.ok(source["parser/pi.rs"].includes("session_header_has_id"));
  assert.ok(source["driver/params.rs"].includes("pi_private_instructions_unsupported"));
  assert.equal(source["parser/protocol.rs"].includes("privateInstructions"), false);
  assert.equal(source["driver/io.rs"].includes("serde_json::from_str"), false);
  assert.equal(source["driver/sessions.rs"].includes("serde_json::from_str"), false);
  assert.equal(source["driver/execution.rs"].includes('.get("type")'), false);
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

  // The package owns the protocol and no part of the client: a client path in
  // the package's sources would be the kernel reaching back in through it.
  const packageSources = [
    source["parser/pi.rs"],
    ...parserLeaves.map((leaf) => source[`parser/${leaf}`]),
    ...packageDriverLeaves.map((leaf) => source[`driver/${leaf}`]),
  ].join("\n");
  for (const clientPath of ["crate::platform", "licoup_native", "licoup-native"]) {
    assert.equal(packageSources.includes(clientPath), false, clientPath);
  }
});
