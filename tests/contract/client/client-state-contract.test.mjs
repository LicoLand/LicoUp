import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(path, "utf8");

test("client state bridge has one generated typed path and no raw Dart CLI twin", () => {
  const schema = JSON.parse(read("schemas/client_bridge/state.json"));
  const manifest = JSON.parse(read("schemas/client_bridge/manifest.json"));
  const family = manifest.families.find(({ id }) => id === "state");
  assert.equal(family.status, "active");
  // Three operations are declared, and only `get` and `set` carry generated bridge
  // types: `state admit` is a command-layer operation reached through the command
  // table, not through the typed bridge. Asserting that explicitly keeps the pin
  // honest instead of letting the declared set and the generated surface drift.
  assert.deepEqual(schema.operations, ["get", "set", "admit"]);
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
  // `admit` stays a command-table operation: it must not grow a bridge type
  // without a deliberate change to the schema, the generator pin and this test.
  assert.doesNotMatch(rust, /ClientStateAdmit/);
  assert.doesNotMatch(dart, /ClientStateAdmit/);

  const actions = read(
    "apps/desktop/lib/src/platform/native_client/native_state_actions.dart",
  );
  // The typed gateway may wrap the call across lines; the invariant is that it
  // goes through `executeStructured` with the bridge operation name, and never
  // through a raw CLI invocation.
  assert.match(actions, /executeStructured\(\s*['"]state\.get['"]/);
  assert.match(actions, /executeStructured\(\s*['"]state\.set['"]/);
  assert.doesNotMatch(actions, /runCli|runCliWithStdin|\[['"]state['"]/);
  assert.doesNotMatch(actions, /Map<String,\s*dynamic>\s+get|Map<String,\s*dynamic>\s+set/);
});
