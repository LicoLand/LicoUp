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
import { partitionModulesByRunnableHost, selectModulesById } from "../../../tools/regression/client-module-selection.mjs";
import { executeClientModules } from "../../../tools/regression/client-module-execution.mjs";
import { flutterTestInputPaths } from "../../../tools/regression/client-regression-toolchain-stats/flutter.mjs";

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
    if (flutter.attribution !== "files") continue;
    assert.ok(Array.isArray(flutter.inputOwners));
    const ownedIndexes = new Set(flutter.inputOwners.flatMap((owner) => owner.indexes));
    const inputs = flutterTestInputPaths(flutter.command);
    assert.deepEqual([...ownedIndexes].sort((left, right) => left - right),
      inputs.map((_, index) => index));
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

test("complete Linux selection retains one batch per native library after platform partition", () => {
  const { runnable, unsupported } = partitionModulesByRunnableHost(CLIENT_MODULE_CATALOG, "linux");
  const batches = planClientRegressionBatches(runnable, {
    catalog: runnable,
    excludedCatalog: unsupported,
  });
  assert.deepEqual(new Set(batches.flatMap((batch) => batch.members)), new Set(runnable.map((module) => module.id)));
  for (const crate of ["licoup-native", "licoup-foundation"]) {
    const manifest = `crates/${crate}/Cargo.toml`;
    const members = runnable.filter((module) => module.regression.stage === "backend" && module.command.program === "cargo" &&
      module.command.args.includes(manifest) && module.command.args.includes("--lib") &&
      !module.command.args.includes("--") && module.command.args.at(-2) === "--lib");
    const covering = batches.filter((batch) => members.some((module) => batch.members.includes(module.id)));
    assert.equal(covering.length, 1, `${crate} must not degrade to one Cargo invocation per member`);
    assert.equal(covering[0].attribution, "target");
    const excluded = unsupported.filter((module) => module.regression.stage === "backend" && module.command.program === "cargo" &&
      module.command.args.includes(manifest) && module.command.args.at(-2) === "--lib");
    for (const module of excluded) {
      const filter = module.command.args.at(-1);
      const index = covering[0].command.args.indexOf(filter);
      assert.ok(index > 0);
      assert.equal(covering[0].command.args[index - 1], "--skip");
      assert.equal(covering[0].members.includes(module.id), false);
    }
  }
});

function platformBatchFixture(filter, id, hosts = ["linux"]) {
  const source = selectModulesById(["rust.domain.agent-usage"])[0];
  return { ...source, id, command: { ...source.command, args: [...source.command.args.slice(0, -1), filter] },
    regression: { ...source.regression, runnableHosts: hosts } };
}

test("executor uses one host partition for batching and excludes foreign owner filters", async () => {
  const shared = [platformBatchFixture("domain::one::", "synthetic.one"),
    platformBatchFixture("domain::two::", "synthetic.two")];
  const foreign = platformBatchFixture("platform::windows::", "synthetic.windows", ["win32"]);
  const calls = [];
  const result = await executeClientModules(shared, {
    repoRoot: ".", catalog: [...shared, foreign], host: "linux", output: { write() {} },
    async commandRunner(batch) {
      calls.push(batch);
      return { ...batch, status: "passed", reason: null, durationMs: 0 };
    },
  });
  assert.equal(result.exitCode, 0);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].members, shared.map((module) => module.id));
  assert.deepEqual(calls[0].command.args.slice(-3), ["--", "--skip", "platform::windows::"]);
  const incomplete = planClientRegressionBatches(shared.slice(0, 1), {
    catalog: shared, excludedCatalog: [foreign],
  });
  assert.equal(incomplete[0].attribution, "exact");
});

test("overlapping foreign filters retain narrow commands and shared exact cases retain their host owner", () => {
  const shared = [platformBatchFixture("domain::one::", "synthetic.one"),
    platformBatchFixture("domain::two::", "synthetic.two")];
  const overlap = platformBatchFixture("domain::", "synthetic.windows", ["win32"]);
  const narrow = planClientRegressionBatches(shared, { catalog: shared, excludedCatalog: [overlap] });
  assert.deepEqual(narrow.map((batch) => batch.command), shared.map((module) => module.command));
  const sameCase = platformBatchFixture("domain::one::", "synthetic.other-host", ["darwin"]);
  const [broad] = planClientRegressionBatches(shared, { catalog: shared, excludedCatalog: [sameCase] });
  assert.equal(broad.attribution, "target");
  assert.equal(broad.command.args.includes("--skip"), false);
  assert.deepEqual(broad.members, shared.map((module) => module.id));
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
