import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
// The OpenCode adapter package: the `opencode serve` HTTP and SSE protocol the
// Agent answers with, the parser that classifies it once, the registration
// composition injects, the arm that replays a recorded transcript, and the
// admission seam the client asks before it starts a turn. One package carries
// one Agent's protocol.
const packageRoot = "crates/licoup-agent-opencode";
const sourceRoot = `${packageRoot}/src`;
const packageFiles = Object.freeze([
  "bin/lico-agent-opencode",
  "contributions/adapter-status.json",
  "manifest.json",
  "package-release.json",
]);
// The process half the client still composes: the serve facade, its endpoint
// policy and the driver that supervises the endpoint. They read the package and
// own no vendor protocol of their own.
const processHalfFiles = Object.freeze([
  "crates/licoup-native/src/platform/opencode_serve.rs",
  "crates/licoup-native/src/platform/opencode_serve/policy.rs",
  "crates/licoup-native/src/platform/opencode_driver.rs",
  "crates/licoup-native/src/platform/opencode_driver/serve_transport.rs",
  "crates/licoup-native/src/platform/opencode_driver/continuity.rs",
  "crates/licoup-native/src/platform/opencode_driver/probe.rs",
]);
const compositionPath =
  "crates/licoup-native/src/platform/native_agent_parser/adapters/mod.rs";
const replayCompositionPath =
  "crates/licoup-native/src/platform/native_agent_parser/replay/adapters/mod.rs";
const movedParserPath =
  "crates/licoup-native/src/platform/native_agent_parser/adapters/opencode.rs";
const admissionGate =
  "licoup_agent_opencode::port::execution::admits_execution()";

function read(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), "utf8");
}

function exists(relativePath) {
  try {
    readFileSync(path.join(repoRoot, relativePath));
    return true;
  } catch {
    return false;
  }
}

test("one package carries the OpenCode serve protocol, its parser and its program", () => {
  const library = read(`${sourceRoot}/lib.rs`);
  assert.deepEqual(
    [...library.matchAll(/^pub mod ([a-z_]+);$/gmu)].map((match) => match[1]).sort(),
    ["parser", "port", "registration", "replay"],
  );
  // The parser declares the adapter contract exactly once, in this package, and
  // every entry point the serve path reads is the package's own.
  const parser = read(`${sourceRoot}/parser.rs`);
  assert.equal((parser.match(/AdapterContract::new\(/gu) ?? []).length, 1);
  assert.match(parser, /AdapterContract::new\("opencode", "http-sse"\)/u);
  for (const member of [
    "struct ServeEventParser",
    "fn session_id",
    "fn session_collection",
    "fn health_ready",
    "fn readiness",
    "fn message",
    "fn completed_transitions",
    "fn failure_transitions",
  ]) {
    assert.ok(parser.includes(member), `the parser does not own ${member}`);
  }
  // The parser is the interpreter, not the engine: it starts no process, opens
  // no socket and carries no HTTP client.
  for (const forbidden of [
    "std::process::Command",
    "TcpStream",
    "TcpListener",
    "reqwest",
    "ureq",
    "std::net",
  ]) {
    assert.equal(parser.includes(forbidden), false,
      `the package may not open its own route to the Agent: ${forbidden}`);
  }
  // Nothing in the package reaches a client crate.
  for (const file of [
    "lib.rs",
    "parser.rs",
    "registration.rs",
    "replay.rs",
    "port/mod.rs",
    "port/execution.rs",
    "bin/lico-agent-opencode.rs",
  ]) {
    assert.equal(read(`${sourceRoot}/${file}`).includes("licoup_native"), false,
      `${file} reaches back into the client`);
  }
});

test("the committed package artifact is the one the host reads", () => {
  for (const file of packageFiles) {
    assert.ok(exists(`${packageRoot}/package/${file}`), `the payload is missing ${file}`);
  }
  const manifest = JSON.parse(read(`${packageRoot}/package/manifest.json`));
  assert.equal(manifest.id, "org.licoland.adapter.opencode");
  assert.equal(manifest.runtime.mode, "process");
  assert.equal(manifest.runtime.entry, "bin/lico-agent-opencode");
  assert.equal(manifest.runtime.runtimeRef, undefined);
  assert.deepEqual(manifest.profiles.map((profile) => profile.id), ["agent-execution"]);
  assert.deepEqual(manifest.profiles[0].capabilities, ["agent-execution.v1"]);
  const release = JSON.parse(read(`${packageRoot}/package/package-release.json`));
  assert.equal(release.packageId, manifest.id);
  assert.equal(release.packageVersion, manifest.version);
  assert.equal(release.converter.kind, "native-executable");
  assert.equal(release.converter.entry, manifest.runtime.entry);
  // The inbound format is the wire the package's parser reads, named by the
  // package rather than retyped in the release document.
  const registration = read(`${sourceRoot}/registration.rs`);
  const declared = registration.match(/PROTOCOL_FORMAT: &str = "([^"]+)"/u);
  assert.ok(declared, "the package declares the protocol it reads");
  assert.equal(release.converter.sourceFormat, declared[1]);
  assert.equal(release.converter.targetFormat, "licoup.conversation.v1");

  // The package owns no persisted data, and says so rather than leaving a
  // reader to infer it.
  assert.equal(manifest.conversion, undefined);
  assert.equal(manifest.extensions["org.licoland.adapter.opencode/persistentData"], "none");
  assert.equal(typeof manifest.extensions["org.licoland.adapter.opencode/persistentDataReason"],
    "string");
});

test("the client keeps the process half and reads the package's protocol", () => {
  for (const relativePath of processHalfFiles) {
    const source = read(relativePath);
    assert.ok(source.includes("opencode"),
      `${relativePath} is not part of the OpenCode process half`);
  }
  // The process half is the client's; the frame interpretation is not. No file
  // on this side re-reads a serve frame or keeps a second copy of the parser.
  for (const relativePath of processHalfFiles) {
    const source = read(relativePath);
    for (const forbidden of [
      "message.part.updated",
      "assistant_messages",
      "struct ServeEventParser",
      "AdapterContract::new",
    ]) {
      assert.equal(source.includes(forbidden), false,
        `${relativePath} keeps a copy of the package's protocol: ${forbidden}`);
    }
  }
  // What they read instead is the composition's own name for the package's
  // parser, so the frames are classified once and below the adapter port.
  assert.match(read("crates/licoup-native/src/platform/opencode_serve.rs"),
    /native_agent_parser::adapters::opencode/u);
  assert.match(read("crates/licoup-native/src/platform/opencode_serve/policy.rs"),
    /adapters::opencode::readiness/u);
  for (const relativePath of processHalfFiles.filter((file) => file.includes("opencode_driver/"))) {
    assert.match(read(relativePath), /adapters::opencode as serve_parser/u);
  }
});

test("the assignment this package reads is the host's, and the host installs it", () => {
  // The host owns the idle-admission decision and joins it to the package's
  // port once per process.
  const composition = read("crates/licoup-native/src/lib.rs");
  assert.match(composition, /licoup_agent_opencode::port::execution::install\(/u);
  assert.match(composition, /admits_execution: admits_agent_execution/u);
  // The client's own driver asks the package's port before it attaches, so a
  // turn started under the close-admission barrier is refused rather than run.
  const transport = read(
    "crates/licoup-native/src/platform/opencode_driver/serve_transport.rs");
  const gate = transport.indexOf(admissionGate);
  assert.notEqual(gate, -1, "the driver never asks the package's admission port");
  const attach = transport.indexOf("opencode_serve::ensure_attachment");
  assert.notEqual(attach, -1, "the driver no longer attaches through the serve facade");
  assert.ok(gate < attach,
    "the admission gate must be read before the endpoint is attached");
  assert.match(transport, /opencode_execution_admission_closed/u);
});

test("the moved protocol leaves no copy in the host and the composition keeps one entry", () => {
  assert.equal(exists(movedParserPath), false,
    "the host still carries a copy of the moved OpenCode parser");
  assert.equal(
    exists("crates/licoup-native/src/platform/native_agent_parser/replay/adapters/opencode.rs"),
    false,
    "the host still carries a copy of the moved OpenCode replay arm");
  const composition = read(compositionPath);
  assert.match(composition, /use licoup_agent_opencode::parser as opencode;/u);
  assert.doesNotMatch(composition, /mod opencode;/u);
  assert.doesNotMatch(composition, /AdapterContract::new\("opencode"/u,
    "the composition restates the package's adapter declaration");
  assert.match(composition, /licoup_agent_opencode::registration::REGISTRATION/u);
  const registrations = composition.slice(
    composition.indexOf("pub(in crate::platform) static REGISTRATIONS"),
    composition.indexOf("/// The parser registrations this host injects"),
  );
  assert.equal(
    (registrations.match(/licoup_agent_opencode::registration::REGISTRATION/gu) ?? []).length,
    1,
    "the composition declares the OpenCode parser more than once",
  );
  const replay = read(replayCompositionPath);
  assert.doesNotMatch(replay, /mod opencode;/u);
  assert.match(replay, /"opencode" => licoup_agent_opencode::replay::replay_arm\(adapter_id\)\?/u);
  // The parity evidence is the package's own: its corpus test drives this
  // package's registration and replay arm through the SDK harness.
  const corpus = read(`${packageRoot}/tests/replay_corpus.rs`);
  assert.match(corpus, /licoup_agent_opencode::registration::parser_set/u);
  assert.match(corpus, /replay_corpus\(/u);
});
