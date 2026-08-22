import assert from "node:assert/strict";
import os from "node:os";
import test from "node:test";
import { CLIENT_MODULE_CATALOG } from "../../../tools/regression/client-module-catalog.mjs";
import { planClientRegressionBatches } from "../../../tools/regression/client-regression-batching.mjs";
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
