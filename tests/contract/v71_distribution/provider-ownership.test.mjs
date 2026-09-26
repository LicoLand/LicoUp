import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

import { loadGraph } from "../../../tools/architecture-graph/lib/graph-model.mjs";
import {
  HOST_PUBLISHED_CAPABILITIES,
  PRODUCT_CAPABILITY_OWNERSHIP,
  providerDependencyChecks,
} from "../../../tools/distribution/catalog/lib/product-capabilities.mjs";
import { runProbe } from "./probe.mjs";
import { fixtureDistribution, fixtureGraph, REPOSITORY_ROOT } from "./fixtures.mjs";

/**
 * The provider/capability ownership table exists in three places on purpose:
 * the Rust contract (product), the published architecture document, and this
 * plan-side copy that has no way to link the crate. The product table is
 * compared through the executing probe (`capability_owner`, `core_capabilities`,
 * `optional_capabilities`), the published document through its own text; the
 * rest of the file exercises the check that compares a graph against the table.
 */

const PROFILES_DOCUMENT = "docs/architecture/DEPLOYMENT-PROFILES.md";

function productTableFromDocument() {
  const text = fs.readFileSync(path.join(REPOSITORY_ROOT, PROFILES_DOCUMENT), "utf8");
  return [...text.matchAll(/^\| `([a-z0-9.-]+)` \| `([a-z0-9.-]+)` \| (Core|Optional) \|$/gmu)]
    .map((match) => ({ capability: match[1], owner: match[2], set: match[3] === "Core" ? "core" : "optional" }));
}

function asMap(rows) {
  return new Map(rows.map((row) => [row.capability, `${row.owner}|${row.set}`]));
}

test("the checked-in ownership table matches the executing product", (t) => {
  const rows = runProbe(t, ["capabilities"]);
  if (rows === null) return;
  assert.equal(rows.length, PRODUCT_CAPABILITY_OWNERSHIP.length, "the product table row count changed");
  const expected = asMap(PRODUCT_CAPABILITY_OWNERSHIP);
  const published = new Set(rows.map((row) => row.capability));
  for (const row of rows) {
    assert.equal(expected.get(row.capability), `${row.owner}|${row.set}`,
      `capability ${row.capability} differs from the executing product`);
  }
  for (const row of PRODUCT_CAPABILITY_OWNERSHIP) {
    assert.ok(published.has(row.capability), `the product does not know ${row.capability}`);
  }
});

test("the checked-in ownership table matches the published document", () => {
  const rows = productTableFromDocument();
  assert.equal(rows.length, PRODUCT_CAPABILITY_OWNERSHIP.length, "the published table row count changed");
  const expected = asMap(PRODUCT_CAPABILITY_OWNERSHIP);
  for (const row of rows) {
    assert.equal(expected.get(row.capability), `${row.owner}|${row.set}`,
      `capability ${row.capability} differs from the published document`);
  }
  assert.equal(HOST_PUBLISHED_CAPABILITIES.length, 1);
  assert.equal(HOST_PUBLISHED_CAPABILITIES[0].capability, "declarative-ui.v1");
});

test("a custom table can check a custom distribution", () => {
  const graph = fixtureGraph();
  const result = providerDependencyChecks(graph, {
    ownership: [
      { capability: "conversation.v1", owner: "org.test.core", set: "core" },
      { capability: "analytics.v1", owner: "org.test.optional", set: "optional" },
    ],
    hostPublished: [],
  });
  assert.deepEqual(result.issues, []);
  assert.equal(result.ok, true);
});

test("the check reports an absent owner, a non-providing owner and a host capability claim", () => {
  const distribution = fixtureDistribution({
    packages: fixtureDistribution().packages.map((pkg) =>
      pkg.id === "org.test.optional" ? { ...pkg, provides: ["declarative-ui.v1"] } : pkg),
  });
  const graph = fixtureGraph({ distribution });
  const result = providerDependencyChecks(graph);
  const codes = result.issues.map((issue) => `${issue.code}:${issue.package ?? issue.capability}`);
  assert.ok(codes.includes("host_capability_claimed_by_package:org.test.optional"));
  assert.ok(codes.includes("capability_owner_absent:org.licoland.adapter.generic"));
  assert.equal(result.ok, false);

  const nonProviding = fixtureGraph({
    distribution: fixtureDistribution({
      packages: fixtureDistribution().packages.map((pkg) =>
        pkg.id === "org.test.core" ? { ...pkg, provides: ["conversation.v1"] } : pkg),
    }),
  });
  const missingCore = providerDependencyChecks(nonProviding, {
    ownership: [{ capability: "conversation.v1", owner: "org.test.core", set: "core" }],
  });
  assert.deepEqual(missingCore.issues, [], "the core provides what the table names");

  const wrongCore = providerDependencyChecks(nonProviding, {
    ownership: [{ capability: "extension-host.v1", owner: "org.test.core", set: "core" }],
  });
  assert.equal(wrongCore.issues[0].code, "capability_owner_not_providing");
});

test("bad capability names and duplicates are refused", () => {
  const distribution = fixtureDistribution({
    packages: fixtureDistribution().packages.map((pkg) =>
      pkg.id === "org.test.core" ? { ...pkg, provides: ["conversation.v1", "Not.Namespaced", "Not.Namespaced"] } : pkg),
  });
  const result = providerDependencyChecks(fixtureGraph({ distribution }), { ownership: [] });
  const codes = [...new Set(result.issues.map((issue) => issue.code))].sort();
  assert.deepEqual(codes, ["capability_duplicate", "capability_id_invalid"]);
});

