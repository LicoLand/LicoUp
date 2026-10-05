import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
// The Agent's own half moved into its package: the protocol reader, the event
// parser and the endpoint policy belong to Kilo Code, not to the client.
const packageRoot = "crates/licoup-agent-kilo/src";
// What the client still owns is the engine the package's ports are answered
// with, plus the composition that runs one turn and the force-stop lane.
const facadePath = "crates/licoup-native/src/platform/kilo_code_host.rs";

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

test("Kilo Code serve is a thin facade plus one target policy leaf", async () => {
  const facade = await read(facadePath);
  const policy = await read(`${packageRoot}/policy.rs`);
  assert.match(
    facade,
    /local_service::serve::ensure_attachment\(kilo_serve_spec\(\), executable\)/u,
  );
  assert.equal(
    facade.includes("ensure_attach_endpoint"),
    false,
    "the facade must route through the readiness-checked attachment, not the retired endpoint-only attach",
  );
  assert.match(facade, /local_service::sse::watch_frames/u);
  assert.doesNotMatch(facade, /local_service::sse::watch_data/u);
  assert.match(facade, /licoup_agent_kilo::parser::readiness/u);
  assert.match(policy, /default_port: 4097/u);
  assert.match(policy, /default_executable: "kilo"/u);
  assert.match(policy, /"kilo_code_serve_health_failed"/u);
  for (const forbidden of ["ureq::", "TcpListener", "read_state", "wait_for_health"])
    assert.equal(facade.includes(forbidden), false, forbidden);
});

test("Kilo Code target owns dedicated composition policy and event regressions", async () => {
  // The event parser moved with the protocol it classifies, and its regression
  // moved with it: a fixture can only pass against the parser the package ships.
  const events = await read(`${packageRoot}/parser/serve.rs`);
  assert.match(events, /foreign_sessions_user_parts_and_reasoning_are_not_the_reply/u);
  assert.match(events, /ServeEventParser::new\("kilo-1"\)/u);
  assert.match(events, /message\.part\.updated/u);
  // The policy's own regression asserts the ports, paths and failure codes the
  // Agent owns rather than the engine's.
  const policy = await read(`${packageRoot}/policy.rs`);
  assert.match(policy, /policy_names_its_own_identity_ports_and_failures/u);
  assert.match(policy, /kilo_code_serve_stop_failed/u);
});

test("Kilo Code facade never projects raw state or local executable paths", async () => {
  const sources = `${await read(facadePath)}\n${await read(`${packageRoot}/policy.rs`)}`;
  assert.equal(sources.includes('"state":'), false);
  assert.equal(sources.includes("stateDir"), false);
  assert.equal(sources.includes("unsafe {"), false);
});

test("the client carries no second copy of the Kilo Code protocol", async () => {
  // The kernel keeps the engine and the composition; the Agent's protocol is
  // exactly one package away from it, and the client's own tree holds none of it.
  const composition = await read(
    "crates/licoup-native/src/platform/kilo_code_driver.rs",
  );
  assert.match(composition, /pub\(in crate::platform\) use licoup_agent_kilo::parser as parser;/u);
  const clientDriver = await read(
    "crates/licoup-native/src/platform/kilo_code_driver/execution.rs",
  );
  assert.match(clientDriver, /driver::execute_via_serve/u);
  assert.equal(
    clientDriver.includes("message.part.updated"),
    false,
    "the client must not classify a vendor stream frame of its own",
  );
  assert.equal(
    clientDriver.includes("struct ServeEventParser"),
    false,
    "the client must not keep a second copy of this Agent's parser",
  );
});
