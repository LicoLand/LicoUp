import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import {
  fixtureDocuments,
  fixtureDistribution,
  fixtureGraph,
  tempDir,
  writeFiles,
  writeFixtureProject,
  REPOSITORY_ROOT,
} from "./fixtures.mjs";

const CLI = "tools/distribution/resolve/cli.mjs";

function runCli(args, { cwd = REPOSITORY_ROOT } = {}) {
  const result = spawnSync(process.execPath, [CLI, ...args], { cwd, encoding: "utf8" });
  return {
    status: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
    json: result.stdout.trim().length > 0 ? JSON.parse(result.stdout) : null,
    error: result.stderr.trim().length > 0 ? JSON.parse(result.stderr) : null,
  };
}

function setupFixtureProject(t) {
  const directory = tempDir(t);
  const documents = fixtureDocuments({ distribution: fixtureDistribution() });
  const project = writeFixtureProject(directory, documents);
  return { directory, project, documents };
}

function listFiles(directory) {
  return fs.readdirSync(directory, { recursive: true }).sort();
}

test("profile and removal previews print declarations and write nothing", (t) => {
  const { directory, project } = setupFixtureProject(t);
  const before = listFiles(directory);

  const profile = runCli(["profile", "minimal", "--project", project, "--repo-root", directory]);
  assert.equal(profile.status, 0, profile.stderr);
  assert.deepEqual(profile.json.dependency_closure, ["org.test.core"]);
  assert.equal(profile.json.measured_bytes, null);
  assert.deepEqual(profile.json.delivery_tasks.map((task) => task.id), ["T01"]);

  const removal = runCli(["removal-preview", "full", "--package", "org.test.optional", "--project", project, "--repo-root", directory]);
  assert.equal(removal.status, 0, removal.stderr);
  assert.equal(removal.json.can_remove_bytes_in_this_model, true);
  assert.deepEqual(removal.json.blocking_dependents, []);

  assert.deepEqual(listFiles(directory), before, "a preview must not write into the project");
});

test("the closure command cross-checks the product semantics against the graph", (t) => {
  const { directory, project } = setupFixtureProject(t);
  const matching = runCli(["closure", "org.test.optional", "--project", project, "--repo-root", directory]);
  assert.equal(matching.status, 0, matching.stderr);
  assert.deepEqual(matching.json.graph_closure, ["org.test.core", "org.test.optional"]);
  assert.deepEqual(matching.json.product_semantics.selected, ["org.test.core", "org.test.optional"]);
  assert.equal(matching.json.matches_graph_closure, true);

  const refused = runCli(["closure", "org.test.absent", "--project", project, "--repo-root", directory]);
  assert.equal(refused.status, 2);
  assert.equal(refused.json.matches_graph_closure, false);
  assert.equal(refused.json.product_semantics.code, "install_package_unavailable");
});

test("the check command reports provider ownership gaps end to end", (t) => {
  const { directory, project } = setupFixtureProject(t);
  const result = runCli(["check", "--project", project, "--repo-root", directory]);
  assert.equal(result.status, 2, "a catalog that is not the product distribution must not pass");
  assert.equal(result.json.ok, false);
  assert.ok(result.json.provider.issues.some((issue) => issue.code === "capability_owner_absent"
    && issue.package === "org.licoland.adapter.generic"));
  assert.ok(result.json.profiles.every((profile) => profile.contains_core));
  assert.equal(result.json.development_dag.deployment_edges_entering, 0);
});

test("the fourth graph and render commands write deterministic outputs", (t) => {
  const { directory, project } = setupFixtureProject(t);
  const graphOut = path.join(directory, "fourth.json");
  const built = runCli(["fourth-graph", "--out", graphOut, "--project", project, "--repo-root", directory]);
  assert.equal(built.status, 0, built.stderr);
  const fourth = JSON.parse(fs.readFileSync(graphOut, "utf8"));
  assert.equal(fourth.profiles.length, 2);
  assert.match(fourth.fourth_graph_digest, /^[0-9a-f]{64}$/u);

  const firstOut = path.join(directory, "render-a");
  const secondOut = path.join(directory, "render-b");
  for (const out of [firstOut, secondOut]) {
    const rendered = runCli(["render", "--out", out, "--project", project, "--repo-root", directory]);
    assert.equal(rendered.status, 0, rendered.stderr);
    assert.ok(rendered.json.files.includes("distribution.fourth.mmd"));
  }
  for (const name of fs.readdirSync(firstOut)) {
    assert.equal(fs.readFileSync(path.join(firstOut, name), "utf8"), fs.readFileSync(path.join(secondOut, name), "utf8"), name);
  }
});

test("lock build and verify work end to end and report byte drift", (t) => {
  const { directory, project, documents } = setupFixtureProject(t);
  const graph = fixtureGraph({ distribution: documents.distribution });
  writeFiles(directory, {
    "packages/core/bin/host": "core host bytes\n",
    "packages/optional/bin/agent": "agent bytes\n",
    "build.json": `${JSON.stringify({
      schema: "licoup.distribution-build.v1",
      graph_digest: graph.graphDigest,
      source_revision: "0".repeat(40),
      packages: [
        { id: "org.test.core", version: "0.3.0", root: "packages/core", artifacts: [{ path: "bin/host" }] },
        { id: "org.test.optional", version: "1.0.0", root: "packages/optional", artifacts: [{ path: "bin/agent" }] },
      ],
    }, null, 2)}\n`,
  });
  const lockPath = path.join(directory, "lock.json");
  const built = runCli(["lock", "build", "--build", "build.json", "--artifacts", directory, "--out", lockPath, "--project", project, "--repo-root", directory]);
  assert.equal(built.status, 0, built.stderr);
  assert.equal(built.json.packages, 2);

  const verified = runCli(["lock", "verify", "--lock", lockPath, "--artifacts", directory, "--project", project, "--repo-root", directory]);
  assert.equal(verified.status, 0, verified.stderr);
  assert.equal(verified.json.ok, true);

  fs.appendFileSync(path.join(directory, "packages/optional/bin/agent"), "tampered");
  const drifted = runCli(["lock", "verify", "--lock", lockPath, "--artifacts", directory, "--project", project, "--repo-root", directory]);
  assert.equal(drifted.status, 2);
  assert.equal(drifted.json.ok, false);
  assert.ok(drifted.json.issues.some((issue) => issue.code === "artifact_digest_changed"));

  const declarationsOnly = runCli(["lock", "verify", "--lock", lockPath, "--project", project, "--repo-root", directory]);
  assert.equal(declarationsOnly.status, 0, declarationsOnly.stderr);
  assert.equal(declarationsOnly.json.attribution, null);
});

test("a broken input is reported as an error, not as a verdict", (t) => {
  const directory = tempDir(t);
  const result = runCli(["check", "--project", path.join(directory, "missing.json"), "--repo-root", directory]);
  assert.equal(result.status, 2);
  assert.equal(result.error.ok, false);
  assert.match(result.error.error, /missing/u);
});
