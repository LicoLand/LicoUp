import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
// The Hermes adapter package: the persistent ACP frame dialect the Agent
// answers with, the parser that classifies it once, the permission question it
// asks, the normalized transitions its turns reduce to, the registration
// composition injects and the arm that replays a recorded transcript. One
// package carries one Agent's protocol.
const packageRoot = "crates/licoup-agent-hermes";
const sourceRoot = `${packageRoot}/src`;
const packageFiles = Object.freeze([
  "bin/lico-agent-hermes",
  "contributions/adapter-status.json",
  "manifest.json",
  "package-release.json",
]);
// The composition above the adapter port, and the two places the Hermes dialect
// is installed and replayed from.
const compositionPath =
  "crates/licoup-native/src/platform/native_agent_parser/adapters/mod.rs";
const replayCompositionPath =
  "crates/licoup-native/src/platform/native_agent_parser/replay/adapters/mod.rs";
const dialectsPath = "crates/licoup-native/src/platform/runtime_adapters/dialects.rs";
const driversPath = "crates/licoup-native/src/platform/runtime_adapters/drivers.rs";
// The parser subtrees this package replaced. The host keeps no copy of any of
// them: the parser is the package's, and the two superseded files that once
// accompanied it were the shared ACP session engine's own copies.
const movedParserPaths = Object.freeze([
  "crates/licoup-native/src/platform/native_agent_parser/adapters/hermes.rs",
  "crates/licoup-native/src/platform/native_agent_parser/adapters/hermes/framing.rs",
  "crates/licoup-native/src/platform/native_agent_parser/adapters/hermes/protocol.rs",
  "crates/licoup-native/src/platform/native_agent_parser/replay/adapters/hermes.rs",
]);

function read(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), "utf8");
}

test("one package carries the Hermes dialect, its parser and its program", () => {
  const library = read(`${sourceRoot}/lib.rs`);
  assert.deepEqual(
    [...library.matchAll(/^pub mod ([a-z_]+);$/gmu)].map((match) => match[1]).sort(),
    ["dialect", "parser", "registration", "replay"],
  );
  // The replay arm is a test surface, so it is a feature rather than a
  // production module — and the feature is what the host's test build enables.
  assert.match(library, /#\[cfg\(any\(test, feature = "test-support"\)\)\]\npub mod replay;/u);
  // This package owns a protocol, not a host seam: the half that would need a
  // port is still the client's, so the package declares none.
  assert.equal(existsSync(path.join(repoRoot, `${sourceRoot}/port`)), false,
    "the package declares no port while the client composes Hermes' process half");
  assert.equal(library.includes("pub mod port;"), false);

  // The parser is the single ingress, and the dialect answers the transport port
  // with this package's own functions rather than re-implementing ACP semantics.
  const dialect = read(`${sourceRoot}/dialect.rs`);
  for (const member of [
    "decode_frame",
    "is_notification",
    "response_id_matches",
    "response_is_error",
    "session_update",
    "prompt_stop_reason",
    "initialize_response",
    "client_request",
    "permission_request",
    "completed_transitions",
    "failed_transitions",
  ]) {
    assert.match(dialect, new RegExp(`^\\s*${member}[,:]`, "mu"),
      `the dialect does not answer the transport port's ${member}`);
  }
  assert.match(dialect, /AcpParserRegistration/u);
  assert.match(dialect, /driver_id: DRIVER_ID/u);
  // Hermes is the one Agent whose permission question is projected rather than
  // shared: the summary and the tool list are this package's own facts.
  assert.match(dialect, /parser::permission_request/u);
  assert.match(dialect, /ProtocolPermissionRequest/u);
  // Hermes asks no client request over this profile, and states that rather
  // than borrowing another Agent's reader.
  assert.match(dialect, /pub fn no_client_request\(_: &Value\) -> Option<ProtocolClientRequest>/u);

  // The parser declares the adapter contract exactly once, in this package.
  const parser = read(`${sourceRoot}/parser.rs`);
  assert.equal((parser.match(/AdapterContract::new\(/gu) ?? []).length, 1);
  assert.match(parser, /AdapterContract::new\("hermes", "stdio-jsonrpc-acp"\)/u);
  // The two facts no other Agent owns: the permission question and the
  // transition vocabulary the host reads through the registration.
  assert.match(parser, /pub fn permission_request\(message: &Value\) -> Option<PermissionRequest>/u);
  assert.match(parser, /unit_id: "hermes:reply"/u);
  assert.match(parser, /pub fn completed_transitions\(output: &str\) -> Vec<Transition>/u);
  assert.match(parser, /pub fn failed_transitions\(code: &str, stage: &str, message: &str\)/u);

  // The registration answers the SDK's normalized-transition query with its own
  // builders and keeps the durable-identity query fail-closed. Both facts are
  // the semantics the host read before the parser moved, so a package that
  // answered neither would silently empty every Hermes turn's transitions.
  const registration = read(`${sourceRoot}/registration.rs`);
  assert.match(registration, /ParserRegistration::new\(\s*CONTRACT,\s*execution_transitions,\s*no_identity,?\s*\)/u);
  assert.match(registration, /pub fn execution_transitions\(outcome: &ExecutionOutcome<'_>\)/u);
  assert.match(registration, /pub fn no_identity\(_: &DurableIdentityRequest<'_>\) -> bool \{\s*false\s*\}/u);
  assert.doesNotMatch(registration, /ParserRegistration::unanswered\(/u,
    "Hermes' registration answers its transitions rather than declaring them unanswered");

  // Nothing in the package reaches a client crate.
  for (const file of ["lib.rs", "dialect.rs", "parser.rs", "registration.rs", "replay.rs",
    "bin/lico-agent-hermes.rs"]) {
    const source = read(`${sourceRoot}/${file}`);
    assert.equal(source.includes("licoup_native"), false,
      `${file} reaches back into the client`);
  }
});

test("the committed package artifact is the one the host reads", () => {
  for (const file of packageFiles) {
    assert.ok(existsSync(path.join(repoRoot, `${packageRoot}/package/${file}`)),
      `the payload is missing ${file}`);
  }
  const manifest = JSON.parse(read(`${packageRoot}/package/manifest.json`));
  assert.equal(manifest.id, "org.licoland.adapter.hermes");
  assert.equal(manifest.runtime.mode, "process");
  assert.equal(manifest.runtime.entry, "bin/lico-agent-hermes");
  assert.equal(manifest.runtime.runtimeRef, undefined);
  assert.deepEqual(manifest.profiles.map((profile) => profile.id), ["agent-execution"]);
  assert.deepEqual(manifest.profiles[0].capabilities, ["agent-execution.v1"]);
  const release = JSON.parse(read(`${packageRoot}/package/package-release.json`));
  assert.equal(release.packageId, manifest.id);
  assert.equal(release.packageVersion, manifest.version);
  assert.equal(release.converter.kind, "native-executable");
  assert.equal(release.converter.entry, manifest.runtime.entry);
  assert.equal(release.converter.sourceFormat, "hermes.acp.v1");
  assert.equal(release.converter.targetFormat, "licoup.conversation.v1");
  // The release declaration names the format the package's own dialect
  // publishes, so the document and the program cannot disagree.
  assert.match(read(`${sourceRoot}/dialect.rs`),
    /pub const PROTOCOL_FORMAT: &str = "hermes\.acp\.v1";/u);

  // The package owns no persisted data, and says so rather than leaving a
  // reader to infer it.
  assert.equal(manifest.conversion, undefined);
  assert.equal(manifest.extensions["org.licoland.adapter.hermes/persistentData"], "none");
  assert.equal(typeof manifest.extensions["org.licoland.adapter.hermes/persistentDataReason"],
    "string");
});

test("the moved Hermes parser leaves no copy in the host and the inventory keeps thirteen", () => {
  for (const relativePath of movedParserPaths) {
    assert.equal(existsSync(path.join(repoRoot, relativePath)), false,
      `the host still carries a copy of the moved Hermes parser: ${relativePath}`);
  }
  const composition = read(compositionPath);
  // The composition names the package's parser and registration, and declares no
  // module of its own for either.
  assert.ok(composition.includes("licoup_agent_hermes::parser as hermes"),
    "the composition does not compose the package's parser under the Hermes alias");
  assert.ok(composition.includes("licoup_agent_hermes::registration::REGISTRATION"),
    "the composition does not dispatch the package's own registration");
  assert.doesNotMatch(composition, /mod hermes;/u);
  // The transitions the host reads are the package's answer rather than a second
  // builder kept above the port.
  assert.equal(composition.includes("hermes_transitions"), false,
    "the composition keeps a second copy of Hermes' transition answer");
  assert.equal(composition.includes("hermes::CONTRACT"), false,
    "the composition restates the package's adapter declaration");
  assert.equal((composition.match(/ParserRegistration::(?:unanswered|new)\(/gu) ?? []).length, 7);
  const registrations = composition.slice(
    composition.indexOf("pub(in crate::platform) static REGISTRATIONS"),
    composition.indexOf("/// The parser registrations this host injects"),
  );
  // Seven declared entries plus the six packages' own registrations.
  assert.equal((registrations.match(/^\s{4}(?:ParserRegistration::\w+\(|licoup_agent_\w+::registration::REGISTRATION,)/gmu)
    ?? []).length, 13);

  // The replay arm moved with the parser: the composition builds it from the
  // package and declares no arm module for Hermes.
  const replay = read(replayCompositionPath);
  assert.ok(replay.includes("licoup_agent_hermes::replay::replay_arm"),
    "the replay composition does not build the package's Hermes arm");
  assert.doesNotMatch(replay, /mod hermes;/u);
  assert.equal(replay.includes("hermes::Replay"), false,
    "the replay composition keeps a second Hermes arm");
  // One arm per Agent, and the shared ACP arm is the one this file still
  // assembles.
  assert.equal((replay.match(/^\s{8}"[a-z-]+" =>/gmu) ?? []).length, 13);
  assert.equal((replay.match(/"copilot" =>/gu) ?? []).length, 1);
  assert.equal((replay.match(/"cursor" =>/gu) ?? []).length, 1);
  assert.equal((replay.match(/"deepseek-harness" =>/gu) ?? []).length, 1);
});

test("the persistent ACP dialect is installed from the package and named nowhere else", () => {
  const drivers = read(driversPath);
  // The dialect table installs the package's registration whole instead of
  // restating Hermes' members above the port.
  assert.ok(drivers.includes("licoup_agent_hermes::dialect::registration()"),
    "the dialect table does not install the package's Hermes dialect");
  assert.equal(drivers.includes("hermes::decode_frame"), false,
    "the dialect table restates a Hermes parser member");
  // The dialect identity has one authority: the table and the run path read the
  // package's own declaration rather than a second literal that could drift
  // away from the identity the transport resolves frames by.
  assert.equal(drivers.includes('"hermes-acp"'), false,
    "the composition restates the Hermes dialect identity");
  assert.equal((drivers.match(/licoup_agent_hermes::dialect::DRIVER_ID/gu) ?? []).length, 2);

  // The composition above the transport names no Hermes parser function of its
  // own: the projection Hermes' parser owns lives in the package.
  const dialects = read(dialectsPath);
  assert.equal(dialects.includes("hermes"), false,
    "the host still assembles a Hermes dialect projection");
  assert.equal(dialects.includes("native_agent_parser::adapters::hermes"), false);

  // The production caller is real: a Hermes turn's normalized transitions are
  // read from the registration the composition dispatches, which is the
  // package's own answer.
  const hermesRun = read(driversPath);
  assert.match(hermesRun, /registrations_parser\("hermes"\)/u);
  assert.match(hermesRun, /normalize_hermes\(/u);
  const normalization = read(
    "crates/licoup-agent-drivers/src/runtime_adapters/normalization.rs",
  );
  assert.match(normalization, /pub fn normalize_hermes\(/u);
  assert.match(normalization, /\(parser\.execution_transitions\)\(/u);
});
