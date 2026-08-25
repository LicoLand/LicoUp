import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const facadePath = "crates/licoup-native/src/platform/kilo_code_serve.rs";
const root = "crates/licoup-native/src/platform/kilo_code_serve";

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

test("Kilo Code serve is a thin facade plus one target policy leaf", async () => {
  const facade = await read(facadePath);
  const policy = await read(`${root}/policy.rs`);
  assert.match(
    facade,
    /local_service::serve::ensure_attachment\(policy::SPEC, executable\)/u,
  );
  assert.equal(
    facade.includes("ensure_attach_endpoint"),
    false,
    "the facade must route through the readiness-checked attachment, not the retired endpoint-only attach",
  );
  assert.match(facade, /local_service::sse::watch_data/u);
  assert.match(facade, /adapters::kilo_code/u);
  assert.match(policy, /default_port: DEFAULT_PORT/u);
  assert.match(policy, /default_executable: "kilo"/u);
  assert.match(policy, /"kilo_code_serve_health_failed"/u);
  for (const forbidden of ["ureq::", "TcpListener", "read_state", "wait_for_health"])
    assert.equal(facade.includes(forbidden), false, forbidden);
});

test("Kilo Code target owns dedicated composition policy and event regressions", async () => {
  const entries = (await fs.readdir(path.join(repoRoot, root, "tests"))).sort();
  assert.deepEqual(entries, ["composition.rs", "events.rs", "mod.rs", "policy.rs"]);
  const events = await read(`${root}/tests/events.rs`);
  assert.match(events, /target_event_lane_projects_only_assistant_text_parts/u);
  assert.match(events, /ServeEventParser::new\("kilo-2"\)/u);
  assert.match(events, /missing_session/u);
});

test("Kilo Code facade never projects raw state or local executable paths", async () => {
  const sources = `${await read(facadePath)}\n${await read(`${root}/policy.rs`)}`;
  assert.equal(sources.includes('"state":'), false);
  assert.equal(sources.includes("stateDir"), false);
  assert.equal(sources.includes("unsafe {"), false);
});
