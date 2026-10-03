import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { generateReports } from "../reports.mjs";
import { renderPlan, planGraphs } from "../reporting/plan.mjs";
import { stateGraph } from "../reporting/render.mjs";
import { directedLayout } from "../reporting/graph-layout.mjs";
import { architectureViews } from "../reporting/architecture.mjs";
import { loadBetterPlan } from "../reporting/adapters/better-plan.mjs";

test("engineering continuation follows recorded current delivery without granting live authority", () => {
  const workflow = JSON.parse(readFileSync(new URL("../workflows/07-engineering-handoff.json", import.meta.url), "utf8"));
  const prohibition = "Do not initiate real conversations, Computer Use or per-worker installations.";
  const continuation = "Only an explicit finite programme assignment may start the next dependency-satisfied milestone after the current milestone has been reviewed and its delivery recorded.";
  assert.equal(workflow.boundary.en, `${prohibition} ${continuation}`);
  assert.equal(workflow.boundary.zh, "不得自行启动真实对话、Computer Use 或各自安装客户端。只有在当前里程碑已通过评审且交付结果已记录后，显式有限程序安排才允许启动下一个依赖已满足的里程碑。");
  const root = mkdtempSync(path.join(tmpdir(), "licoup-handoff-report-test-"));
  try {
    const source = path.join(root, "tools/development");
    mkdirSync(path.join(source, "workflows"), { recursive: true });
    writeFileSync(path.join(source, "workflows/07-engineering-handoff.json"), JSON.stringify(workflow));
    writeFileSync(path.join(source, "state-machines.json"), "[]");
    writeFileSync(path.join(source, "architecture-views.json"), "[]");
    generateReports({ root, now: "synthetic timestamp" });
    const page = readFileSync(path.join(root, "build/reports/workflows.html"), "utf8");
    assert.ok(page.includes(prohibition));
    assert.ok(page.includes(continuation));
    assert.doesNotMatch(page, /reviewed, recorded, dependency-satisfied successor|已记录交付且依赖已满足的后续里程碑/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("report generation reflects sources without executing workflows or reading privacy payloads", () => {
  const root = mkdtempSync(path.join(tmpdir(), "licoup-report-test-"));
  const previousTool = process.env.LICOUP_BETTER_PLAN_TOOL;
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

    // The projection consumes one `programme export` call, so the fixture is the
    // tool's JSON output: a recorded Tree, a planned outline and one export error.
    const tree = { schema: "better-plan.checkpoints-tree", id: "TREE-001", title: "Recorded delivery",
      goal: "Ship the recorded delivery", success: ["The recorded delivery renders"],
      requirements: [{ code: "REQ-001", statement: { en: "One owner decides the result", zh: "中文不应渲染" }, source_ids: ["REQ-201"] }],
      open_decisions: ["Choose the supported export format. Confirm its consumer."],
      delivery_policy: { pull_requests: "draft_until_tree_review", live_acceptance: { model: "synthetic-model", instruction: { en: "Use the ordinary UI", zh: "REVIEW_LABEL_MUST_NOT_RENDER" } } },
      delivery: { result: { summary: "TREE-RESULT-SENTINEL", exceptions: ["TREE-EXCEPTION-SENTINEL", "<img src=x onerror=alert(1)>TREE-ESCAPE-SENTINEL"] },
        review: [{ source: { kind: "node", id: "NODE-003" }, reason: "TREE-REVIEW-SENTINEL" }] },
      tasks: [
        { id: "TASK-001", title: "Worker", outcome: "Delivered", draft_pr: "https://example.invalid/pull/7",
          delivery: { result: { summary: "TASK-RESULT-SENTINEL", exceptions: ["TASK-EXCEPTION-SENTINEL"] },
            review: [{ source: { kind: "node", id: "NODE-004" }, reason: "TASK-REVIEW-SENTINEL" }] },
          requirements: ["REQ-201", { statement: { en: "Task object requirement", zh: "中文" }, source_ids: ["REQ-202"] }],
          contract: {}, nodes: [
            { id: "NODE-001", title: "Implement", outcome: "Ready", role: "worker-1", after: [], status: "completed",
              review: [{ source: { kind: "node", id: "NODE-003" }, reason: "content_changed" }], result: { summary: "Design is ready", exceptions: ["NODE-EXCEPTION-SENTINEL"] }, executors: [], contract: {
                scope: { in: ["Example capability", "STOP CONDITION: preserve the source until transfer completes"], out: ["Live provider quality"] },
                design: { approach: ["Use the actual production owner"] },
                ownership: { write_paths: ["src/example.mjs"], shared_exclusive: ["Synthetic store isolated per task"] },
                acceptance: [{ given: "A synthetic input", when: "The public entry runs", then: "The declared result is returned", oracle: "Compare with the fixture", evidence: { source: "tests/example.test.mjs" } }],
                requirements: [{ statement: { en: "Node contract requirement", zh: "中文" }, source_ids: ["REQ-301"] }],
                regression_paths: ["tests/example.test.mjs"] } },
            { id: "NODE-002", title: "Verify", outcome: "Proven", role: "worker-1", after: ["NODE-001"], status: "pending", commit: "synthetic-commit", result: null, executors: [], contract: { scope: ["Current array scope"], files: { edit: ["src/current-owner.rs"] }, commit_outcome: "Complete the current owner" } },
          ] },
      ] };
    const plannedRequirements = [{ code: "REQ-PLAN-1", statement: { en: "The planned requirement statement", zh: "中文" }, source_ids: ["REQ-101", "REQ-102"] }];
    const plannedDecisions = [{ statement: { en: "Choose the planned path", zh: "中文" } }];
    const fixture = {
      schema: "better-plan.programme-export",
      programme: { schema: "better-plan.programme", id: "PROGRAMME-001", title: "Synthetic programme",
        goal: { en: "Ship the synthetic programme", zh: "中文目标不应渲染" }, success: ["The synthetic page renders"],
        deliveries: [
          { id: "DELIVERY-002", title: "Recorded delivery", tree: "delivery/Tree.json", requires: [] },
          { id: "DELIVERY-001", title: "Planned delivery", requires: ["DELIVERY-002", "DELIVERY-404"],
            goal: { en: "Design the planned delivery", zh: "中文目标" }, success: ["The outline is reviewable"],
            requirements: plannedRequirements, open_decisions: plannedDecisions },
          { id: "DELIVERY-003", title: "Broken delivery", tree: "delivery/missing/Tree.json", requires: ["DELIVERY-001"] },
        ] },
      report: {
        deliveries: [
          { id: "DELIVERY-001", title: "Planned delivery", state: "planned", execution_status: "planned", unconfirmed_tasks: [], ready_nodes: [], review_nodes: [], requires: ["DELIVERY-002", "DELIVERY-404"], blocked_by: ["DELIVERY-002"], error: null },
          { id: "DELIVERY-002", title: "Recorded delivery", state: "needs_review", execution_status: "running", unconfirmed_tasks: ["TASK-001"], ready_nodes: ["NODE-002"], review_nodes: ["NODE-001"], requires: [], blocked_by: [], error: null },
          { id: "DELIVERY-003", title: "Broken delivery", state: "error", execution_status: "missing", unconfirmed_tasks: [], ready_nodes: [], review_nodes: [], requires: ["DELIVERY-001"], blocked_by: [], error: "The Tree at delivery/missing/Tree.json could not be read." },
        ],
        ready: ["DELIVERY-002"],
        ready_to_design: ["DELIVERY-001"],
        counts: { needs_review: 1, planned: 1, error: 1 },
        errors: [],
      },
      deliveries: {
        "DELIVERY-002": { kind: "tree", tree: "delivery/Tree.json", export: { tree,
          derived: { status: "running", delivery_status: "needs_review", task_delivery_status: { "TASK-001": "needs_review" }, ready: ["NODE-002"], review_nodes: ["NODE-001"], node_counts: { completed: 1, total: 2 } },
          checks: [{ id: "CHECK-REPORT", title: "Shared report check", commands: ["node --test tests/example.test.mjs"], coverage: { kind: "tree" }, pending: true, running: true, dirty: true, result: { status: "passed" }, covers: ["NODE-001", "NODE-002"], owner: { kind: "task", id: "TASK-001" } }] } },
        "DELIVERY-001": { kind: "planned", outline: { goal: { en: "Design the planned delivery", zh: "中文目标" }, success: ["The outline is reviewable"], requirements: plannedRequirements, open_decisions: plannedDecisions } },
        "DELIVERY-003": { kind: "error", tree: "delivery/missing/Tree.json", error: "The Tree at delivery/missing/Tree.json could not be read." },
      },
      requirements: {
        catalogue: [
          { id: "AS-001", title: { en: "Accessibility baseline", zh: "中文" }, statement: { en: "The interface meets the accessibility baseline", zh: "中文" }, status: "implemented", priority: "high" },
          { id: "OR-001", title: { en: "Ordering guarantee", zh: "中文" }, statement: { en: "Deliveries run in programme order", zh: "中文" }, status: "implemented" },
          { id: "QA-001", title: { en: "Uncovered check", zh: "中文" }, statement: { en: "The uncovered requirement statement", zh: "中文" }, status: "accepted" },
          { id: "EX-001", title: { en: "Excluded item", zh: "中文" }, statement: { en: "The excluded requirement statement", zh: "中文" }, status: "excluded",
            exclusion: { en: "Out of this programme's scope", zh: "中文" }, scope_note: { en: "Tracked elsewhere", zh: "中文" },
            acceptance: [{ given: "An excluded input", when: "The scope is reviewed", then: "The exclusion is recorded", oracle: "Compare with the register", evidence: { source: "docs/register.md" } }] },
        ],
        coverage: {
          by_requirement: {
            "AS-001": { deliveries: ["DELIVERY-002"], tasks: [{ delivery: "DELIVERY-002", task: "TASK-001" }] },
            "OR-001": { deliveries: ["DELIVERY-002"], tasks: [] },
            "EX-001": { deliveries: [], tasks: [] },
          },
          uncovered: ["QA-001"],
          excluded: ["EX-001"],
          unknown_refs: [{ delivery: "DELIVERY-002", task: "TASK-001", ref: "REQ-999" }],
        },
      },
      metrics: { coverage_percent: [{ delivery: "DELIVERY-002", check: "CHECK-REPORT", owner: { kind: "task", id: "TASK-001" }, value: 87.5, status: "recorded" }] },
    };
    write("private/workspace/export.json", fixture);
    write("private/workspace/stub-tool.py", [
      "import os, sys",
      "path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'export.json')",
      "with open(path, 'r', encoding='utf-8') as handle:",
      "    sys.stdout.write(handle.read())",
    ].join("\n") + "\n");
    write("private/workspace/Programme.json", { schema: "better-plan.programme", id: "PROGRAMME-001", title: "Synthetic programme",
      deliveries: fixture.programme.deliveries });
    process.env.LICOUP_BETTER_PLAN_TOOL = path.join(root, "private/workspace/stub-tool.py");
    const programmeSource = readFileSync(path.join(root, "private/workspace/Programme.json"), "utf8");
    assert.equal(generateReports({ root, planSource: "private/workspace/Programme.json" }).pages.length, 5);
    const projected = readFileSync(path.join(root, "build/reports/delivery-plan.html"), "utf8");
    // Programme identity, goal and success list.
    assert.match(projected, /Synthetic programme/);
    assert.match(projected, /Ship the synthetic programme/);
    assert.match(projected, /The synthetic page renders/);
    // The recorded Tree delivery renders its existing execution graph plus badges.
    assert.match(projected, /1\. Recorded delivery/);
    assert.match(projected, /<span class="badge">Needs review<\/span>/);
    assert.match(projected, /<span class="badge">Running<\/span>/);
    assert.match(projected, /<span class="badge">Ready to execute<\/span>/);
    assert.match(projected, /Use the actual production owner/);
    assert.match(projected, /src\/example\.mjs/);
    assert.match(projected, /Compare with the fixture/);
    assert.match(projected, /node --test tests\/example\.test\.mjs/);
    assert.match(projected, /NODE-002/);
    assert.match(projected, /Shared report check/);
    assert.match(projected, /Running · Review needed · passed · Covers NODE-001, NODE-002/u);
    assert.match(projected, /completed needs-review/u);
    assert.match(projected, /Review needed/u);
    assert.match(projected, /Pending review/u);
    // A current needs-review delivery carries its recorded result, exceptions,
    // pending review and unconfirmed Task identity, not only the status badge.
    assert.match(projected, /TREE-RESULT-SENTINEL/u);
    assert.match(projected, /TREE-EXCEPTION-SENTINEL/u);
    assert.match(projected, /TREE-REVIEW-SENTINEL/u);
    assert.match(projected, /TASK-RESULT-SENTINEL/u);
    assert.match(projected, /TASK-EXCEPTION-SENTINEL/u);
    assert.match(projected, /TASK-REVIEW-SENTINEL/u);
    assert.match(projected, /NODE-EXCEPTION-SENTINEL/u);
    assert.match(projected, /TASK-001 · needs_review/u);
    // Exception text is projected verbatim into the escaped JSON payload; it
    // never becomes live markup in the page.
    assert.doesNotMatch(projected, /<img src=x/u);
    assert.match(projected, /Current array scope/u);
    assert.match(projected, /src\/current-owner\.rs/u);
    assert.match(projected, /Complete the current owner/u);
    assert.match(projected, /synthetic-commit/u);
    assert.match(projected, /https:\/\/example\.invalid\/pull\/7/u);
    assert.match(projected, /Use the ordinary UI/u);
    assert.match(projected, /synthetic-model/u);
    assert.match(projected, /<g class="graph-node[^"]*\bpending\b[^"]*" data-node="NODE-002"/u);
    // The planned delivery renders an outline card without an execution graph.
    assert.match(projected, /2\. Planned delivery/);
    assert.match(projected, /Ready to design/);
    assert.match(projected, /Design the planned delivery/);
    assert.match(projected, /The outline is reviewable/);
    assert.match(projected, /REQ-PLAN-1/);
    assert.match(projected, /REQ-101/);
    assert.match(projected, /REQ-102/);
    assert.match(projected, /Choose the planned path/);
    assert.match(projected, /Requires: DELIVERY-002 · Blocked by: DELIVERY-002/);
    // One broken delivery renders an error card instead of aborting the page.
    assert.match(projected, /3\. Broken delivery/);
    assert.match(projected, /The Tree at delivery\/missing\/Tree\.json could not be read\./);
    assert.match(projected, /class="error-note"/);
    // Requirement coverage: totals, groups, uncovered, excluded reasons, unknown refs.
    assert.match(projected, /Requirement coverage/);
    assert.match(projected, /4 catalogue entries/);
    assert.match(projected, /implemented <b>2<\/b>/);
    assert.match(projected, /accepted <b>1<\/b>/);
    assert.match(projected, /Accessibility baseline/);
    assert.match(projected, /Owned by DELIVERY-002/);
    assert.match(projected, /Tasks: DELIVERY-002 · TASK-001/);
    assert.match(projected, /Uncovered \(1\)/);
    assert.match(projected, /The uncovered requirement statement/);
    assert.match(projected, /Excluded \(1\)/);
    assert.match(projected, /Out of this programme's scope/);
    assert.match(projected, /Unknown references \(1\)/);
    assert.match(projected, /REQ-999/);
    // Metrics appear only when recorded, with values in programme order.
    assert.match(projected, /coverage_percent/);
    assert.match(projected, /87\.5/);
    // Unknown requires ids are a warning line, not a crash.
    assert.match(projected, /DELIVERY-001 requires 'DELIVERY-404', which is not a delivery/);
    // English-only rendering: bilingual review labels never reach the page.
    assert.doesNotMatch(projected, /中文/u);
    assert.doesNotMatch(projected, /REVIEW_LABEL_MUST_NOT_RENDER/u);
    // Only the overview and the Tree delivery draw execution graphs.
    assert.equal((projected.match(/class="execution-graph"/g) ?? []).length, 2);
    // Milestone cards and overview rows stay in programme order.
    const cardOrder = ["DELIVERY-002", "DELIVERY-001", "DELIVERY-003"].map((id) => projected.indexOf(`id="milestone-${id}"`));
    assert.ok(cardOrder[0] < cardOrder[1] && cardOrder[1] < cardOrder[2], "milestone cards follow programme order");
    assert.ok(projected.indexOf("1. Recorded delivery") < projected.indexOf("2. Planned delivery"));
    assert.ok(projected.indexOf("2. Planned delivery") < projected.indexOf("3. Broken delivery"));
    // Drawers carry the requirement ids and check ids that the page must show.
    const records = JSON.parse(projected.match(/<script id="report-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
    const hasItem = (fragment) => records.some((record) => (record.sections ?? []).some((section) => (section.items ?? []).some((item) => typeof item === "string" && item.includes(fragment))));
    assert.ok(hasItem("One owner decides the result · covers REQ-201"), "Tree requirement ids sit beside their statement");
    assert.ok(hasItem("REQ-301"), "Node requirement ids sit beside their statement");
    assert.ok(hasItem("REQ-202"), "Task requirement ids sit beside their statement");
    assert.ok(records.some((record) => record.title === "coverage_percent"
      && (record.sections ?? []).some((section) => (section.items ?? []).some((item) => item.includes("CHECK-REPORT") && item.includes("87.5") && item.includes("owner task/TASK-001")))), "the metric drawer carries the check id and owner identity");
    assert.ok(records.some((record) => (record.sections ?? []).some((section) => section.title === "Unconfirmed tasks"
      && (section.items ?? []).some((item) => item === "TASK-001 · needs_review"))), "unconfirmed Task identity stays structured");
    assert.ok(records.some((record) => (record.sections ?? []).some((section) => (section.items ?? []).some((item) => typeof item === "string" && item.includes("<img src=x onerror=alert(1)>TREE-ESCAPE-SENTINEL")))), "exception text stays escaped inside the embedded JSON");
    // The adapter never writes its source.
    assert.equal(readFileSync(path.join(root, "private/workspace/Programme.json"), "utf8"), programmeSource);

    const sourcePlan = loadBetterPlan(path.join(root, "private/workspace/Programme.json"));
    assert.deepEqual(sourcePlan.milestones.map(({ id }) => id), ["DELIVERY-002", "DELIVERY-001", "DELIVERY-003"]);
    assert.deepEqual(sourcePlan.milestones.map(({ kind }) => kind), ["tree", "planned", "error"]);
    const current = sourcePlan.milestones[0];
    assert.deepEqual(current.delivery, {
      status: "needs_review",
      result: ["TREE-RESULT-SENTINEL"],
      exceptions: ["TREE-EXCEPTION-SENTINEL", "<img src=x onerror=alert(1)>TREE-ESCAPE-SENTINEL"],
      review: ["node/NODE-003: TREE-REVIEW-SENTINEL"],
    });
    assert.deepEqual(current.taskDeliveryStatus, { "TASK-001": "needs_review" });
    assert.deepEqual(current.unconfirmedTasks, ["TASK-001"]);
    assert.deepEqual(current.tasks[0].detail.sections
      .find((section) => section.title === "Task delivery review").items, ["node/NODE-004: TASK-REVIEW-SENTINEL"]);
    assert.deepEqual(current.tasks[0].nodes.find((node) => node.code === "NODE-001").detail.sections
      .find((section) => section.title === "Current result exceptions").items, ["NODE-EXCEPTION-SENTINEL"]);
    assert.deepEqual(sourcePlan.metrics[0].entries[0].owner, { kind: "task", id: "TASK-001" });
    assert.equal(sourcePlan.milestones[0].state, "needs_review");
    assert.equal(sourcePlan.milestones[0].readyToExecute, true);
    assert.equal(sourcePlan.milestones[1].readyToDesign, true);
    assert.deepEqual(sourcePlan.warnings, ["DELIVERY-001 requires 'DELIVERY-404', which is not a delivery; the dependency edge is ignored."]);
    // The projection follows the Tree's own dependency edges, in Tree order.
    const graphs = planGraphs(sourcePlan);
    assert.deepEqual(graphs[0].edges.map(({ from, to }) => [from, to]), [["DELIVERY-002", "DELIVERY-001"], ["DELIVERY-001", "DELIVERY-003"]]);
    assert.deepEqual(graphs[1].edges.map(({ from, to }) => [from, to]), [["NODE-001", "NODE-002"]]);
    assert.ok(graphs[1].nodes.every((node) => node.status), "the adapter carries each Node's status");
    assert.equal(graphs[2], null, "a planned delivery has no execution graph");
    assert.equal(graphs[3], null, "an error delivery has no execution graph");
    assert.deepEqual(sourcePlan.requirements.counts, [["implemented", 2], ["accepted", 1], ["excluded", 1]]);
    assert.deepEqual(sourcePlan.requirements.groups.map(({ prefix }) => prefix), ["AS", "OR"]);
    assert.deepEqual(sourcePlan.requirements.uncovered.map(({ id }) => id), ["QA-001"]);
    assert.deepEqual(sourcePlan.requirements.excluded.map(({ id }) => id), ["EX-001"]);
    assert.deepEqual(sourcePlan.requirements.unknown.map(({ ref }) => ref), ["REQ-999"]);
    assert.deepEqual(sourcePlan.metrics.map(({ name }) => name), ["coverage_percent"]);

    generateReports({ root });
    assert.equal(existsSync(path.join(root, "build/reports/delivery-plan.html")), false);
    assert.doesNotMatch(readFileSync(path.join(root, "build/reports/index.html"), "utf8"), /delivery-plan.html/);
  } finally {
    if (previousTool === undefined) delete process.env.LICOUP_BETTER_PLAN_TOOL;
    else process.env.LICOUP_BETTER_PLAN_TOOL = previousTool;
    rmSync(root, { recursive: true, force: true });
  }
});

test("a Better Plan tool without 'programme export' fails with operator guidance", () => {
  const root = mkdtempSync(path.join(tmpdir(), "licoup-better-plan-tool-"));
  const previousTool = process.env.LICOUP_BETTER_PLAN_TOOL;
  try {
    mkdirSync(path.join(root, "workspace"), { recursive: true });
    writeFileSync(path.join(root, "workspace", "unsupported.py"),
      "import sys\nsys.stderr.write(\"error: argument command: invalid choice: 'export'\\n\")\nsys.exit(2)\n");
    process.env.LICOUP_BETTER_PLAN_TOOL = path.join(root, "workspace", "unsupported.py");
    assert.throws(() => loadBetterPlan(path.join(root, "workspace", "Programme.json")), /update the Better Plan skill/i);
  } finally {
    if (previousTool === undefined) delete process.env.LICOUP_BETTER_PLAN_TOOL;
    else process.env.LICOUP_BETTER_PLAN_TOOL = previousTool;
    rmSync(root, { recursive: true, force: true });
  }
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

// The graph is where a reader looks for progress. A Node's derived state used to
// reach only its detail panel, so a 49-Node Tree drew every box identically and the
// reader had to open each one to learn which were done. The panel is not a substitute
// for the picture, so the state is asserted on the drawn node itself.
test("derived Node state reaches the execution graph, not only the detail panel", () => {
  const tasks = [{ code: "A", title: "Worker A", outcome: "Domain", nodes: [
    { code: "a", title: "Done", outcome: "Core", status: "completed", prerequisites: [] },
    { code: "b", title: "Waiting", outcome: "Core", status: "pending", prerequisites: [] },
  ] }];
  const milestone = { id: "first", title: "First feature", outcome: "Outcome", acceptance: ["One"], requires: [], phase: "authorized", tasks };
  const drawn = (html) => new Map([...html.matchAll(/<g class="graph-node([^"]*)" data-node="([^"]*)"/gu)]
    .map((match) => [match[2], match[1].trim().split(/\s+/u)]));
  const html = renderPlan({ now: "synthetic", plan: { summary: "Summary", milestones: [milestone] } });
  const classes = drawn(html);
  assert.ok(classes.get("a").includes("completed"), "a completed Node is drawn as completed");
  assert.ok(classes.get("b").includes("pending"), "a pending Node is drawn as pending");
  assert.ok(classes.get("first").includes("authorized"), "the overview draws the delivery phase");
  assert.match(html, /<div class="graph-legend">.*completed <b>1<\/b>.*pending <b>1<\/b>/u);
  // A graph whose Nodes share one state says nothing the box colour has not already
  // said, so the legend stays out of the way. The phase is cleared too: it is drawn
  // on the overview Node and would otherwise be the second state.
  const uniform = renderPlan({ now: "synthetic", plan: { summary: "Summary",
    milestones: [{ ...milestone, phase: undefined, tasks: [{ ...tasks[0], nodes: tasks[0].nodes.map((node) => ({ ...node, status: "pending" })) }] }] } });
  assert.doesNotMatch(uniform, /<div class="graph-legend">/u);
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

// The reviewed report sources are reusable repository data, not private evidence.
// Each one carries an exact admission in the maintained Auditor policy; the policy
// uses the published exact policy declarations without wildcard admissions.
test("reviewed report sources keep exact policy admissions", () => {
  const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
  const policy = JSON.parse(readFileSync(path.join(repoRoot, ".lico-auditor/policy.json"), "utf8"));
  assert.deepEqual(Object.keys(policy), ["schemaVersion", "allowedJsonPaths", "reviewedSchemaFixtures", "reviewedSchemaHistory", "publicReferenceDomains", "reviewedUnixPathLiterals"]);
  assert.equal(policy.schemaVersion, 1);
  const workflowNames = [
    "01-requirements",
    "02-milestone",
    "03-parallel-development",
    "04-integration-review",
    "05-engineering-verification",
    "06-data-transition",
    "07-engineering-handoff",
    "08-live-acceptance",
    "09-defect-repair",
    "10-privacy-review",
    "11-contribution",
    "12-release",
    "13-installed-milestone-candidate",
  ];
  const reviewed = [
    ["tools/development/architecture-views.json", "json"],
    ["tools/development/state-machines.json", "json"],
    ...workflowNames.map((name) => [`tools/development/workflows/${name}.json`, "config-object"]),
  ];
  const developmentDeclarations = policy.allowedJsonPaths
    .filter((entry) => entry.path.startsWith("tools/development/"))
    .map((entry) => ({ path: entry.path, kind: entry.kind }));
  assert.deepEqual(developmentDeclarations, reviewed.map(([relativePath, kind]) => ({ path: relativePath, kind })));
  for (const [relativePath, kind] of reviewed) {
    const data = JSON.parse(readFileSync(path.join(repoRoot, relativePath), "utf8"));
    if (kind === "json") assert.ok(Array.isArray(data), `${relativePath} keeps its declared array shape`);
    else assert.equal(typeof data === "object" && data !== null && !Array.isArray(data), true, `${relativePath} keeps its declared object shape`);
  }
});
