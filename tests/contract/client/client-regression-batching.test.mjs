import assert from "node:assert/strict";
import os from "node:os";
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
import { selectModulesById } from "../../../tools/regression/client-module-selection.mjs";

test("complete selection batches native targets and Node test files before scheduling", () => {
  const batches = planClientRegressionBatches(CLIENT_MODULE_CATALOG, {
    catalog: CLIENT_MODULE_CATALOG,
    availableParallelism: 12,
  });
  assert.ok(batches.length < CLIENT_MODULE_CATALOG.length / 4);

  const rustTarget = batches.find((batch) =>
    batch.toolchain === "rust" && batch.attribution === "target" && batch.members.length > 100);
  assert.ok(rustTarget);
  assert.equal(rustTarget.command.args.includes("--lib"), true);
  assert.equal(rustTarget.command.args.at(-1), "--lib");

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
  }
});

test("focused Rust selection keeps its exact filter while a complete target delegates to libtest", () => {
  const selected = selectModulesById(["rust.domain.agent-usage"]);
  const [batch] = planClientRegressionBatches(selected, {
    catalog: CLIENT_MODULE_CATALOG,
    availableParallelism: os.availableParallelism(),
  });
  assert.equal(batch.attribution, "exact");
  assert.equal(batch.command.args.at(-1), selected[0].command.args.at(-1));
  assert.equal(batch.internalConcurrency, selected[0].regression.weight);
});

test("retry planning narrows every failed aggregate member to an exact command", () => {
  const selected = CLIENT_MODULE_CATALOG.filter((module) =>
    module.id.startsWith("rust.domain.agent-usage")).slice(0, 4);
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

test("Gradle unit filters sharing one task are emitted in one invocation", () => {
  const batches = planClientRegressionBatches(CLIENT_MODULE_CATALOG, {
    catalog: CLIENT_MODULE_CATALOG,
  });
  const gradle = batches.filter((batch) => batch.toolchain === "gradle");
  assert.ok(gradle.some((batch) => batch.attribution === "filters" && batch.members.length > 1));
});

test("hybrid Android native work cannot overlap shared Cargo, Flutter, or Gradle state", () => {
  const batches = planClientRegressionBatches(CLIENT_MODULE_CATALOG, {
    catalog: CLIENT_MODULE_CATALOG,
  });
  const androidNative = batches.find((batch) => batch.members.includes("bridge.android"));
  assert.deepEqual(androidNative.resources, ["cargo-target", "flutter-cache", "gradle-cache"]);
  const capacities = defaultRegressionCapacities(12);
  assert.equal(capacities.resources["cargo-target"], 1);
  assert.equal(capacities.resources["flutter-cache"], 1);
  assert.equal(capacities.resources["gradle-cache"], 1);
});

test("Continuous Assistant SDK wrappers stay out of node-test batches and own one target each", () => {
  const catalog = CLIENT_MODULE_CATALOG;
  const sdkIds = [
    "regression.client-bridge-generation",
    "regression.continuous-assistant-contract",
    "regression.continuous-assistant-integration",
    "regression.continuous-assistant-scenarios",
    "regression.continuous-assistant-evaluation",
    "regression.continuous-assistant-adoption",
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
  assert.equal(
    catalog.find((item) => item.id === "regression.continuous-assistant-adoption").regression.toolchain,
    "rust",
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
  const rustWholeTargets = catalog.filter((module) =>
    module.command.program === "cargo" &&
    module.command.args.includes("--test") &&
    ["continuity_host", "continuity_scenarios", "continuity_evaluation", "continuity_adoption"]
      .some((target) => module.command.args.includes(target)));
  assert.equal(rustWholeTargets.length, 0, "wrappers already own whole CA Rust targets");
  const flutterJourneyLeaves = catalog.filter((module) =>
    module.command.args.some((arg) => String(arg).includes("continuous_assistant_journeys")));
  assert.equal(flutterJourneyLeaves.length, 0, "UX wrapper already owns the Flutter journey directory");

  const assistantContinuity = catalog.find((item) => item.id === "rust.domain.assistant-continuity");
  assert.ok(assistantContinuity);
  assert.ok(assistantContinuity.inputs.includes("crates/licoup-native/src/domain/assistant_continuity/**"));
  assert.ok(assistantContinuity.command.args.includes("continuity_native"));
  assert.ok(
    catalog.find((item) => item.id === "rust.domain.assistant-continuity-context")
      .command.args.includes("continuity_context"),
  );
  assert.ok(
    catalog.find((item) => item.id === "rust.domain.assistant-continuity-qualification")
      .command.args.includes("continuity_qualification"),
  );
  assert.ok(
    catalog.find((item) => item.id === "rust.domain.conversation-continuity-store")
      .inputs.includes("crates/licoup-conversation/src/continuity/**"),
  );
  assert.ok(
    !catalog.find((item) => item.id === "regression.continuous-assistant-contract")
      .inputs.includes("crates/licoup-conversation/src/continuity/**"),
  );
  assert.ok(
    !catalog.find((item) => item.id === "regression.continuous-assistant-integration")
      .inputs.includes("crates/licoup-native/src/domain/assistant_continuity/**"),
  );
  assert.ok(catalog.find((item) => item.id === "flutter.feature.continuous-assistant.pane"));
  assert.ok(catalog.find((item) => item.id === "flutter.controller.continuous-assistant"));
  assert.ok(catalog.find((item) => item.id === "flutter.feature.continuous-assistant.toast"));
  const sourceOwners = catalog.filter((module) =>
    module.inputs.includes("crates/licoup-native/src/domain/assistant_continuity/**"));
  assert.equal(sourceOwners.length, 1);
  assert.equal(sourceOwners[0].id, "rust.domain.assistant-continuity");
});

test("Node-only contract selection is derived from the same toolchain authority", () => {
  const all = listContractClientTests(".");
  const nodeOnly = nodeOnlyContractTestFiles(".");
  const sdkOwned = sdkOwnedContractTestFiles(".");
  assert.ok(all.length > 0);
  assert.equal(nodeOnly.length + sdkOwned.length, all.length);
  assert.ok(sdkOwned.includes("tests/contract/client/continuous-assistant-adoption.test.mjs"));
  assert.ok(sdkOwned.includes("tests/contract/client/client-bridge-generation.test.mjs"));
  assert.ok(!nodeOnly.includes("tests/contract/client/continuous-assistant-ux.test.mjs"));
  assert.equal(nodeTestFileToolchain("tests/contract/client/contracts-client.test.mjs"), "node-test");
  assert.deepEqual(
    [...all].sort(),
    [...nodeOnly, ...sdkOwned].sort(),
  );
});
