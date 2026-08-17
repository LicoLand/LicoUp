import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const read = (relative) => readFileSync(path.join(root, relative), "utf8");
const exists = (relative) => existsSync(path.join(root, relative));

const manifest = JSON.parse(read("schemas/client_bridge/manifest.json"));
const contract = JSON.parse(read("schemas/client_bridge/strategy.json"));
const fixture = JSON.parse(
  read(
    "crates/licoup-native/tests/fixtures/adaptive_flywheel/synthetic-entry-worker.fixture",
  ),
);

const TYPED_EVENTS = new Set(["complete", "success", "failure"]);
const EFFECT_FAMILIES = new Set([
  "authorization",
  "actor",
  "script",
  "workset",
]);
const TERMINAL_FAMILIES = new Set(["succeed", "fail", "blocked"]);

test("Adaptive Flywheel owns an independent active bridge", () => {
  const family = manifest.families.find(
    (candidate) => candidate.id === "strategy",
  );
  assert.equal(family.id, "strategy");
  assert.equal(family.status, "active");
  assert.equal(family.schema, "schemas/client_bridge/strategy.json");
  assert.equal(family.rustOutput.endsWith("ffi/generated/strategy.rs"), true);
  assert.equal(
    family.dartOutput.endsWith("contracts/generated/strategy.g.dart"),
    true,
  );
  assert.equal(exists(family.rustOutput), true);
  assert.equal(exists(family.dartOutput), true);
  for (const action of contract.actions) {
    assert.equal(action.startsWith("strategy."), true);
  }
  assert.equal(contract.actions.includes("strategy.binding.replace"), true);
  assert.equal(contract.actions.some((action) => action.includes("install")), false);
  assert.equal(contract.maxStates > 0, true);
  assert.equal(contract.maxTransitions > 0, true);
  assert.equal(contract.maxParallelism > 0, true);
  assert.equal(contract.maxRequestBytes > 0, true);
  assert.equal(contract.maxPackageBytes > 0, true);
  for (const kind of [
    "pass",
    "choice",
    "fork",
    "join",
    "authorization",
    "actor",
    "script",
    "workset",
    "succeed",
    "fail",
    "blocked",
  ]) {
    assert.equal(contract.stateKinds.includes(kind), true);
  }
});

test("synthetic entry/worker fixture is a typed single-entry workflow", () => {
  assert.equal(fixture.schema, "licoup.adaptive-flywheel.workflow.v1");
  assert.equal(fixture.initial, "authorize");
  assert.deepEqual(
    fixture.actorSlots.map((slot) => slot.id),
    ["entry", "worker-a"],
  );
  assert.equal(fixture.actorSlots.filter((slot) => slot.entry === true).length, 1);
  assert.equal(fixture.states.length >= 1, true);
  const stateIds = fixture.states.map((state) => state.id);
  assert.equal(new Set(stateIds).size, stateIds.length);
  assert.equal(stateIds.includes(fixture.initial), true);
  const stateById = new Map(fixture.states.map((state) => [state.id, state]));
  const transitionIds = fixture.transitions.map((transition) => transition.id);
  assert.equal(new Set(transitionIds).size, transitionIds.length);
  for (const transition of fixture.transitions) {
    assert.equal(TYPED_EVENTS.has(transition.event), true);
    assert.equal(stateById.has(transition.from), true);
    assert.equal(stateById.has(transition.to), true);
  }
  for (const state of fixture.states) {
    const outgoing = fixture.transitions.filter(
      (transition) => transition.from === state.id,
    );
    if (EFFECT_FAMILIES.has(state.kind)) {
      assert.equal(
        outgoing.some((transition) => transition.event === "success"),
        true,
        `${state.id} must route success`,
      );
      assert.equal(
        outgoing.some((transition) => transition.event === "failure"),
        true,
        `${state.id} must route failure`,
      );
    } else if (TERMINAL_FAMILIES.has(state.kind)) {
      assert.equal(outgoing.length, 0, `${state.id} terminal has no outgoing edge`);
    }
  }
  assert.equal(fixture.limits.maxParallelism > 0, true);
  assert.equal(fixture.limits.maxWorksetItems > 0, true);
  assert.equal(fixture.limits.maxAttempts > 0, true);
  for (const state of fixture.states) {
    if (state.retry) {
      assert.equal(state.retry.maxAttempts > 0, true);
      assert.equal(state.retry.maxAttempts <= fixture.limits.maxAttempts, true);
    }
  }
  for (const workset of fixture.worksets) {
    assert.equal(typeof workset.itemBinding, "string");
    assert.equal(typeof workset.predecessorField, "string");
  }
  assert.equal(fixture.states.length <= contract.maxStates, true);
  assert.equal(fixture.transitions.length <= contract.maxTransitions, true);
  assert.equal(fixture.limits.maxParallelism <= contract.maxParallelism, true);
});

test("the catalog and fixture carry no built-in identity or focused acceptance", () => {
  const fixtureText = JSON.stringify(fixture);
  assert.doesNotMatch(fixtureText, /builtin_strategy_identity/u);
  assert.doesNotMatch(fixtureText, /licoup-basic/u);
  assert.doesNotMatch(fixtureText, /Focused acceptance|focused-acceptance/u);
  const manifestText = JSON.stringify(manifest);
  assert.doesNotMatch(manifestText, /builtin_strategy_identity/u);
  assert.doesNotMatch(manifestText, /licoup-basic/u);
});

test("the bridge stays import-driven with bounded execution surfaces", () => {
  assert.equal(contract.actions.includes("strategy.package.prepare-import"), true);
  assert.equal(contract.actions.includes("strategy.package.commit-import"), true);
  assert.equal(contract.actions.includes("strategy.run.start"), true);
  assert.equal(contract.actions.includes("strategy.authorization.grant"), true);
  assert.equal(contract.failureCodes.includes("workflow_invalid"), true);
  for (const status of ["pending", "running", "blocked", "failed", "completed"]) {
    assert.equal(contract.runStatuses.includes(status), true);
  }
});
