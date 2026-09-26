import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

import { loadGraph } from "../../../tools/architecture-graph/lib/graph-model.mjs";
import { catalogueFromGraph, resolveInstallClosure } from "../../../tools/distribution/resolve/lib/catalogue-resolver.mjs";
import { decisionsAgree, decisionShape, runProbe } from "./probe.mjs";
import { REPOSITORY_ROOT, tempDir } from "./fixtures.mjs";

/**
 * The differential between the plan resolver and the product resolver.
 *
 * `crates/licoup-extension-contracts` owns `install_closure`; the plan side
 * reimplements its declared semantics for previews. This file feeds one shared
 * vector corpus to both real implementations — the Rust probe in `rust-probe/`
 * executes the product function, the plan resolver runs in this process — and
 * compares their decisions field by field. A change on either side that alters
 * a decision fails here; a source-text change that does not alter a decision
 * does not concern this oracle.
 */

const VECTORS_PATH = "tests/contract/distribution/vectors/catalogue-cases.json";
const VECTORS = JSON.parse(fs.readFileSync(path.join(REPOSITORY_ROOT, VECTORS_PATH), "utf8"));

function sameDecision(left, right) {
  return JSON.stringify(decisionShape(left)) === JSON.stringify(decisionShape(right));
}

test("the shared vectors are complete", () => {
  assert.ok(VECTORS.cases.length >= 8, "the corpus must cover the closure rules");
  const ids = VECTORS.cases.map((entry) => entry.id);
  assert.equal(new Set(ids).size, ids.length, "vector ids must be unique");
  for (const entry of VECTORS.cases) {
    assert.ok(entry.rule && entry.product_test, `case ${entry.id} needs its rule and product provenance`);
    assert.ok(entry.catalogue.core_package && entry.catalogue.packages.length > 0, `case ${entry.id} needs a catalogue`);
    assert.ok(entry.roots.length > 0, `case ${entry.id} needs a root`);
    assert.ok(entry.expected && typeof entry.expected.ok === "boolean", `case ${entry.id} needs its recorded decision`);
  }
});

test("the plan resolver reproduces every recorded decision", () => {
  for (const entry of VECTORS.cases) {
    const result = resolveInstallClosure(entry.catalogue, entry.roots);
    assert.ok(sameDecision(result, entry.expected),
      `${entry.id}: plan ${JSON.stringify(decisionShape(result))} recorded ${JSON.stringify(decisionShape(entry.expected))}`);
  }
});

test("the product resolver and the plan resolver agree on every shared decision", (t) => {
  const productRows = runProbe(t, ["vectors", VECTORS_PATH]);
  if (productRows === null) return;
  assert.equal(productRows.length, VECTORS.cases.length, "the probe must decide every vector");
  const productById = new Map(productRows.map((row) => [row.id, row]));
  for (const entry of VECTORS.cases) {
    const product = productById.get(entry.id);
    assert.ok(product !== undefined, `the probe returned no decision for ${entry.id}`);
    assert.ok(sameDecision(product, entry.expected),
      `${entry.id}: product ${JSON.stringify(decisionShape(product))} recorded ${JSON.stringify(decisionShape(entry.expected))}`);
    const plan = resolveInstallClosure(entry.catalogue, entry.roots);
    const comparison = decisionsAgree(plan, product);
    assert.ok(comparison.agree, `${entry.id}: plan ${comparison.plan} product ${comparison.product}`);
  }
});

test("the differential comparison fails when either side is wrong", () => {
  const passing = VECTORS.cases.find((entry) => entry.expected.ok);
  const passingDecision = resolveInstallClosure(passing.catalogue, passing.roots);
  assert.equal(decisionsAgree(passingDecision, passingDecision).agree, true);

  const missingSelection = { ...passingDecision, selected: passingDecision.selected.slice(1) };
  assert.equal(decisionsAgree(missingSelection, passingDecision).agree, false,
    "a plan that drops a selected package must not agree");
  const extraDeclined = { ...passingDecision, declined_optional: [...passingDecision.declined_optional, "example.extra"] };
  assert.equal(decisionsAgree(passingDecision, extraDeclined).agree, false,
    "a product that declines another package must not agree");

  const failing = VECTORS.cases.find((entry) => !entry.expected.ok);
  const failingDecision = resolveInstallClosure(failing.catalogue, failing.roots);
  const wrongCode = { ...failingDecision, code: "some_other_refusal" };
  assert.equal(decisionsAgree(failingDecision, wrongCode).agree, false,
    "a different refusal code must not agree");
  const wrongPackage = { ...failingDecision, package: "example.other" };
  assert.equal(decisionsAgree(wrongPackage, failingDecision).agree, false,
    "a different refused package must not agree");
  const inventedDependent = { ...failingDecision, required_by: "example.invented" };
  assert.equal(decisionsAgree(inventedDependent, failingDecision).agree, false,
    "an invented dependent must not agree");
  const wrongField = { ...failingDecision, field: "someOtherField" };
  assert.equal(decisionsAgree(wrongField, failingDecision).agree, false,
    "a different offending field must not agree");
});

