import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { generateReports } from "../reports.mjs";
import { renderPlan, planGraphs } from "../reporting/plan.mjs";
import { stateGraph } from "../reporting/render.mjs";
import { directedLayout } from "../reporting/graph-layout.mjs";
import { architectureViews } from "../reporting/architecture.mjs";
import { loadBetterPlan } from "../reporting/adapters/better-plan.mjs";

test("report generation reflects sources without executing workflows or reading privacy payloads", () => {
  const root = mkdtempSync(path.join(tmpdir(), "licoup-report-test-"));
  const write = (file, value) => {
    mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    writeFileSync(path.join(root, file), typeof value === "string" ? value : JSON.stringify(value));
  };
  try {
    write("tools/development/workflows/01-example.json", { id: "example", file: "01-example.json", title: "<script>example</script>",
      purpose: "Synthetic workflow", owner: "Maintainer", entry: "Request", steps: ["Discuss", "Deliver"], exit: "Closed", failure: "Repair", boundary: "No execution" });
    write("tools/development/state-machines.json", [{ id: "synthetic", owner: "example", configuration: "config.json" }]);
    write("config.json", { machines: [{ id: "example", initial: "ready", states: [{ id: "ready" }, { id: "done" }], transitions: [{ from_state: "ready", event: "finish", to_state: "done" }] }] });
    write("tools/development/architecture-views.json", []);
    write("docs/plans/current/plan.json", "PRIVATE_DRAFT_NOT_AN_INPUT");
    write("build/reports/privacy-audit/example.reviewed.html", "PRIVATE_PAYLOAD_MUST_NOT_BE_COPIED");
    // Receipt existence is useful even if its payload is unreadable; rendering
    // must not interpret arbitrary evidence as executable source or success.
    write("build/reports/repo-local-info-hygiene.json", "PRIVATE_PAYLOAD_MUST_NOT_BE_COPIED");
    const first = generateReports({ root, now: "synthetic timestamp" });
    assert.equal(first.pages.length, 4);
    assert.equal(first.configuredMachines, 1);
    const index = readFileSync(path.join(root, "build/reports/index.html"), "utf8");
    assert.match(index, /privacy-audit\/example.reviewed.html/);
    assert.match(index, /Not generated/);
    assert.doesNotMatch(index, /PRIVATE_PAYLOAD/);
    assert.doesNotMatch(index, /delivery-plan.html|PRIVATE_DRAFT/);
    const flow = readFileSync(path.join(root, "build/reports/workflows.html"), "utf8");
    assert.match(flow, /&lt;script&gt;example/);
    assert.doesNotMatch(flow, /<script>example<\/script>/);
    assert.match(readFileSync(path.join(root, "build/reports/state-machines.html"), "utf8"), /finish/);
    write("config.json", { machines: [] });
    assert.equal(generateReports({ root }).configuredMachines, 0);

    const native = { schema: "better-plan.plan/v3", code: "PLAN-001", directory: "delivery", phase: "draft", title: "Synthetic delivery",
      intent: { goal: "Example outcome", success: ["Observable result"], scope: { in: ["Example capability"] } },
      spec: { architecture: { notes: ["Milestone prerequisites: none."] },
        full_regression: { commands: ["node --test tests/integration.test.mjs"], paths: ["tests/integration.test.mjs"] },
        tasks: [{ code: "TASK-001", title: "Worker", outcome: "Delivered", nodes: [
        { code: "NODE-001", title: "Implement", outcome: "Ready", prerequisites: [] },
        { code: "NODE-002", title: "Verify", outcome: "Proven", prerequisites: ["NODE-001"] },
      ], design: { approach: ["Use the actual production owner"] },
      ownership: { write_paths: ["src/example.mjs"], shared_exclusive: ["Synthetic store isolated per task"] },
      acceptance: [{ given: "A synthetic input", when: "The public entry runs", then: "The declared result is returned", oracle: "Compare with the fixture", evidence: { source: "tests/example.test.mjs" } }],
      focused_regression: { commands: ["node --test tests/example.test.mjs"], paths: ["tests/example.test.mjs"] } }] } };
    write("private/workspace/Manifest.json", { schema: "better-plan.manifest/v3", plans: [{ code: native.code, title: native.title, directory: "delivery", plan: "delivery/Plan.json" }] });
    write("private/workspace/delivery/Plan.json", native);
    const source = readFileSync(path.join(root, "private/workspace/delivery/Plan.json"), "utf8");
    assert.equal(generateReports({ root, planSource: "private/workspace/Manifest.json" }).pages.length, 5);
    const projected = readFileSync(path.join(root, "build/reports/delivery-plan.html"), "utf8");
    assert.match(projected, /Synthetic delivery/);
    assert.match(projected, /Use the actual production owner/);
    assert.match(projected, /src\/example.mjs/);
    assert.match(projected, /Compare with the fixture/);
    assert.match(projected, /node --test tests\/example.test.mjs/);
    assert.match(projected, /Milestone integration handoff/);
    assert.equal(readFileSync(path.join(root, "private/workspace/delivery/Plan.json"), "utf8"), source);
    assert.equal(existsSync(path.join(root, "private/workspace/delivery/Checkpoints.json")), false);
    const successor = structuredClone(native);
    successor.code = "PLAN-002";
    successor.directory = "successor";
    successor.spec.architecture.notes = ["Milestone prerequisites: delivery."];
    write("private/workspace/successor/Plan.json", successor);
    write("private/workspace/Manifest.json", { schema: "better-plan.manifest/v3", plans: [
      { code: successor.code, plan: "successor/Plan.json" },
      { code: native.code, plan: "delivery/Plan.json" },
    ] });
    const sourcePlan = loadBetterPlan(path.join(root, "private/workspace/Manifest.json"));
    assert.deepEqual(planGraphs(sourcePlan)[0].edges.map(({ from, to }) => [from, to]), [["PLAN-001", "PLAN-002"]]);
    const deliveryGraph = planGraphs(sourcePlan)[2];
    assert.deepEqual(deliveryGraph.edges.map(({ from, to }) => [from, to]), [["NODE-001", "NODE-002"], ["NODE-002", "PLAN-001-handoff"]]);
    generateReports({ root });
    assert.equal(existsSync(path.join(root, "build/reports/delivery-plan.html")), false);
    assert.doesNotMatch(readFileSync(path.join(root, "build/reports/index.html"), "utf8"), /delivery-plan.html/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("execution layout preserves explicit joins and source dependency order", () => {
  const tasks = [
    { code: "A", title: "Worker A", outcome: "Domain", nodes: [{ code: "a", title: "Domain", outcome: "Core", prerequisites: [] }] },
    { code: "B", title: "Worker B", outcome: "View", nodes: [{ code: "b", title: "View", outcome: "UI", prerequisites: [] }] },
    { code: "C", title: "Integrator", outcome: "Review both", nodes: [{ code: "join", title: "Deliver", outcome: "Reviewed", prerequisites: ["a", "b"] }] },
  ];
  const milestone = { id: "first", title: "First feature", outcome: "Outcome", acceptance: ["One", "Two"], requires: [], tasks };
  const plan = { summary: "Summary", statusNote: "No work activated", milestones: [milestone, { ...milestone, id: "second", title: "Second feature", requires: ["first"] }] };
  const [overview, first] = planGraphs(plan);
  assert.deepEqual(overview.edges.map(({ from, to }) => [from, to]), [["first", "second"]]);
  assert.deepEqual(first.edges.map(({ from, to }) => [from, to]), [["a", "join"], ["b", "join"]]);
  const byCode = new Map(first.nodes.map((node) => [node.code, node]));
  assert.equal(byCode.get("a").x, byCode.get("b").x);
  assert.notEqual(byCode.get("a").y, byCode.get("b").y);
  assert.ok(byCode.get("join").x > byCode.get("a").x);
  const html = renderPlan({ now: "synthetic", plan });
  assert.ok(html.indexOf('id="milestone-overview"') < html.indexOf('id="milestone-first"'));
  assert.ok(html.indexOf('id="milestone-first"') < html.indexOf('id="milestone-second"'));
  assert.equal((html.match(/class="execution-graph"/g) ?? []).length, 3);
  assert.doesNotMatch(html, /<select/);
});

test("state diagrams preserve return paths, self-loops and parallel transition conditions", () => {
  const graph = stateGraph({ id: "execution", initial: "ready", terminal: ["done"],
    states: [{ id: "ready" }, { id: "active" }, { id: "done" }],
    transitions: [
      { from_state: "ready", to_state: "active", event: "start" },
      { from_state: "active", to_state: "ready", event: "retry" },
      { from_state: "active", to_state: "active", event: "progress" },
      { from_state: "active", to_state: "done", event: "finish", guard: "reviewed" },
      { from_state: "active", to_state: "done", event: "cancel" },
    ],
  }, { start: "Start work" });
  assert.equal(graph.edges.length, 4);
  assert.ok(graph.nodes.find((node) => node.code === "ready").initial);
  assert.ok(graph.nodes.find((node) => node.code === "done").terminal);
  assert.equal(graph.edges.find((edge) => edge.from === "ready").label, "Start work");
  assert.ok(graph.edges.some((edge) => edge.from === "active" && edge.to === "ready"));
  const loop = graph.edges.find((edge) => edge.from === edge.to);
  assert.ok(loop.points.length > 2);
  for (const edge of graph.edges) assert.ok(edge.points.every(({ x, y }) => Number.isFinite(x) && Number.isFinite(y)));
  const finish = graph.edges.find((edge) => edge.to === "done");
  assert.deepEqual(finish.detail.sections[0].items, ["finish · reviewed", "cancel"]);
});

test("generated connectors share centered ports and finish tangent to their arrowheads", () => {
  const graph = directedLayout([
    { code: "a" }, { code: "b" }, { code: "c" }, { code: "d" },
  ], [{ from: "a", to: "b" }, { from: "a", to: "c" }, { from: "b", to: "d" },
    { from: "c", to: "d" }, { from: "d", to: "a" }, { from: "b", to: "b" }]);
  const nodes = new Map(graph.nodes.map((node) => [node.code, node]));
  for (const edge of graph.edges) {
    const source = nodes.get(edge.from), target = nodes.get(edge.to);
    const values = edge.path.match(/-?\d+(?:\.\d+)?/g).map(Number);
    assert.deepEqual(values.slice(0, 2), [source.x + source.width / 2, source.y]);
    assert.deepEqual(values.slice(-2), [target.x - target.width / 2, target.y]);
    assert.equal(values.at(-3), target.y);
    assert.equal(values[3], source.y);
    assert.doesNotMatch(edge.path, /[LHVA]/);
  }
});

test("plan labels cannot break out of the embedded JSON script", () => {
  const plan = { summary: "</script><script>unsafe</script>", statusNote: "Draft", milestones: [] };
  const html = renderPlan({ plan, now: "synthetic" });
  assert.doesNotMatch(html, /<script>unsafe<\/script>/);
  const raw = html.match(/<script id="report-data" type="application\/json">([\s\S]*?)<\/script>/)[1];
  assert.equal(JSON.parse(raw)[0].description, "</script><script>unsafe</script>");
});

test("architecture edges follow runtime package definitions instead of impact consumers", () => {
  const root = mkdtempSync(path.join(tmpdir(), "licoup-architecture-test-"));
  const write = (file, value) => {
    mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    writeFileSync(path.join(root, file), value);
  };
  try {
    const components = ["a", "b", "c"].map((id) => ({ title: id, manifest: `crates/${id}/Cargo.toml` }));
    write("tools/development/architecture-views.json", JSON.stringify([{ title: "Synthetic components", components }]));
    write("Cargo.toml", '[workspace.dependencies]\nb = { path = "crates/b" }\n');
    write("crates/a/Cargo.toml", '[package]\nname="a"\n[dependencies]\nb.workspace=true\n[dev-dependencies]\nc={path="../c"}\n');
    for (const id of ["b", "c"]) write(`crates/${id}/Cargo.toml`, `[package]\nname="${id}"\n`);
    const edges = () => architectureViews(root)[0].edges.map(({ from, to }) => [from, to]);
    assert.deepEqual(edges(), [[components[0].manifest, components[1].manifest]]);
    write("crates/a/Cargo.toml", '[package]\nname="a"\n[target.\'cfg(unix)\'.dependencies]\nc={path="../c"}\n');
    assert.deepEqual(edges(), [[components[0].manifest, components[2].manifest]]);
    assert.deepEqual(architectureViews(root)[0].edges[0].detail.sections[0].items, ["cfg(unix)"]);
    write("packages/widget/pubspec.yaml", 'name: widget\ndependencies:\n  core:\n    path: ../core\n');
    write("packages/core/pubspec.yaml", 'name: core\n');
    write("tools/development/architecture-views.json", JSON.stringify([{ title: "Synthetic Dart components", components: [
      { title: "Widget", manifest: "packages/widget/pubspec.yaml" }, { title: "Core", manifest: "packages/core/pubspec.yaml" },
    ] }]));
    assert.deepEqual(edges(), [["packages/widget/pubspec.yaml", "packages/core/pubspec.yaml"]]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
