import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const read = (relative) => readFileSync(path.join(root, relative), "utf8");

const manifest = JSON.parse(read("schemas/client_bridge/manifest.json"));
const contract = JSON.parse(read("schemas/client_bridge/strategy.json"));
const fixture = JSON.parse(
  read(
    "crates/licoup-native/tests/fixtures/adaptive_flywheel/synthetic-entry-worker.template.json",
  ),
);
const service = read("crates/licoup-native/src/domain/adaptive_flywheel/service.rs");
const reducer = read("crates/licoup-native/src/domain/adaptive_flywheel/reducer.rs");
const store = read("crates/licoup-native/src/domain/adaptive_flywheel/store.rs");
const packageImporter = read("crates/licoup-native/src/domain/adaptive_flywheel/package.rs");
const packageRuntime = packageImporter.split("#[cfg(test)]", 1)[0];
const strategyRuntime = read("crates/licoup-native/src/platform/strategy_runtime/mod.rs");
const strategyCommand = read("crates/licoup-native/src/ffi/commands/strategy.rs");
const conversation = read("crates/licoup-native/src/domain/client_conversation/mod.rs");

test("Adaptive Flywheel owns an independent active bridge", () => {
  assert.deepEqual(
    manifest.families.find((family) => family.id === "strategy"),
    {
      id: "strategy",
      status: "active",
      schema: "schemas/client_bridge/strategy.json",
      rustOutput: "crates/licoup-native/src/ffi/generated/strategy.rs",
      dartOutput: "apps/desktop/lib/src/contracts/generated/strategy.g.dart",
    },
  );
  for (const action of contract.actions) {
    assert.match(service, new RegExp(`"${action.replaceAll(".", "\\.")}"`, "u"));
  }
  assert.equal(contract.actions.includes("strategy.binding.replace"), true);
  assert.equal(contract.actions.some((action) => action.includes("install")), false);
  assert.match(strategyCommand, /StrategyService::open/u);
  assert.doesNotMatch(conversation, /AdaptiveFlywheel|FlywheelRun|SelectionMode/u);
});

test("strategy packages are immutable ZIP revisions with one Graph authority", () => {
  assert.match(packageRuntime, /extract_zip_safe/u);
  assert.match(packageRuntime, /workflow\.json/u);
  assert.match(packageRuntime, /scripts\//u);
  assert.match(packageRuntime, /revision_digest/u);
  assert.match(packageRuntime, /harden_read_only_tree/u);
  assert.match(packageRuntime, /synthetic_fixture_package_bytes/u);
  assert.match(packageRuntime, /verified_revision_content/u);
  assert.doesNotMatch(packageRuntime, /source\.zip/u);
  assert.doesNotMatch(packageRuntime, /builtin_strategy_identity/u);
  assert.doesNotMatch(packageRuntime, /licoup-basic/u);
  assert.equal(fixture.schema, "licoup.adaptive-flywheel.workflow.v1");
  assert.equal(fixture.initial, "authorize");
  assert.deepEqual(
    fixture.actorSlots.map((slot) => slot.id),
    ["entry", "worker-a"],
  );
  assert.equal(fixture.actorSlots.filter((slot) => slot.entry === true).length, 1);
  assert.doesNotMatch(JSON.stringify(fixture), /Focused acceptance|focused-acceptance/u);
});

test("the strategy catalog stays empty until a package is imported", () => {
  assert.doesNotMatch(service, /ensure_builtin_strategy/u);
  assert.doesNotMatch(service, /BUILTIN_STRATEGY_ID/u);
  assert.doesNotMatch(service, /licoup-basic/u);
  assert.doesNotMatch(packageRuntime, /licoup-basic/u);
  assert.doesNotMatch(packageImporter, /include_bytes![\s\S]{0,400}builtin-basic/u);
  assert.doesNotMatch(packageImporter, /resources\/adaptive_flywheel\/builtin/u);
  assert.doesNotMatch(service, /ensure_builtin_strategy|BUILTIN_STRATEGY_ID/u);
  assert.match(store, /PRIMARY KEY\(revision_digest, slot_id, ordinal\)/u);
  assert.doesNotMatch(service, /LicoUp Basic Strategy/u);
  assert.doesNotMatch(packageRuntime, /ensure_builtin_strategy/u);
  assert.doesNotMatch(packageRuntime, /BUILTIN_STRATEGY_ID/u);
  assert.match(store, /fn purge_retired_builtin_definitions/u);
  assert.match(store, /RETIRED_BUILTIN_DEFINITION_ID/u);
  assert.match(store, /licoup-basic/u);
  assert.match(store, /LicoUp Basic Strategy/u);
  assert.match(
    store,
    /pub fn list_definitions[\s\S]{0,240}purge_retired_builtin_definitions/u,
  );
  assert.equal(
    existsSync(
      path.join(
        root,
        "crates/licoup-native/resources/adaptive_flywheel/builtin-basic",
      ),
    ),
    false,
  );
  assert.equal(
    existsSync(
      path.join(
        root,
        "crates/licoup-native/resources/adaptive_flywheel/builtin",
      ),
    ),
    false,
  );
  const publish = read("tools/scripts/client-macos-release-publish.mjs");
  assert.doesNotMatch(publish, /builtin-basic|licoup-basic|LicoUp Basic Strategy/u);
});

test("runtimes are detected and bound without a desktop picker", () => {
  assert.match(service, /refresh_runtime_bindings/u);
  assert.match(service, /bind_detected_runtimes/u);
  assert.match(service, /compatible_id/u);
  assert.match(strategyRuntime, /fn compatible_id/u);
});

test("effect authority and expired lease recovery are transactionally fenced", () => {
  assert.match(store, /TransactionBehavior::Immediate/u);
  assert.match(store, /authorize_effect/u);
  assert.match(store, /recover_next_expired_command/u);
  assert.match(service, /verified_revision_content/u);
  assert.match(service, /authorize_effect/u);
  assert.doesNotMatch(strategyRuntime, /maxStdoutBytes/u);
});

test("imported graphs merge actor JSON and switch candidates without leaking paths", () => {
  assert.match(reducer, /merge_run_context/u);
  assert.match(reducer, /predecessorLocator/u);
  assert.match(reducer, /FallbackIssued/u);
  assert.match(strategyRuntime, /predecessor_locator/u);
  assert.match(strategyRuntime, /locatorUnavailable/u);
  assert.match(reducer, /strategy_workset_cycle/u);
  assert.match(reducer, /resume_session_id/u);
  assert.match(service, /MAX_ACTIVE_EFFECTS/u);
  assert.match(service, /recover_failed_effect/u);
});
