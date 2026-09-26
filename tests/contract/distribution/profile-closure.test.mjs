import assert from "node:assert/strict";
import test from "node:test";

import { loadGraph } from "../../../tools/architecture-graph/lib/graph-model.mjs";
import { profilePreview } from "../../../tools/distribution/resolve/lib/profile-resolver.mjs";
import {
  expectGraphError,
  fixtureDistribution,
  fixtureGraph,
  fixtureTask,
  REPOSITORY_ROOT,
} from "./fixtures.mjs";

const PROFILE_KEYS = ["proposal_only", "profile", "selected_packages", "dependency_closure", "not_selected", "measured_bytes", "note"];

test("a profile closes over its selected packages and their requires only", () => {
  const graph = fixtureGraph();
  const minimal = profilePreview(graph, "minimal");
  assert.deepEqual(minimal.dependency_closure, ["org.test.core"]);
  assert.deepEqual(minimal.not_selected, ["org.test.optional"]);
  assert.equal(minimal.measured_bytes, null, "no size is invented in the plan");

  const full = profilePreview(graph, "full");
  assert.deepEqual(full.dependency_closure, ["org.test.core", "org.test.optional"]);
  assert.deepEqual(full.not_selected, []);
});

test("a closure follows requires transitively", () => {
  const distribution = fixtureDistribution({
    packages: [
      { id: "org.test.core", title: "Core", requires_package: [], modules: ["M01"], optional: false, provides: ["core.one.v1"], activation: "core-start", artifact_status: "not-built", measured_bytes: null, implementation_tasks: ["T01"] },
      { id: "org.test.mid", title: "Mid", requires_package: ["org.test.core"], modules: ["M02"], optional: true, provides: ["mid.one.v1"], activation: "on-demand", artifact_status: "not-built", measured_bytes: null, implementation_tasks: [] },
      { id: "org.test.top", title: "Top", requires_package: ["org.test.mid"], modules: ["M03"], optional: true, provides: ["top.one.v1"], activation: "on-demand", artifact_status: "not-built", measured_bytes: null, implementation_tasks: ["T02"] },
    ],
    profiles: [{ id: "deep", title: "Deep", selected_packages: ["org.test.top"], forbidden_packages: [] }],
  });
  const graph = fixtureGraph({
    distribution,
    execution: { tasks: [fixtureTask("T01"), fixtureTask("T02", { depends_on: ["T01"], modules: ["M02"], packages: ["org.test.top"] })] },
  });
  assert.deepEqual(profilePreview(graph, "deep").dependency_closure, ["org.test.core", "org.test.mid", "org.test.top"]);
});

test("a package pulled into a closure through a forbidden package is refused", () => {
  const distribution = fixtureDistribution({
    packages: [
      { id: "org.test.core", title: "Core", requires_package: [], modules: ["M01"], optional: false, provides: ["core.one.v1"], activation: "core-start", artifact_status: "not-built", measured_bytes: null, implementation_tasks: ["T01"] },
      { id: "org.test.a", title: "A", requires_package: ["org.test.core", "org.test.b"], modules: ["M02"], optional: true, provides: ["a.one.v1"], activation: "on-demand", artifact_status: "not-built", measured_bytes: null, implementation_tasks: ["T02"] },
      { id: "org.test.b", title: "B", requires_package: ["org.test.core"], modules: [], optional: true, provides: ["b.one.v1"], activation: "on-demand", artifact_status: "not-built", measured_bytes: null, implementation_tasks: [] },
    ],
    profiles: [{ id: "minimal", title: "Minimal", selected_packages: ["org.test.core", "org.test.a"], forbidden_packages: ["org.test.b"] }],
  });
  const message = expectGraphError(
    () => fixtureGraph({
      distribution,
      execution: { tasks: [fixtureTask("T01"), fixtureTask("T02", { depends_on: ["T01"], modules: ["M02"], packages: ["org.test.a"] })] },
    }),
    /forbidden package/u,
  );
  assert.match(message, /org\.test\.b/u);
});

test("a static module dependency from the core into an optional package is refused", () => {
  // M01 ships in the core, M02 only in the optional package. A direct or
  // indirect static edge between them would link optional code into the
  // minimal host, which the install closure must refuse.
  const message = expectGraphError(
    () => fixtureGraph({ architecture: { edges: [{ type: "depends_on", source: "M01", target: "M02" }] } }),
    /escapes the install closure/u,
  );
  assert.match(message, /org\.test\.core/u);
});

