import assert from "node:assert/strict";
import test from "node:test";
import { CLIENT_MODULE_CATALOG } from "../../../tools/regression/client-module-catalog.mjs";
import { planClientRegressionBatches } from "../../../tools/regression/client-regression-batching.mjs";
import {
  defaultRegressionCapacities,
  nodeTestFileToolchain,
} from "../../../tools/regression/client-regression-metadata.mjs";
import {
  listContractClientTests,
  nodeOnlyContractTestFiles,
  sdkOwnedContractTestFiles,
} from "../../../tools/regression/client-contract-selection.mjs";
import { partitionModulesByRunnableHost, selectModulesById } from "../../../tools/regression/client-module-selection.mjs";
import { executeClientModules } from "../../../tools/regression/client-module-execution.mjs";
import { flutterTestInputPaths } from "../../../tools/regression/client-regression-toolchain-stats/flutter.mjs";

test("complete selection batches Node test files and Flutter suites before scheduling", () => {
  const batches = planClientRegressionBatches(CLIENT_MODULE_CATALOG, {
    catalog: CLIENT_MODULE_CATALOG,
    availableParallelism: 12,
  });
  assert.ok(batches.length < CLIENT_MODULE_CATALOG.length / 2);

  const nodeBatch = batches.find((batch) =>
    batch.toolchain === "node-test" && batch.members.length > 1);
  assert.ok(nodeBatch);
  assert.equal(nodeBatch.command.args[0], "--test");
  assert.equal(nodeBatch.command.args.includes("--test-concurrency=6"), true);
  assert.equal(nodeBatch.weight, 6);

  for (const flutter of batches.filter((batch) => batch.toolchain === "flutter")) {
    const separator = flutter.command.args.indexOf("--");
    const paths = flutter.command.args.slice(separator + 3).filter((value) =>
      !value.startsWith("--") && value.endsWith(".dart"));
    assert.ok(new Set(paths).size <= 64);
    if (flutter.attribution !== "files") continue;
    assert.ok(Array.isArray(flutter.inputOwners));
    const ownedIndexes = new Set(flutter.inputOwners.flatMap((owner) => owner.indexes));
    const inputs = flutterTestInputPaths(flutter.command);
    assert.deepEqual([...ownedIndexes].sort((left, right) => left - right),
      inputs.map((_, index) => index));
  }
});

test("focused selection keeps its exact module command", () => {
  const selected = selectModulesById(["packaging.macos"]);
  const [batch] = planClientRegressionBatches(selected, {
    catalog: CLIENT_MODULE_CATALOG,
  });
  assert.equal(batch.attribution, "exact");
  assert.deepEqual(batch.command, selected[0].command);
});

test("complete host selection keeps every runnable member in the planned batch set", () => {
  const { runnable, unsupported } = partitionModulesByRunnableHost(CLIENT_MODULE_CATALOG, "linux");
  const batches = planClientRegressionBatches(runnable, {
    catalog: runnable,
    excludedCatalog: unsupported,
  });
  assert.deepEqual(new Set(batches.flatMap((batch) => batch.members)),
    new Set(runnable.map((module) => module.id)));
});

test("executor uses one host partition for batching", async () => {
  const [one, two] = selectModulesById([
    "regression.release-workflow-contracts",
    "regression.agent-boundary-contracts",
  ]);
  const calls = [];
  const result = await executeClientModules([one, two], {
    repoRoot: ".", catalog: [one, two], host: "linux", output: { write() {} },
    async commandRunner(batch) {
      calls.push(batch);
      return { ...batch, status: "passed", reason: null, durationMs: 0 };
    },
  });
  assert.equal(result.exitCode, 0);
  assert.equal(calls.length, 1);
  assert.deepEqual([...calls[0].members].sort(),
    ["regression.agent-boundary-contracts", "regression.release-workflow-contracts"]);
});

test("retry planning narrows every failed aggregate member to an exact command", () => {
  const selected = selectModulesById([
    "regression.release-workflow-contracts",
    "regression.agent-boundary-contracts",
    "regression.test-artifact-lifecycle",
    "regression.public-client-docs",
  ]);
  const batches = planClientRegressionBatches(selected, {
    catalog: CLIENT_MODULE_CATALOG,
    narrow: true,
  });
  assert.equal(batches.length, selected.length);
  assert.equal(batches.every((batch) =>
    batch.attribution === "exact" && batch.members.length === 1), true);
  assert.deepEqual(batches.map((batch) => batch.command),
    selected.map((module) => module.command));
});

test("no batch reserves the retired Gradle toolchain", () => {
  const batches = planClientRegressionBatches(CLIENT_MODULE_CATALOG, {
    catalog: CLIENT_MODULE_CATALOG,
  });
  assert.equal(batches.every((batch) => batch.toolchain !== "gradle"), true);
  const capacities = defaultRegressionCapacities(12);
  assert.equal(capacities.resources["flutter-cache"], 1);
});

test("Continuous Assistant SDK wrappers stay out of node-test batches", () => {
  const catalog = CLIENT_MODULE_CATALOG;
  const sdkIds = [
    "regression.client-bridge-generation",
    "regression.continuous-assistant-contract",
    "regression.continuous-assistant-ux",
  ];
  for (const id of sdkIds) {
    const module = catalog.find((item) => item.id === id);
    assert.ok(module, `${id} must be registered`);
    assert.notEqual(module.regression.toolchain, "node-test", id);
  }
  assert.equal(
    catalog.find((item) => item.id === "regression.continuous-assistant-ux").regression.toolchain,
    "flutter",
  );

  const batches = planClientRegressionBatches(catalog, { catalog });
  const nodeBatches = batches.filter((batch) => batch.toolchain === "node-test");
  for (const id of sdkIds) {
    assert.equal(
      nodeBatches.some((batch) => batch.members.includes(id)),
      false,
      `${id} leaked into a node-test batch`,
    );
  }
  const flutterJourneyLeaves = catalog.filter((module) =>
    module.command.args.some((arg) => String(arg).includes("continuous_assistant_journeys")));
  assert.equal(flutterJourneyLeaves.length, 0, "UX wrapper already owns the Flutter journey directory");
  assert.ok(catalog.find((item) => item.id === "flutter.feature.continuous-assistant.pane"));
  assert.ok(catalog.find((item) => item.id === "flutter.controller.continuous-assistant"));
  assert.ok(catalog.find((item) => item.id === "flutter.feature.continuous-assistant.toast"));
});

test("Node-only contract selection is derived from the same toolchain authority", () => {
  const all = listContractClientTests(".");
  const nodeOnly = nodeOnlyContractTestFiles(".");
  const sdkOwned = sdkOwnedContractTestFiles(".");
  assert.ok(all.length > 0);
  assert.equal(nodeOnly.length + sdkOwned.length, all.length);
  assert.ok(sdkOwned.includes("tests/contract/client/continuous-assistant-ux.test.mjs"));
  assert.ok(!nodeOnly.includes("tests/contract/client/continuous-assistant-ux.test.mjs"));
  assert.equal(nodeTestFileToolchain("tests/contract/client/contracts-client.test.mjs"), "node-test");
  assert.deepEqual(
    [...all].sort(),
    [...nodeOnly, ...sdkOwned].sort(),
  );
});
