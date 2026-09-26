import assert from "node:assert/strict";
import test from "node:test";
import { documentDate, markdownAnchors, withContentDate, validateModuleRoutes } from "../documentation.mjs";
import { sourceRisk } from "../structure.mjs";
import { runClosure, liveInventory } from "../closure.mjs";
import { validateMachines } from "../state-machines.mjs";
import { readFileSync } from "node:fs";

test("dates reject missing, duplicate, impossible and future values", () => {
  const today = "2026-09-25";
  for (const source of ["# Guide", "Updated: 2026-02-30", "Updated: 2026-09-26", "Updated: 2026-09-25\nUpdated: 2026-09-25"]) {
    assert.ok(documentDate(source, today));
  }
  assert.equal(documentDate("Updated: 2024-02-29", today), null);
});

test("link anchors support localized headings and ignore code examples", () => {
  const anchors = markdownAnchors("# 设计选择\n## Design\n## Design\n```md\n# Example\n```\n<a id=\"entry\"></a>");
  assert.deepEqual([...anchors], ["entry", "设计选择", "design", "design-1"]);
});

test("generated dates reflect content changes instead of repeated execution", () => {
  const content = "# Guide\n\nStable content.\n";
  const prior = withContentDate(content, "", "2026-09-20");
  assert.equal(withContentDate(content, prior, "2026-09-25"), prior);
  assert.match(withContentDate(content + "New fact.\n", prior, "2026-09-25"), /Updated: 2026-09-25/);
});

test("module routes fail for missing test roots and unknown verification modules", () => {
  const issues = validateModuleRoutes([{ id: "example", guide: "guide.md", testRoots: ["tests"], regressionModules: ["missing"] }], {
    exists: (file) => file === "guide.md", read: () => "npm run verify:example",
    scripts: { "verify:example": "node check.mjs" }, regressionIds: new Set(),
  });
  assert.equal(issues.length, 2);
});

test("source scanner flags large handwritten files and excludes generated outputs", () => {
  assert.equal(sourceRisk("module.rs", "line\n".repeat(800), true), null);
  assert.equal(sourceRisk("module.rs", "line\n".repeat(1001), true).severity, "HIGH RISK");
  assert.equal(sourceRisk("generated/model.rs", "line\n".repeat(1001), true), null);
  assert.equal(sourceRisk("asset.json", "line\n".repeat(1001), true), null);
});

test("closure records failures, continues independent checks and never promotes live status", () => {
  const invoked = [];
  const saved = [];
  const live = liveInventory([{ agentId: "synthetic-agent" }]);
  const result = runClosure({ entries: [
    { id: "first", command: "first" }, { id: "second", command: "second" },
  ], live, invoke(command) { invoked.push(command); return command === "first" ? 1 : 0; },
  save(value) { saved.push(structuredClone(value)); }, now: () => "2026-09-25T00:00:00Z" });
  assert.deepEqual(invoked, ["first", "second"]);
  assert.equal(saved[0].status, "running");
  assert.equal(result.status, "failed");
  assert.deepEqual(result.steps.map((step) => step.status), ["failed", "passed"]);
  assert.ok(result.live.every((entry) => entry.status === "not-run"));
});

test("launch failure cannot become a passing closure", () => {
  const result = runClosure({ entries: [{ id: "missing", command: "missing" }],
    invoke() { throw new Error("synthetic launch failure"); }, save() {} });
  assert.equal(result.status, "failed");
  assert.equal(result.steps[0].exitCode, null);
});

test("state configurations reject ambiguous transitions and terminal escapes", () => {
  const model = { machines: [{ id: "example", initial: "ready", events: ["finish"],
    terminal: ["done"], states: [{ id: "ready" }, { id: "done" }],
    transitions: [{ from_state: "ready", event: "finish", to_state: "done" }] }] };
  assert.equal(validateMachines(model)[0].transitions, 1);
  model.machines[0].transitions.push({ from_state: "ready", event: "finish", to_state: "ready" });
  assert.throws(() => validateMachines(model), /ambiguous/);
  model.machines[0].transitions[1] = { from_state: "done", event: "finish", to_state: "ready" };
  assert.throws(() => validateMachines(model), /terminal/);
});

test("optional public refactoring Skill is packaged and explicitly invoked", () => {
  const root = new URL("../../../", import.meta.url);
  const packaging = JSON.parse(readFileSync(new URL("apps/desktop/packaging.modules.json", root)));
  assert.ok(packaging.modules["user-skills"].includePaths.includes("crates/licoup-native/resources/licoup-refactor"));
  const policy = readFileSync(new URL("crates/licoup-native/resources/licoup-refactor/agents/openai.yaml", root), "utf8");
  assert.match(policy, /allow_implicit_invocation: false/);
  const defaultGuide = readFileSync(new URL("crates/licoup-native/resources/licoup-guide/SKILL.md", root), "utf8");
  assert.doesNotMatch(defaultGuide, /licoup-refactor/);
});
