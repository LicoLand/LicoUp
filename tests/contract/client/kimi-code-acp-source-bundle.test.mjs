import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
// The Kimi Code adapter package: the ACP frame dialect the Agent answers with,
// the parser that classifies it once, the driver half the shared ACP engine
// runs, the registration composition injects and the arm that replays a
// recorded transcript. One package carries one Agent's protocol.
const packageRoot = "crates/licoup-agent-kimi";
const sourceRoot = `${packageRoot}/src`;
const packageFiles = Object.freeze([
  "bin/lico-agent-kimi",
  "contributions/adapter-status.json",
  "manifest.json",
  "package-release.json",
]);
// The driver half still composed by the client. It reads the package and owns
// no vendor fact of its own.
const facadePath = "crates/licoup-native/src/platform/kimi_code_driver.rs";
// The shared ACP engine, which names no Agent.
const enginePath = "crates/licoup-agent-drivers/src/acp_driver_runtime";

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

test("one package carries the Kimi Code dialect, its parser and its program", () => {
  const library = read(`${sourceRoot}/lib.rs`);
  assert.deepEqual(
    [...library.matchAll(/^pub mod ([a-z_]+);$/gmu)].map((match) => match[1]).sort(),
    ["dialect", "driver", "parser", "port", "registration", "replay"],
  );
  // The replay arm is a test surface, so it is a feature rather than a
  // production module — and the feature is what the host's test build enables.
  assert.match(library, /#\[cfg\(any\(test, feature = "test-support"\)\)\]\npub mod replay;/u);

  // The parser is the single ingress: the dialect answers the transport port
  // with this package's own functions, and re-implements no ACP semantics.
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
  assert.match(dialect, /ldr_id: DRIVER_ID|driver_id: DRIVER_ID/u);

  // The parser declares the adapter contract exactly once, in this package.
  const parser = read(`${sourceRoot}/parser.rs`);
  assert.equal((parser.match(/AdapterContract::new\(/gu) ?? []).length, 1);
  assert.match(parser, /AdapterContract::new\("kimi-code", "lf-ndjson-acp"\)/u);

  // The driver half declares the launch metadata and delegates the engine, so
  // the package describes a Kimi execution without owning an ACP transport.
  const driver = read(`${sourceRoot}/driver.rs`);
  assert.match(driver, /AcpDriverSpec::new\(RUNTIME_PROTOCOL, &\["acp"\]\)/u);
  assert.match(driver, /with_identity\(crate::dialect::DRIVER_ID, "kimi_code_acp"\)/u);
  assert.match(driver, /execute_acp\(/u);
  assert.match(driver, /probe_acp\(/u);
  for (const forbidden of ["std::process::Command", "TcpStream", "reqwest", "ureq"]) {
    assert.equal(driver.includes(forbidden), false,
      `the package may not open its own route to the Agent: ${forbidden}`);
  }

  // Nothing in the package reaches a client crate.
  for (const file of ["lib.rs", "dialect.rs", "parser.rs", "driver.rs", "registration.rs",
    "replay.rs", "port/mod.rs", "port/execution.rs", "bin/lico-agent-kimi.rs"]) {
    const source = read(`${sourceRoot}/${file}`);
    assert.equal(source.includes("licoup_native"), false,
      `${file} reaches back into the client`);
  }
});

test("the committed package artifact is the one the host reads", () => {
  for (const file of packageFiles) {
    assert.ok(exists(`${packageRoot}/package/${file}`), `the payload is missing ${file}`);
  }
  const manifest = JSON.parse(read(`${packageRoot}/package/manifest.json`));
  assert.equal(manifest.id, "org.licoland.adapter.kimi");
  assert.equal(manifest.runtime.mode, "process");
  assert.equal(manifest.runtime.entry, "bin/lico-agent-kimi");
  assert.equal(manifest.runtime.runtimeRef, undefined);
  assert.deepEqual(manifest.profiles.map((profile) => profile.id), ["agent-execution"]);
  assert.deepEqual(manifest.profiles[0].capabilities, ["agent-execution.v1"]);
  const release = JSON.parse(read(`${packageRoot}/package/package-release.json`));
  assert.equal(release.packageId, manifest.id);
  assert.equal(release.packageVersion, manifest.version);
  assert.equal(release.converter.kind, "native-executable");
  assert.equal(release.converter.entry, manifest.runtime.entry);
  assert.equal(release.converter.sourceFormat, "kimi-code.acp.v1");
  assert.equal(release.converter.targetFormat, "licoup.conversation.v1");

  // The package owns no persisted data, and says so rather than leaving a
  // reader to infer it.
  assert.equal(manifest.conversion, undefined);
  assert.equal(manifest.extensions["org.licoland.adapter.kimi/persistentData"], "none");
  assert.equal(typeof manifest.extensions["org.licoland.adapter.kimi/persistentDataReason"],
    "string");
});

test("the client keeps a thin Kimi facade and names the package for the protocol", () => {
  const facade = read(facadePath);
  for (const packageToken of [
    "licoup_agent_kimi::driver::RUNTIME_PROTOCOL",
    "licoup_agent_kimi::driver::DRIVER",
    "licoup_agent_kimi::driver::capability_probe",
    "licoup_agent_kimi::driver::execute",
    "licoup_agent_kimi::driver::cancel",
  ]) {
    assert.ok(facade.includes(packageToken),
      `the client facade does not read the package's ${packageToken}`);
  }
  // No second copy of the vendor fact stays behind: the launch metadata, the
  // runtime protocol and the frame interpretation are the package's.
  for (const forbidden of [
    "AcpDriverSpec::new",
    "with_identity",
    "with_launch_settings",
    "with_allow_all_argument",
    "decode_json_line",
    "validate_session_update",
    "validate_prompt_response",
    "AdapterContract::new",
  ]) {
    assert.equal(facade.includes(forbidden), false,
      `the client facade keeps a copy of the package's protocol: ${forbidden}`);
  }
});

test("the shared ACP engine names no Agent and holds no Kimi branch", () => {
  const protocol = read(`${enginePath}/protocol.rs`);
  const port = read(`${enginePath}/parser_port.rs`);
  const replay = read(`${enginePath}/replay.rs`);
  // Kimi Code is named nowhere in the shared engine: the moved dialect reaches
  // the engines through the port and through the package's own arm, so no
  // vendor branch can reappear beside the shared reducer.
  for (const [name, source] of [["protocol", protocol], ["parser_port", port], ["replay", replay]]) {
    for (const agent of ["kimi", "codex", "hermes", "claude"]) {
      assert.equal(source.toLowerCase().includes(agent), false,
        `the shared ACP ${name} names the Agent ${agent}`);
    }
  }
  // The ACP profile's own state machine is a shared resource rather than a
  // vendor branch: the reducer reads the packaged machine and names no Agent.
  assert.match(protocol, /state_machines::copilot_protocol/u);
  // The dialect is resolved by the identity the transport is keyed on, never by
  // an Agent name.
  assert.match(port, /pub fn parser_for\(driver_id: &str\)/u);
  assert.match(protocol, /parser_port::parser_for\(driver_id\)/u);
  // An Agent's own package hands its dialect to the shared reducer rather than
  // the engine learning that Agent's name.
  assert.match(replay, /pub fn with_dialect\(registration: AcpParserRegistration\)/u);
});

test("the moved parser leaves no copy in the host and the inventory keeps thirteen", () => {
  assert.equal(exists("crates/licoup-native/src/platform/native_agent_parser/adapters/kimi_code.rs"),
    false, "the host still carries a copy of the moved Kimi parser");
  const composition = read(
    "crates/licoup-native/src/platform/native_agent_parser/adapters/mod.rs",
  );
  // The composition names no Kimi parser module: the package's own dialect
  // registration is what reaches the transport, and the parser registration is
  // the package's own value.
  assert.doesNotMatch(composition, /licoup_agent_kimi::parser/u);
  assert.doesNotMatch(composition, /mod kimi_code;/u);
  assert.equal((composition.match(/ParserRegistration::(?:unanswered|new)\(/gu) ?? []).length, 11);
  assert.match(composition, /licoup_agent_kimi::registration::REGISTRATION/u);
  assert.match(composition, /licoup_agent_codex::registration::REGISTRATION/u);
  const registrations = composition.slice(
    composition.indexOf("pub(in crate::platform) static REGISTRATIONS"),
    composition.indexOf("/// The parser registrations this host injects"),
  );
  // Eleven declared entries plus the two packages' own registrations.
  assert.equal((registrations.match(/^\s{4}(?:ParserRegistration::\w+\(|licoup_agent_\w+::registration::REGISTRATION,)/gmu)
    ?? []).length, 13);
});
