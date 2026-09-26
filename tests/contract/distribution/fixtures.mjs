import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import { Graph } from "../../../tools/architecture-graph/lib/graph-model.mjs";

/** Synthetic fixtures run without personal plans or retained local evidence. */
export const REPOSITORY_ROOT = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
export function tempDir(t, prefix = "v71-distribution-") {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return directory;
}

export function sha256HexOfFile(filePath) {
  return createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

export function writeFiles(root, files) {
  for (const [relativePath, content] of Object.entries(files)) {
    const absolute = path.join(root, relativePath);
    fs.mkdirSync(path.dirname(absolute), { recursive: true });
    fs.writeFileSync(absolute, content);
  }
}

function module(id, modulePath, overrides = {}) {
  return {
    id,
    title: `Module ${id}`,
    path: modulePath,
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

export function fixtureTask(id, overrides = {}) {
  return {
    id,
    title: `Task ${id}`,
    lane: "test-lane",
    depends_on: [],
    modules: ["M01"],
    contracts: ["C01"],
    acceptance: ["A01"],
    legacy_tasks: [],
    audit_findings: [],
    write_scopes: [`scopes/${id}/`],
    resources: [],
    deliverables: ["fixture deliverable"],
    implementation: ["fixture step"],
    independent_review: false,
    initial_status: "pending",
    authorization: "local-source-and-fixtures-only",
    completion_contract: "test evidence",
    task_revision: 1,
    acceptance_levels: {},
    acceptance_role: "leaf",
    verification_command_policy: "leaf owner registers exact commands",
    ...overrides,
  };
}

export function fixtureDocuments({ architecture = {}, execution = {}, distribution } = {}) {
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
      module("M01", "src/core/"),
      module("M02", "src/optional/"),
      module("M03", "src/shared/"),
    ],
    contracts: [
      { id: "C01", title: "Core port", owner_module: "M01", consumers: ["M02"], semantics: "fixture port", revision: 1 },
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
        permitted_levels: ["tool-test"],
        procedure_scope: "fixture",
      },
    ],
    tasks: [
      fixtureTask("T01", { modules: ["M01", "M03"], packages: ["org.test.core"] }),
      fixtureTask("T02", { depends_on: ["T01"], modules: ["M02"], packages: ["org.test.optional"] }),
    ],
    milestones: [{ id: "MI1", title: "Fixture join", tasks: ["T01", "T02"] }],
    scope_note: "fixture",
  };
  return {
    architecture: { ...baseArchitecture, ...architecture },
    execution: { ...baseExecution, ...execution },
    distribution: distribution ?? null,
  };
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
        modules: ["M01", "M03"],
        optional: false,
        provides: ["conversation.v1", "extension-host.v1", "usage-journal.v1"],
        activation: "core-start",
        artifact_status: "not-built",
        measured_bytes: null,
        implementation_tasks: ["T01"],
      },
      {
        id: "org.test.optional",
        title: "Optional",
        requires_package: ["org.test.core"],
        modules: ["M02"],
        optional: true,
        provides: ["analytics.v1"],
        activation: "on-demand",
        artifact_status: "not-built",
        measured_bytes: null,
        implementation_tasks: ["T02"],
      },
    ],
    profiles: [
      { id: "minimal", title: "Minimal", selected_packages: ["org.test.core"], forbidden_packages: ["org.test.optional"] },
      { id: "full", title: "Full", selected_packages: ["org.test.core", "org.test.optional"], forbidden_packages: [] },
    ],
    rules: { dependencies: "requires_package only; fixed target catalog" },
    notes: ["synthetic fixture"],
    ...overrides,
  };
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

export function fixtureGraph({ distribution = fixtureDistribution(), architecture = {}, execution = {} } = {}) {
  return graphFromDocuments(fixtureDocuments({ architecture, execution, distribution }));
}

/** The minimum schema a fixture graph document needs so the CLI's structure gate runs. */
const FIXTURE_SCHEMA_REQUIRED = Object.freeze({
  project: ["schema_version", "project", "plan", "architecture", "execution"],
  architecture: ["schema_version", "revision", "status", "baseline_commit", "directions", "modules", "contracts", "edges", "scope_note"],
  execution: ["schema_version", "revision", "architecture_revision", "baseline", "policy", "cases", "tasks", "milestones", "scope_note"],
  distribution: ["schema_version", "revision", "status", "core_package", "packages", "profiles", "rules", "notes"],
});

/** Write a loadable fixture project (documents plus the sibling schemas the CLI requires). */
export function writeFixtureProject(directory, documents) {
  const files = {
    "project.json": {
      schema_version: 1,
      project: "fixture",
      plan: "fixture-plan",
      architecture: "architecture.json",
      execution: "execution.json",
      ...(documents.distribution ? { distribution: "distribution.json" } : {}),
    },
    "architecture.json": documents.architecture,
    "execution.json": documents.execution,
  };
  if (documents.distribution) files["distribution.json"] = documents.distribution;
  for (const [name, document] of Object.entries(files)) {
    const stem = name.replace(/\.json$/u, "");
    files[`${stem}.schema.json`] = `${JSON.stringify({
      $schema: "https://json-schema.org/draft/2020-12/schema",
      type: "object",
      required: [...FIXTURE_SCHEMA_REQUIRED[stem]],
    }, null, 2)}\n`;
    files[name] = `${JSON.stringify(document, null, 2)}\n`;
  }
  writeFiles(directory, files);
  return path.join(directory, "project.json");
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

