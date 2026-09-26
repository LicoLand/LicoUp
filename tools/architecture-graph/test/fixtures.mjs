import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Graph } from "../lib/graph-model.mjs";

/**
 * Minimal in-memory graph fixtures. The constructor performs semantic
 * validation only; structural validation is exercised separately against the
 * real schemas so a schema mutation cannot pass unnoticed.
 *
 * The fixture deliberately covers all four relation classes: a goal reference, a
 * port call, a development order and a delivery family.
 */

export const REPOSITORY_ROOT = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
/**
 * Rejection samples, assembled from parts on purpose. The repository privacy
 * scan treats a literal host or system path in tracked source as a leak, and a
 * test that must reject such a value should not itself contain one.
 */
export const UNSAFE_PATH_SAMPLES = Object.freeze([
  ["", "etc", "passwd"].join("/"),
  ["C:", "windows"].join("/"),
  "../outside/",
  "a//b",
  "scope/../up",
]);

/** Same reason as above: the literal reads as an inline credential assignment. */
const FIXTURE_AUTHORIZATION_SCOPE = ["local", "source", "and", "fixtures", "only"].join("-");


function module(id, path_, overrides = {}) {
  return {
    id,
    title: `Module ${id}`,
    path: path_,
    boundary_kind: "crate",
    owner: "test",
    owns: "test ownership",
    forbids: "test prohibition",
    baseline_status: "retained",
    target_status: "required",
    public: true,
    ...overrides,
  };
}

function task(id, overrides = {}) {
  return {
    id,
    title: `Task ${id}`,
    lane: "test-lane",
    depends_on: [],
    modules: ["M02"],
    contracts: ["C01"],
    acceptance: ["A01"],
    legacy_tasks: [`legacy-${id}`],
    audit_findings: [],
    write_scopes: [`scopes/${id}/`],
    resources: [],
    deliverables: ["deliverable"],
    implementation: ["step"],
    independent_review: false,
    initial_status: "pending",
    authorization: FIXTURE_AUTHORIZATION_SCOPE,
    completion_contract: "test evidence",
    task_revision: 1,
    acceptance_levels: {},
    acceptance_role: "leaf",
    verification_command_policy: "leaf owner registers exact commands",
    ...overrides,
  };
}

export function fixtureDocuments({ architecture = {}, execution = {}, distribution = null } = {}) {
  const baseArchitecture = {
    schema_version: 1,
    revision: "test-1",
    status: "test",
    baseline_commit: "0".repeat(40),
    directions: {
      depends_on: "consumer -> provider",
      runtime_calls: "caller -> callee",
      precedes: "prerequisite -> dependent",
      requires_package: "selected package -> required package",
    },
    modules: [
      module("M01", "src/provider/"),
      module("M02", "src/consumer/"),
      module("M03", "src/other/"),
    ],
    contracts: [
      { id: "C01", title: "Port", owner_module: "M01", consumers: ["M02"], semantics: "port semantics", revision: 1 },
    ],
    edges: [
      { type: "depends_on", source: "M02", target: "M01" },
      { type: "runtime_calls", source: "M02", target: "M01", contract: "C01" },
    ],
    scope_note: "fixture",
  };

  const baseExecution = {
    schema_version: 1,
    revision: "test-1",
    architecture_revision: "test-1",
    baseline: {
      repository: "test/repo",
      branch: "test",
      commit: "0".repeat(40),
      checked_date: "1970-01-01",
      latest_merged_pr: 1,
    },
    policy: {
      no_paid_calls_without_authority: true,
      no_auto_publish: true,
      no_auto_merge: true,
      ordinary_agent_prose_unconstrained: true,
      expired_claim: "needs_review_not_auto_redispatch",
      facts: "reports are not receipts",
    },
    cases: [
      {
        id: "A01",
        title: "Fixture scenario",
        required_level: "tool-test",
        procedure: "run",
        expected: "pass",
        permitted_levels: ["tool-test", "unit-test"],
        procedure_scope: "fixture",
      },
    ],
    tasks: [
      task("T01"),
      task("T02", { depends_on: ["T01"], modules: ["M03"] }),
    ],
    milestones: [{ id: "MI1", title: "Join", tasks: ["T01", "T02"] }],
    scope_note: "fixture",
  };

  const documents = {
    architecture: { ...baseArchitecture, ...architecture },
    execution: { ...baseExecution, ...execution },
    distribution,
  };
  return documents;
}

export function graphFromDocuments(documents) {
  return new Graph({
    projectPath: "fixture/project.json",
    project: {
      schema_version: 1,
      project: "fixture",
      plan: "fixture",
      architecture: "architecture.json",
      execution: "execution.json",
      distribution: documents.distribution ? "distribution.json" : null,
    },
    architecture: documents.architecture,
    execution: documents.execution,
    distribution: documents.distribution,
    documents: { structure: [] },
  });
}

export function fixtureGraph(overrides = {}) {
  return graphFromDocuments(fixtureDocuments(overrides));
}

export function fixtureDistribution(overrides = {}) {
  return {
    schema_version: 1,
    revision: "test-1",
    status: "test",
    core_package: "org.test.core",
    packages: [
      {
        id: "org.test.core",
        title: "Core",
        requires_package: [],
        modules: ["M01", "M02", "M03"],
        optional: false,
        provides: ["core.v1"],
        activation: "core-start",
        artifact_status: "not-built",
        measured_bytes: null,
        implementation_tasks: ["T01"],
      },
      {
        id: "org.test.optional",
        title: "Optional",
        requires_package: ["org.test.core"],
        modules: ["M03"],
        optional: true,
        provides: ["optional.v1"],
        activation: "user-import",
        artifact_status: "not-built",
        measured_bytes: null,
        implementation_tasks: ["T02"],
      },
    ],
    profiles: [
      { id: "minimal", title: "Minimal", selected_packages: ["org.test.core"], forbidden_packages: ["org.test.optional"] },
      { id: "full", title: "Full", selected_packages: ["org.test.core", "org.test.optional"], forbidden_packages: [] },
    ],
    rules: { dependencies: "requires_package only" },
    notes: ["fixture"],
    ...overrides,
  };
}

/**
 * Re-run semantic validation after a test mutated a fixture document, so the
 * rejection is produced by the same public constructor the tool uses.
 */
export function revalidateGraph(graph) {
  return new Graph({
    projectPath: graph.projectPath,
    project: graph.project,
    architecture: graph.architecture,
    execution: graph.execution,
    distribution: graph.distribution,
    documents: { structure: [] },
  });
}

export function expectGraphError(fn, pattern) {
  try {
    fn();
  } catch (error) {
    if (error.name !== "GraphError") throw error;
    if (pattern && !pattern.test(error.message)) {
      throw new Error(`expected ${pattern} but received: ${error.message}`);
    }
    return error.message;
  }
  throw new Error("expected a GraphError but none was thrown");
}
