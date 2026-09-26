import assert from "node:assert/strict";
import test from "node:test";

import { loadGraph } from "../../../tools/architecture-graph/lib/graph-model.mjs";
import { removalPreview } from "../../../tools/distribution/resolve/lib/profile-resolver.mjs";
import {
  expectGraphError,
  fixtureDistribution,
  fixtureGraph,
  fixtureTask,
  REPOSITORY_ROOT,
} from "./fixtures.mjs";

const REMOVAL_KEYS = [
  "proposal_only",
  "profile",
  "package",
  "blocking_dependents",
  "active_pin_retainers",
  "can_remove_bytes_in_this_model",
  "note",
];

test("removing an unreferenced optional package is modelled as reclaimable", () => {
  const graph = fixtureGraph();
  const preview = removalPreview(graph, { profileId: "full", packageId: "org.test.optional" });
  assert.deepEqual(preview.blocking_dependents, []);
  assert.deepEqual(preview.active_pin_retainers, []);
  assert.equal(preview.can_remove_bytes_in_this_model, true);
  assert.equal(preview.proposal_only, true);
});

test("an active pin retains the package and its dependents block the removal", () => {
  const graph = fixtureGraph();
  const pinned = removalPreview(graph, {
    profileId: "full",
    packageId: "org.test.optional",
    pinned: ["org.test.optional"],
  });
  assert.deepEqual(pinned.active_pin_retainers, ["org.test.optional"]);
  assert.equal(pinned.can_remove_bytes_in_this_model, false);

  const distribution = fixtureDistribution({
    packages: [
      { id: "org.test.core", title: "Core", requires_package: [], modules: ["M01"], optional: false, provides: ["core.one.v1"], activation: "core-start", artifact_status: "not-built", measured_bytes: null, implementation_tasks: ["T01"] },
      { id: "org.test.a", title: "A", requires_package: ["org.test.core"], modules: ["M02"], optional: true, provides: ["a.one.v1"], activation: "on-demand", artifact_status: "not-built", measured_bytes: null, implementation_tasks: ["T02"] },
      { id: "org.test.b", title: "B", requires_package: ["org.test.a"], modules: ["M03"], optional: true, provides: ["b.one.v1"], activation: "on-demand", artifact_status: "not-built", measured_bytes: null, implementation_tasks: [] },
    ],
    profiles: [{ id: "chain", title: "Chain", selected_packages: ["org.test.core", "org.test.a", "org.test.b"], forbidden_packages: [] }],
  });
  const chained = fixtureGraph({
    distribution,
    execution: { tasks: [fixtureTask("T01"), fixtureTask("T02", { depends_on: ["T01"], modules: ["M02"], packages: ["org.test.a"] })] },
  });
  const blocked = removalPreview(chained, { profileId: "chain", packageId: "org.test.a" });
  assert.deepEqual(blocked.blocking_dependents, ["org.test.b"]);
  assert.equal(blocked.can_remove_bytes_in_this_model, false);
});

test("the core, packages outside the profile and unknown pins are refused", () => {
  const graph = fixtureGraph();
  assert.match(expectGraphError(() => removalPreview(graph, { profileId: "full", packageId: "org.test.core" }), /core is not an uninstallable feature/u), /core/u);
  assert.match(expectGraphError(() => removalPreview(graph, { profileId: "minimal", packageId: "org.test.optional" }), /package not in selected profile/u), /optional/u);
  assert.match(expectGraphError(() => removalPreview(graph, { profileId: "full", packageId: "org.test.optional", pinned: ["org.test.absent"] }), /pin not in selected profile/u), /absent/u);
  assert.match(expectGraphError(() => removalPreview(graph, { profileId: "absent", packageId: "org.test.optional" }), /unknown profile/u), /absent/u);
});

test("a removal preview changes neither the graph nor task fingerprints", () => {
  const graph = fixtureGraph();
  const before = {
    digest: graph.graphDigest,
    distribution: JSON.stringify(graph.distribution),
    fingerprints: Object.fromEntries([...graph.tasks.keys()].map((id) => [id, graph.taskFingerprint(id)])),
  };
  removalPreview(graph, { profileId: "full", packageId: "org.test.optional", pinned: ["org.test.optional"] });
  expectGraphError(() => removalPreview(graph, { profileId: "minimal", packageId: "org.test.core" }), /core is not an uninstallable feature/u);
  assert.equal(graph.graphDigest, before.digest);
  assert.equal(JSON.stringify(graph.distribution), before.distribution);
  for (const [id, fingerprint] of Object.entries(before.fingerprints)) {
    assert.equal(graph.taskFingerprint(id), fingerprint, `task ${id} fingerprint moved`);
  }
});

