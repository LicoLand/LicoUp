import assert from "node:assert/strict";
import test from "node:test";

import { loadGraph } from "../../../tools/architecture-graph/lib/graph-model.mjs";
import { buildFourthGraph, renderFourthGraph } from "../../../tools/architecture-graph/distribution/fourth-graph.mjs";
import { fixtureGraph, REPOSITORY_ROOT } from "./fixtures.mjs";

test("the fourth graph traces packages to modules, contracts, tasks and providers", () => {
  const graph = fixtureGraph();
  const fourth = buildFourthGraph(graph);

  const types = new Set(fourth.nodes.map((node) => node.type));
  for (const type of ["package", "profile", "capability", "module", "task", "contract"]) {
    assert.ok(types.has(type), `the fourth graph is missing ${type} nodes`);
  }
  const relations = new Set(fourth.edges.map((edge) => edge.relation));
  for (const relation of [
    "requires_package",
    "profile_selects_package",
    "profile_forbids_package",
    "package_ships_module",
    "package_implementation_task",
    "task_delivers_package",
    "package_provides_capability",
    "module_owns_contract",
    "module_consumes_contract",
  ]) {
    assert.ok(relations.has(relation), `the fourth graph is missing ${relation}`);
  }
  assert.ok(fourth.edges.every((edge) => edge.enters_development_dag === false));
  assert.ok(!fourth.edges.some((edge) => edge.relation === "precedes"), "no deployment edge may schedule work");

  const core = fourth.traceability.packages.find((entry) => entry.id === "org.test.core");
  assert.deepEqual(core.modules, ["M01", "M03"]);
  assert.deepEqual(core.contracts, ["C01"]);
  assert.deepEqual(core.delivery_tasks, ["T01"]);
  const optional = fourth.traceability.packages.find((entry) => entry.id === "org.test.optional");
  assert.deepEqual(optional.contracts, ["C01"], "a consumed contract is traced too");
  assert.deepEqual(optional.delivery_tasks, ["T02"]);

  const minimal = fourth.profiles.find((profile) => profile.id === "minimal");
  assert.deepEqual(minimal.closure, ["org.test.core"]);
  assert.equal(minimal.provider_coverage.length, 12, "every product capability is reported per profile");
  const declarativeUi = fourth.nodes.find((node) => node.id === "declarative-ui.v1");
  assert.equal(declarativeUi.host_published, true);
  assert.equal(declarativeUi.default_owner, "org.licoland.core");
});

test("building and rendering the fourth graph is deterministic", () => {
  const graph = fixtureGraph();
  const first = buildFourthGraph(graph);
  const second = buildFourthGraph(graph);
  assert.equal(JSON.stringify(second), JSON.stringify(first));
  assert.equal(second.fourth_graph_digest, first.fourth_graph_digest);

  const oneRender = renderFourthGraph(graph);
  const otherRender = renderFourthGraph(graph);
  assert.deepEqual(Object.keys(oneRender.files), Object.keys(otherRender.files));
  for (const [name, content] of Object.entries(oneRender.files)) {
    assert.equal(otherRender.files[name], content, `${name} is not reproducible`);
  }
  assert.match(oneRender.files["distribution.fourth.mmd"], /profile minimal/u);
  assert.match(oneRender.files["distribution.fourth.svg"], /org\.test\.core/u);
  assert.match(oneRender.files["distribution.traceability.md"], /\| org\.test\.optional \|/u);
  assert.equal(oneRender.summary.entered_development_dag_edges, 0);
});

test("building the fourth graph does not move the development DAG or task fingerprints", () => {
  const graph = fixtureGraph();
  const before = {
    dag: JSON.stringify(graph.developmentDag()),
    fingerprints: Object.fromEntries([...graph.tasks.keys()].map((id) => [id, graph.taskFingerprint(id)])),
  };
  renderFourthGraph(graph);
  assert.equal(JSON.stringify(graph.developmentDag()), before.dag);
  for (const [id, fingerprint] of Object.entries(before.fingerprints)) {
    assert.equal(graph.taskFingerprint(id), fingerprint, `task ${id} fingerprint moved`);
  }
});

