import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { localArtifactReason, inspectCandidate } from "../artifacts.mjs";
import { analyzePaths, validateImpactRegistry, eventBase } from "../impact.mjs";
import { inspectRegistry, sourceCandidates, unregisteredConfigurations } from "../state-machines.mjs";
import { compareObservation, observeReference } from "../upstream.mjs";
import { CLIENT_MODULE_CATALOG } from "../../regression/client-module-catalog.mjs";

test("local artifacts are rejected outside conventional roots; reusable source stays allowed", () => {
  for (const name of ["feature/progress.md", "notes/run-report.json", "nested/plans/design.md", "bench/measurements.log"]) {
    assert.ok(localArtifactReason(name));
  }
  assert.ok(localArtifactReason("notes.md", "# Development report\n"));
  assert.equal(localArtifactReason("tools/report.mjs"), null);
  assert.equal(localArtifactReason("schemas/test-report.schema.json"), null);
  assert.equal(localArtifactReason("tests/fixtures/result-report.json", '{"fixture":true}'), null);
});

test("an index-only report cannot hide behind a cleaned worktree file", (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), "candidate-artifact-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  execFileSync("git", ["init", "-q", root]);
  writeFileSync(path.join(root, "notes.md"), "# Development report\nLocal result.\n");
  execFileSync("git", ["add", "notes.md"], { cwd: root });
  writeFileSync(path.join(root, "notes.md"), "# Module boundary\nStable guidance.\n");
  assert.deepEqual(inspectCandidate(root).findings, [{ file: "notes.md", snapshot: "index", reason: "local-work-document" }]);
});

test("local graph projections cannot be written into public documentation", () => {
  const root = fileURLToPath(new URL("../../../", import.meta.url));
  const result = spawnSync(process.execPath, ["tools/architecture-graph/cli.mjs", "render",
    "--project", "absent.json", "--out", "docs/local-graph-output"], { cwd: root, encoding: "utf8" });
  assert.equal(result.status, 2);
  assert.match(JSON.parse(result.stderr).error, /output must stay ignored/);
});

test("a vendor edit warns only for that vendor, while the common parser reaches all adapters", () => {
  const vendor = analyzePaths(["crates/licoup-native/src/platform/codex_app_server/config.rs"]);
  assert.deepEqual(vendor.live.map((entry) => entry.id), ["codex"]);
  assert.ok(vendor.regressionModules.some((id) => id.includes("codex")));
  assert.ok(vendor.live.every((entry) => !entry.blocking && entry.status === "not-run"));
  const shared = analyzePaths(["crates/licoup-agent-adapter-sdk/src/lifecycle.rs"]);
  assert.ok(shared.live.length > 1);
  const pty = analyzePaths(["crates/licoup-foundation/src/platform/pty_transport.rs"]);
  assert.deepEqual(pty.live.map((entry) => entry.id), shared.live.map((entry) => entry.id));
  assert.ok(pty.regressionModules.includes("rust.platform.codex-app-server"));
  assert.ok(pty.regressionModules.some((id) => id.startsWith("rust.platform.claude-code-driver.")));
});

test("configuration edits select the bound runtime checks and vendor warnings", () => {
  const result = analyzePaths(["crates/licoup-native/resources/state-machines/codex.json"]);
  assert.deepEqual(result.live.map((entry) => entry.id), ["codex"]);
  assert.ok(result.regressionModules.includes("rust.platform.codex-app-server"));
  assert.deepEqual(result.unresolvedOwners, []);
  assert.equal(result.stateConfigurations.length, 1);
});

function syntheticRegistry() {
  const catalog = ["a", "b", "c"].map((id) => ({ ...CLIENT_MODULE_CATALOG[0], id, inputs: [`src/${id}/**`] }));
  const owners = ["a", "b", "c"].map((id, index, ids) => ({ id, guide: `docs/${id}.md`, sourceRoots: [`src/${id}`], regressionModules: [id],
    boundaries: [{ inputs: [`src/${id}/contract.rs`], consumers: [ids[(index + 1) % ids.length]] }] }));
  return { catalog, owners };
}

test("contract impact follows transitive consumers even in a cyclic runtime graph", () => {
  const { catalog, owners } = syntheticRegistry();
  assert.deepEqual(analyzePaths(["src/a/private.rs"], owners, catalog).regressionModules, ["a"]);
  assert.deepEqual(analyzePaths(["src/a/contract.rs"], owners, catalog).regressionModules, ["a", "b", "c"]);
  owners[0].boundaries[0].consumers = ["missing"];
  assert.throws(() => validateImpactRegistry(owners, catalog), /unknown boundary consumer/);
});

test("PR analysis uses the base commit instead of inspecting an empty CI worktree", () => {
  assert.equal(eventBase({ pull_request: { base: { sha: "a".repeat(40) } } }), "a".repeat(40));
  assert.equal(eventBase({ before: "0".repeat(40) }), null);
  assert.equal(eventBase({ before: "--untrusted-option" }), null);
});

test("a module's registered suite covers a new owned file absent from narrower catalog inputs", () => {
  const { catalog, owners } = syntheticRegistry();
  catalog[0].inputs = ["src/a/old.rs"];
  const result = analyzePaths(["src/a/new.rs", "src/unknown/new.rs"], owners, catalog);
  assert.deepEqual(result.regressionModules, ["a"]);
  assert.deepEqual(result.uncoveredPaths, ["src/unknown/new.rs"]);
});

test("state registry rejects duplicate machine authorities and missing executor bindings", () => {
  const machine = { machines: [{ id: "same", states: [{ id: "ready" }], initial: "ready", events: [], transitions: [] }] };
  const entries = ["one", "two"].map((id) => ({ id, owner: "example", configuration: `${id}.json`, executor: "execute.rs", verification: "verify:example" }));
  const ports = { read: () => JSON.stringify(machine), exists: () => true, scripts: { "verify:example": "run" } };
  assert.deepEqual(inspectRegistry(entries, ports).map((entry) => entry.status), ["configuration-valid", "failed"]);
  assert.equal(inspectRegistry(entries.slice(0, 1), { ...ports, exists: () => false })[0].status, "failed");
});

test("unregistered source state declarations remain visible instead of being called compliant", () => {
  const candidates = sourceCandidates(["src/runtime.rs", "tests/fixture.rs"], () => "enum RuntimeState { Ready, Done }", []);
  assert.deepEqual(candidates, [{ file: "src/runtime.rs", line: 1, symbol: "RuntimeState", status: "needs-classification" }]);
});

test("a newly added configuration must register independently of the existing registry", () => {
  const files = ["known.json", "resources/new.json", "tests/ui/model.json", "tests/fixtures/example.json", "unrelated.json"];
  const read = (file) => JSON.stringify(file === "unrelated.json" ? { status: "ready" } : { machines: [] });
  assert.deepEqual(unregisteredConfigurations(files, read, [{ configuration: "known.json" }]), ["resources/new.json", "tests/ui/model.json"]);
});

test("upstream observation never implies compatibility and pending changes survive refresh", async () => {
  const previous = { validator: "etag:one" };
  const changed = compareObservation(previous, { available: true, validator: "etag:two" });
  assert.equal(changed.status, "changed-review-required");
  assert.equal(compareObservation(changed, { available: true, validator: "etag:two" }).status, "changed-review-required");
  const unavailable = await observeReference("https://example.invalid/spec", changed, async () => { throw new Error("offline"); });
  assert.equal(unavailable.pendingReview, true);
  assert.equal(unavailable.protocolCompatibility, "unverified");
  assert.equal(unavailable.status, "unavailable");
});
