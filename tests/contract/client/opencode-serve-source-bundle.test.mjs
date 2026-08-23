import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { openCodeWorkspaceUrl } from "../../product-e2e/cli/agent-conversations/support/gates/opencode-http.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const facadePath = "crates/licoup-native/src/platform/opencode_serve.rs";
const root = "crates/licoup-native/src/platform/opencode_serve";

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

test("OpenCode serve is a thin facade plus one target policy leaf", async () => {
  const facade = await read(facadePath);
  const policy = await read(`${root}/policy.rs`);
  assert.match(facade, /local_service::serve::ensure\(policy::SPEC/u);
  assert.match(facade, /local_service::serve::watch_session_events/u);
  assert.match(policy, /default_port: DEFAULT_PORT/u);
  assert.match(policy, /default_executable: "opencode"/u);
  assert.match(policy, /"opencode_serve_health_failed"/u);
  for (const forbidden of ["ureq::", "TcpListener", "read_state", "wait_for_health"])
    assert.equal(facade.includes(forbidden), false, forbidden);
});

test("OpenCode target owns dedicated composition policy and event regressions", async () => {
  const entries = (await fs.readdir(path.join(repoRoot, root, "tests"))).sort();
  assert.deepEqual(entries, ["composition.rs", "events.rs", "mod.rs", "policy.rs"]);
  const events = await read(`${root}/tests/events.rs`);
  assert.match(events, /target_event_lane_projects_only_assistant_text_parts/u);
  assert.match(events, /project_event\(&mut projection, "open-2", &event\.to_string\(\)\)/u);
  assert.match(events, /tool\.updated/u);
});

test("OpenCode facade never projects raw state or local executable paths", async () => {
  const sources = `${await read(facadePath)}\n${await read(`${root}/policy.rs`)}`;
  assert.equal(sources.includes('"state":'), false);
  assert.equal(sources.includes("stateDir"), false);
  assert.equal(sources.includes("unsafe {"), false);
});

test("OpenCode live regression uses official workspace query routing", () => {
  const url = new URL(openCodeWorkspaceUrl(
    "http://127.0.0.1:24173",
    ["session", "session/with space", "message"],
    "/workspace/with space",
  ));
  assert.equal(url.pathname, "/session/session%2Fwith%20space/message");
  assert.equal(url.searchParams.get("directory"), "/workspace/with space");
});
