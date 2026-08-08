import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(path, "utf8");

test("client state bridge has one generated typed path and no raw Dart CLI twin", () => {
  const schema = JSON.parse(read("schemas/client_bridge/state.json"));
  const manifest = JSON.parse(read("schemas/client_bridge/manifest.json"));
  const family = manifest.families.find(({ id }) => id === "state");
  assert.equal(family.status, "active");
  assert.deepEqual(schema.operations, ["get", "set"]);
  assert.equal(new Set(schema.collections).size, 15);

  const rust = read(
    "crates/licoup-native/src/ffi/generated/client_state.rs",
  );
  const dart = read(
    "apps/desktop/lib/src/contracts/generated/client_state.g.dart",
  );
  for (const symbol of [
    "ClientStateCollection",
    "ClientStateDocument",
    "ClientStateGetRequest",
    "ClientStateSetRequest",
    "ClientStateGetResult",
    "ClientStateSetResult",
    "ClientStateActivity",
    "ClientStateFailure",
  ]) {
    assert.match(rust, new RegExp(`\\b${symbol}\\b`));
    assert.match(dart, new RegExp(`\\b${symbol}\\b`));
  }

  const actions = read(
    "apps/desktop/lib/src/platform/native_client/native_state_actions.dart",
  );
  assert.match(actions, /executeStructured\(['"]state\.get['"]/);
  assert.match(actions, /executeStructured\(['"]state\.set['"]/);
  assert.doesNotMatch(actions, /runCli|runCliWithStdin|\[['"]state['"]/);
  assert.doesNotMatch(actions, /Map<String,\s*dynamic>\s+get|Map<String,\s*dynamic>\s+set/);
});
