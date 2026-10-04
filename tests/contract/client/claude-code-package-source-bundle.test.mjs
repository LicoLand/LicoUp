import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

// The Claude Code adapter is one Agent's program: its vendor protocol, its
// parser and the registration composition injects live in
// `licoup-agent-claude-code`, and the client keeps only the process half. This
// contract holds the two apart: what is the package's, what is the client's, and
// the fact that the package names no client crate at all.

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const packageRoot = "crates/licoup-agent-claude-code";
const protocolRoot = `${packageRoot}/src/protocol`;
const parserRoot = `${protocolRoot}/parser`;
const driverRoot = "crates/licoup-native/src/platform/claude_code_driver";

const protocolLeaves = Object.freeze([
  "control.rs",
  "failure.rs",
  "launch.rs",
  "mod.rs",
  "params.rs",
  "parser.rs",
  "settings.rs",
]);
const parserLeaves = Object.freeze(["adapter.rs", "events.rs", "state.rs"]);
const packageLeaves = Object.freeze(["lib.rs", "registration.rs", "replay.rs"]);
const driverLeaves = Object.freeze([
  "approval.rs",
  "control.rs",
  "execution.rs",
  "failure.rs",
  "io.rs",
  "launch.rs",
  "model.rs",
  "probe.rs",
  "reset.rs",
  "supervision.rs",
  "transport.rs",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function packageSources() {
  return Object.fromEntries(await Promise.all([
    ...packageLeaves.map(async (leaf) => [leaf, await read(`${packageRoot}/src/${leaf}`)]),
    ...protocolLeaves.map(async (leaf) => [leaf, await read(`${protocolRoot}/${leaf}`)]),
    ...parserLeaves.map(async (leaf) => [
      `parser/${leaf}`,
      await read(`${parserRoot}/${leaf}`),
    ]),
  ]));
}

async function driverSources() {
  return Object.fromEntries(await Promise.all(
    driverLeaves.map(async (leaf) => [leaf, await read(`${driverRoot}/${leaf}`)]),
  ));
}

test("the package carries one Agent's protocol and the client keeps the process", async () => {
  const [facade, sources] = await Promise.all([
    read(`${driverRoot}.rs`),
    driverSources(),
  ]);
  // The client's Claude Code file is a composition, not an implementation: it
  // declares the process leaves it still owns and names the package for the
  // protocol.
  assert.deepEqual(
    [...facade.matchAll(/^(?:pub\(in crate::platform\) )?mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((moduleName) => moduleName !== "tests")
      .map((moduleName) => `${moduleName}.rs`)
      .sort(),
    [...driverLeaves].sort(),
  );
  for (const movedModule of ["command", "errors", "params", "native_agent_parser"]) {
    assert.equal(
      facade.includes(`mod ${movedModule};`),
      false,
      `${movedModule} moved with the protocol and is not a client module`,
    );
  }
  assert.ok(
    facade.includes("licoup_agent_claude_code::protocol"),
    "the client names the package for the protocol it reads",
  );
  for (const implementationToken of ["include!(", "#[path"]) {
    assert.equal(facade.includes(implementationToken), false);
  }
  // The client carries no copy of the protocol: the leaves that moved are gone.
  for (const movedLeaf of ["command.rs", "errors.rs", "params.rs"]) {
    assert.equal(
      Object.hasOwn(sources, movedLeaf),
      false,
      `${movedLeaf} is no longer a client leaf`,
    );
  }
  assert.equal(
    sources["model.rs"].includes("struct EffectiveSettings"),
    false,
    "the effective settings are the package's vocabulary",
  );
  assert.equal(
    sources["model.rs"].includes("struct CapabilityProbe"),
    false,
    "the capability facts are the package's vocabulary",
  );
  assert.equal(
    sources["launch.rs"].includes("struct DriverConfig"),
    false,
    "the launch configuration is the package's vocabulary",
  );
});

test("the package names no client crate and reparses no raw vendor detail", async () => {
  const sources = await packageSources();
  const joined = Object.values(sources).join("\n");
  // Documentation may name the boundary it keeps; code may not cross it. A
  // block doc comment opens with `/*!` or `/**` and continues on lines that do
  // not start with a comment marker, so the markers are dropped and the
  // remaining lines are checked.
  const code = Object.entries(sources)
    .flatMap(([leaf, source]) => source
      .split("\n")
      .map((line) => line.replace(/\/\/.*$/u, ""))
      .filter((line) => !/^\s*(?:\*|\/\*)/u.test(line))
      .map((line) => `${leaf}: ${line}`))
    .join("\n");
  for (const clientPath of [
    "crate::platform",
    "licoup_native",
    "licoup-native",
    "licoup_agent_drivers",
  ]) {
    assert.equal(
      code.includes(clientPath),
      false,
      `the package must not reach into a client crate: ${clientPath}`,
    );
  }
  assert.equal(joined.includes("unsafe {"), false);
  for (const forbidden of ["include!(", "#[path"]) {
    assert.equal(joined.includes(forbidden), false);
  }
});

test("the protocol has one owner for framing, launch identity and failure", async () => {
  const sources = await packageSources();
  assert.ok(sources["parser.rs"].includes('AdapterContract::new("claude-code", "lf-ndjson")'));
  assert.ok(sources["parser.rs"].includes("fn encode_message"));
  assert.ok(sources["parser.rs"].includes("fn user_message"));
  assert.ok(sources["parser.rs"].includes("fn steer_message"));
  assert.ok(sources["parser.rs"].includes("fn interrupt_request"));
  assert.ok(sources["parser.rs"].includes("fn permission_response"));
  assert.ok(sources["parser.rs"].includes("fn denied_control_response"));
  assert.ok(sources["parser.rs"].includes("fn completed_transitions"));
  assert.ok(sources["parser.rs"].includes("fn failure_transitions"));

  // The byte-line ingress is one implementation over the decoded state machine:
  // the adapter decodes, the state machine classifies, and neither duplicates
  // the other.
  assert.ok(sources["parser/adapter.rs"].includes("fn parse_line"));
  assert.ok(sources["parser/adapter.rs"].includes("self.state.handle(message)?"));
  assert.ok(sources["parser/state.rs"].includes("pub fn handle("));
  assert.equal(sources["parser/state.rs"].includes("serde_json::from_slice"), false);

  // The launch identity carries the vendor lane, and it never writes the prompt
  // onto argv.
  assert.ok(sources["launch.rs"].includes('"--print"'));
  assert.ok(sources["launch.rs"].includes('"--input-format"'));
  assert.ok(sources["launch.rs"].includes('"--output-format"'));
  assert.ok(sources["launch.rs"].includes('"--include-partial-messages"'));
  assert.ok(sources["launch.rs"].includes('"--resume"'));
  assert.ok(sources["launch.rs"].includes('"--model"'));
  assert.ok(sources["launch.rs"].includes('"--effort"'));
  assert.ok(sources["launch.rs"].includes('"--permission-mode"'));
  assert.ok(sources["launch.rs"].includes('"--allowedTools"'));
  assert.ok(sources["launch.rs"].includes('"--append-system-prompt"'));
  assert.equal(sources["launch.rs"].includes("Command::new"), false);
  assert.ok(sources["params.rs"].includes("stdin_message"));
  assert.ok(sources["failure.rs"].includes("message: &'static str"));
  assert.ok(sources["failure.rs"].includes("fn into_payload"));
  assert.ok(sources["control.rs"].includes("struct PermissionRequest"));
});

test("the parser reports the signals and settles nothing", async () => {
  const sources = await packageSources();
  const state = sources["parser/state.rs"];
  const adapter = sources["parser/adapter.rs"];
  assert.ok(state.includes("claude_code_authentication_required"));
  assert.ok(state.includes("claude_code_turn_cancelled"));
  assert.ok(state.includes("claude_code_session_mismatch"));
  assert.ok(state.includes("claude_code_invalid_json") || adapter.includes("claude_code_invalid_json"));
  assert.ok(state.includes("ProtocolFinishReport"));
  assert.equal(state.includes("fn settle"), false);
  assert.equal(/\btimeout\b/u.test(state), false, "the parser imposes no turn timeout");
  assert.ok(state.includes("mark_cancel_requested"));
  assert.ok(sources["parser/events.rs"].includes("processing_evidence_kind"));
  assert.ok(sources["parser/events.rs"].includes("partial_text_delta"));
  // The turn-event bus is the host's consumer; the package must not invent one.
  assert.ok(state.includes("turn_event_emit::"));
  assert.equal(state.includes("thread_local!"), false);
});

test("the registration answers the SDK queries and the replay arm drives the real parser", async () => {
  const sources = await packageSources();
  assert.ok(sources["registration.rs"].includes('ADAPTER_ID: &str = "claude-code"'));
  assert.ok(sources["registration.rs"].includes('FRAMING: &str = "lf-ndjson"'));
  assert.ok(sources["registration.rs"].includes(
    "pub const REGISTRATION: ParserRegistration",
  ));
  assert.ok(sources["registration.rs"].includes("fn execution_transitions("));
  assert.ok(sources["registration.rs"].includes("fn valid_identity("));
  assert.ok(sources["registration.rs"].includes("crate::replay::replay_arm"));

  assert.ok(sources["replay.rs"].includes("impl FrameReplay for Replay"));
  assert.ok(sources["replay.rs"].includes("ClaudeCodeParser::new("));
  assert.ok(sources["replay.rs"].includes("parser.parse_line("));
  assert.ok(sources["replay.rs"].includes('"agent-to-client"'));
  assert.ok(sources["registration.rs"].includes("pub const fn parser_set"));
});

test("the five recorded Claude Code transcripts are the package's own corpus", async () => {
  const scenarios = [
    "normal-turn",
    "user-cancel",
    "agent-error",
    "streaming-interruption",
    "native-resume",
  ];
  for (const scenario of scenarios) {
    const document = JSON.parse(
      await read(`apps/desktop/test/fixtures/adapter-replay/claude-code/${scenario}.json`),
    );
    assert.equal(document.adapterId, "claude-code");
    assert.equal(document.scenario, scenario);
    // The channel the fixtures record is the framing the package declares, so a
    // corpus cannot pass against another channel.
    for (const frame of document.frames) {
      assert.equal(frame.channel, "lf-ndjson", `${scenario} frame ${frame.index}`);
    }
  }
});

test("the committed package documents describe the program this crate builds", async () => {
  const manifest = JSON.parse(await read(`${packageRoot}/package/manifest.json`));
  const release = JSON.parse(await read(`${packageRoot}/package/package-release.json`));
  assert.equal(manifest.id, "org.licoland.adapter.claude-code");
  assert.equal(manifest.runtime.mode, "process");
  assert.equal(manifest.runtime.entry, "bin/lico-agent-claude-code");
  assert.equal(manifest.runtime.runtimeRef, undefined);
  assert.equal(release.packageId, manifest.id);
  assert.equal(release.packageVersion, manifest.version);
  assert.equal(release.converter.kind, "native-executable");
  assert.equal(release.converter.entry, manifest.runtime.entry);
  assert.equal(release.converter.sourceFormat, "claude-code.stream-json.v1");
  assert.equal(release.converter.targetFormat, "licoup.conversation.v1");
  for (const permission of manifest.permissions) {
    assert.ok(permission.capability.startsWith(`${manifest.id}/`));
  }
  // The staged entry is present, is not a script, and is what the manifest names.
  const entry = await fs.readFile(path.join(repoRoot, `${packageRoot}/package/${manifest.runtime.entry}`));
  assert.equal(entry.subarray(0, 2).toString("utf8") === "#!", false);
  assert.ok(entry.length > 0);
});
