import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { REQUIRED_RECEIPT_FIELDS } from "../lib/work-items.mjs";
import { checkStructure, schemaPathBeside } from "../lib/schema-check.mjs";
import { DEVELOPMENT_DAG_CLASS, loadGraph, RELATION_CLASSES, topologicalLayers } from "../lib/graph-model.mjs";
import { expectGraphError, fixtureGraph, revalidateGraph, REPOSITORY_ROOT, UNSAFE_PATH_SAMPLES } from "./fixtures.mjs";


function temporaryDirectory(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

test("structural checking delegates to the existing JSON Schema library and is not a no-op", () => {
  const directory = temporaryDirectory("architecture-graph-schema-");
  try {
    const schemaPath = path.join(directory, "sample.schema.json");
    const documentPath = path.join(directory, "sample.json");
    fs.writeFileSync(schemaPath, JSON.stringify({
      $schema: "https://json-schema.org/draft/2020-12/schema",
      type: "object",
      required: ["name", "count"],
      additionalProperties: false,
      properties: { name: { type: "string" }, count: { type: "integer", minimum: 0 } },
    }));
    assert.equal(checkStructure({ document: { name: "ok", count: 1 }, documentPath, schemaPath }).valid, true);
    assert.equal(checkStructure({ document: { name: "ok" }, documentPath, schemaPath }).valid, false,
      "a missing required field must be rejected by the schema library");
    assert.equal(checkStructure({ document: { name: "ok", count: -1 }, documentPath, schemaPath }).valid, false);
    assert.equal(checkStructure({ document: { name: "ok", count: 1, extra: true }, documentPath, schemaPath }).valid, false);
    assert.equal(checkStructure({ document: { name: 7, count: 1 }, documentPath, schemaPath }).valid, false);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("a missing sibling schema is an error rather than a silent skip", () => {
  const schemaPath = path.join(REPOSITORY_ROOT, "tools/architecture-graph/test/absent.schema.json");
  assert.match(
    expectGraphError(() => checkStructure({ document: {}, documentPath: "absent.json", schemaPath })),
    /missing schema/,
  );
});

test("graph version, task fingerprint and input-evidence fields bind a claim", () => {
  const graph = fixtureGraph();
  const version = graph.graphVersion;
  assert.match(version.baseline_commit, /^[0-9a-f]{40}$/u);
  assert.equal(version.architecture_revision, graph.architecture.revision);
  assert.ok(REQUIRED_RECEIPT_FIELDS.includes("task_digest"));
  assert.ok(REQUIRED_RECEIPT_FIELDS.includes("input_digest"));
  assert.ok(REQUIRED_RECEIPT_FIELDS.includes("claim_token"));
});

test("IDs must be unique across node types", () => {
  const graph = fixtureGraph();
  graph.architecture.modules.push({ ...graph.architecture.modules[0], id: "C01", title: "collides with a contract id" });
  assert.match(expectGraphError(() => revalidateGraph(graph)), /unique across every graph node type/);
});

test("an unknown reference, an illegal edge type and a cycle are rejected", () => {
  const unknownReference = fixtureGraph();
  unknownReference.architecture.edges.push({ type: "depends_on", source: "M02", target: "M09" });
  assert.match(expectGraphError(() => revalidateGraph(unknownReference)), /unknown/);

  const illegalType = fixtureGraph();
  illegalType.architecture.edges.push({ type: "requires_package", source: "M01", target: "M02" });
  assert.match(expectGraphError(() => revalidateGraph(illegalType)), /depends_on or runtime_calls/);

  const cycle = fixtureGraph();
  cycle.architecture.edges.push({ type: "depends_on", source: "M01", target: "M02" });
  assert.match(expectGraphError(() => revalidateGraph(cycle)), /relation cycle among/);

  const runtimeContract = fixtureGraph();
  runtimeContract.architecture.edges.push({ type: "runtime_calls", source: "M01", target: "M02", contract: "C99" });
  assert.match(expectGraphError(() => revalidateGraph(runtimeContract)), /known contract/);
});

test("unsafe write scopes and unpermitted evidence levels are rejected", () => {
  for (const unsafeScope of UNSAFE_PATH_SAMPLES) {
    const graph = fixtureGraph();
    graph.execution.tasks[0].write_scopes = [unsafeScope];
    assert.match(expectGraphError(() => revalidateGraph(graph)), /write scope/);
  }

  const downgraded = fixtureGraph();
  downgraded.execution.tasks[0].acceptance_levels = { A01: "production-profile" };
  assert.match(expectGraphError(() => revalidateGraph(downgraded)), /unpermitted evidence level/);

  const finalDowngrade = fixtureGraph();
  finalDowngrade.execution.tasks[0].acceptance_role = "final";
  finalDowngrade.execution.tasks[0].acceptance_levels = { A01: "unit-test" };
  assert.match(expectGraphError(() => revalidateGraph(finalDowngrade)), /cannot downgrade/);
});

test("the development DAG is derived from task.depends_on only", () => {
  const graph = fixtureGraph();
  const relations = graph.relations();
  const scheduling = relations.filter((edge) => edge.enters_development_dag);
  assert.ok(scheduling.length > 0);
  assert.ok(scheduling.every((edge) => edge.class === DEVELOPMENT_DAG_CLASS));
  assert.ok(scheduling.every((edge) => edge.relation === "precedes"));
  assert.deepEqual(graph.developmentDag().edges, [["T01", "T02"]]);
  for (const name of Object.values(RELATION_CLASSES)) {
    if (name === DEVELOPMENT_DAG_CLASS) continue;
    assert.ok(relations.filter((edge) => edge.class === name).every((edge) => edge.enters_development_dag === false));
  }
});

test("construction rejects cyclic task dependencies before any projection is requested", () => {
  const cycle = fixtureGraph();
  cycle.tasks.get("T01").depends_on = ["T02"];
  assert.match(expectGraphError(() => revalidateGraph(cycle)), /relation cycle among/);

  const self = fixtureGraph();
  self.tasks.get("T01").depends_on = ["T01"];
  assert.match(expectGraphError(() => revalidateGraph(self)), /self relation/);
});

test("a layer computation reports an exact cycle instead of guessing an order", () => {
  assert.deepEqual(topologicalLayers(["a", "b"], [["a", "b"]]), [["a"], ["b"]]);
  assert.match(expectGraphError(() => topologicalLayers(["a", "b"], [["a", "b"], ["b", "a"]])), /cycle among: a, b/);
  assert.match(expectGraphError(() => topologicalLayers(["a"], [["a", "a"]])), /self relation/);
});

test("the module graph and the development graph are separate objects", () => {
  const graph = fixtureGraph();
  const moduleEdges = graph.architecture.edges.map((edge) => `${edge.source}->${edge.target}`);
  const taskEdges = graph.developmentDag().edges.map((edge) => `${edge[0]}->${edge[1]}`);
  assert.deepEqual(moduleEdges.sort(), ["M02->M01", "M02->M01"]);
  assert.deepEqual(taskEdges.sort(), ["T01->T02"]);
  assert.ok(moduleEdges.every((edge) => graph.modules.has(edge.split("->")[0])));
  assert.ok(taskEdges.every((edge) => graph.tasks.has(edge.split("->")[0])));
  const overlap = new Set(moduleEdges).intersection(new Set(taskEdges));
  assert.equal(overlap.size, 0, "module and task identifiers must not be mixed into one scheduling graph");
});

test("schema documents are read from beside the graph, not from a machine path", () => {
  const directory = temporaryDirectory("architecture-graph-beside-");
  try {
    const documentPath = path.join(directory, "execution.json");
    const schemaPath = path.join(directory, "execution.schema.json");
    fs.writeFileSync(documentPath, "{}\n");
    fs.writeFileSync(schemaPath, "{}\n");
    assert.equal(schemaPathBeside(documentPath), schemaPath);
    assert.equal(path.basename(schemaPathBeside(path.join("some", "plan", "execution.json"))), "execution.schema.json");
    assert.ok(fs.existsSync(schemaPath));
    assert.equal(fs.existsSync(path.join(directory, "absent.schema.json")), false);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
