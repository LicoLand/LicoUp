import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const read = (relative) => readFileSync(path.join(root, relative), "utf8");

const manifest = JSON.parse(read("schemas/client_bridge/manifest.json"));
const contract = JSON.parse(read("schemas/client_bridge/strategy.json"));
const workflow = JSON.parse(
  read("crates/licoup-native/resources/adaptive_flywheel/builtin-basic/workflow.json"),
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
  assert.match(packageRuntime, /builtin_strategy_identity/u);
  assert.match(packageRuntime, /verified_revision_content/u);
  assert.doesNotMatch(packageRuntime, /source\.zip/u);
  assert.equal(workflow.schema, "licoup.adaptive-flywheel.workflow.v1");
  assert.equal(workflow.initial, "authorize");
  assert.deepEqual(
    workflow.actorSlots.map((slot) => slot.id),
    ["designer", "worker", "reviewer", "python"],
  );
  assert.doesNotMatch(JSON.stringify(workflow), /Focused acceptance|focused-acceptance/u);
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

test("the built-in basic strategy is a graph-driven automatic loop", () => {
  assert.equal(workflow.metadata.id, "licoup-basic");
  assert.doesNotMatch(JSON.stringify(workflow), /Better Plan/u);
  const kinds = new Set(workflow.states.map((state) => state.kind));
  for (const kind of ["authorization", "actor", "workset", "script", "succeed", "blocked"]) {
    assert.equal(kinds.has(kind), true, kind);
  }
  assert.equal(
    workflow.transitions.some((edge) => edge.from === edge.to),
    true,
    "review loop must be represented by a Graph back-edge",
  );
  assert.match(reducer, /predecessor_field/u);
  assert.match(reducer, /strategy_workset_cycle/u);
  assert.match(reducer, /resume_session_id/u);
  assert.match(service, /MAX_ACTIVE_EFFECTS/u);
});
