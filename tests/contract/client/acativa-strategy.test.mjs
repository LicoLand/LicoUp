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

test("Acativa owns an independent active bridge", () => {
  const family = manifest.families.find(
    (candidate) => candidate.id === "strategy",
  );
  assert.equal(family.id, "strategy");
  assert.equal(family.status, "active");
  assert.equal(family.schema, "schemas/client_bridge/strategy.json");
  assert.equal(
    family.dartOutput.endsWith("contracts/generated/strategy.g.dart"),
    true,
  );
  assert.equal(family.rustOutput, undefined);
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

test("the catalog carries no built-in identity or focused acceptance", () => {
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
  assert.deepEqual([...contract.transitionModes].sort(), ["callback", "flow"]);
  assert.deepEqual([...contract.callbackDecisions].sort(), [
    "advance",
    "return",
    "terminate",
  ]);
  assert.equal(
    contract.diagnosticCodes.includes("workflow_flow_target_incomplete"),
    true,
  );
  assert.equal(
    contract.diagnosticCodes.includes("workflow_transition_mode_invalid"),
    true,
  );
  for (const status of ["pending", "running", "blocked", "failed", "completed"]) {
    assert.equal(contract.runStatuses.includes(status), true);
  }
});
