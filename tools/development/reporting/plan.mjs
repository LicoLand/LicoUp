import { ReportPage, label, escape, list } from "./page.mjs";
import { graphView } from "./graph.mjs";
import { directedLayout, laneLayout } from "./graph-layout.mjs";

const STATE_LABELS = { planned: "Planned", unrecorded: "Unrecorded", recorded: "Recorded", needs_review: "Needs review", missing: "Missing", error: "Error" };
const EXECUTION_LABELS = { planned: "Planned", pending: "Pending", running: "Running", completed: "Completed", failed: "Failed", blocked: "Blocked", cancelled: "Cancelled", missing: "Missing" };
const stateLabel = (value) => STATE_LABELS[value] ?? (value ? String(value) : null);
const executionLabel = (value) => EXECUTION_LABELS[value] ?? (value ? String(value) : null);
const decisionLine = (decision) => typeof decision === "string"
  ? decision
  : label(decision?.statement ?? decision?.question ?? decision?.summary ?? decision?.code) ?? "";
const readyBadges = (milestone) => [
  milestone.readyToExecute ? "Ready to execute" : null,
  milestone.readyToDesign ? "Ready to design" : null,
].filter(Boolean);

function taskSections(task, requirements, node = null) {
  const nodeContracts = (task.design?.["node-contracts"] ?? []).filter((item) => node && item.startsWith(`${node.title}:`));
  return [
    { title: "This node's changes and verification", items: nodeContracts },
    { title: "Work scope", items: task.scope?.in ?? [] },
    { title: "Design", items: Object.entries(task.design ?? {}).filter(([topic]) => !nodeContracts.length || topic !== "node-contracts").flatMap(([topic, items]) => items.map((item) => `${topic}: ${label(item)}`)) },
    { title: "Files and directories written", items: task.ownership?.write_paths ?? [] },
    { title: "Deliverables", items: (task.outputs ?? []).map((output) => `${output.title} · ${output.artifact}: ${output.guarantee}`) },
    { title: "Acceptance and oracle", items: (task.acceptance ?? []).map((criterion) => `Given: ${criterion.given}\nWhen: ${criterion.when}\nThen: ${criterion.then}\nOracle: ${criterion.oracle}\nEvidence: ${criterion.evidence?.source ?? ""}`) },
    { title: "Regression files and scope", items: task.regression?.paths ?? [] },
    { title: "Regression commands", items: task.regression?.commands ?? [] },
    { title: "Parallel resources and exclusive ownership", items: task.ownership?.shared_exclusive ?? [] },
    { title: "Requirements covered", items: (task.requirements ?? []).map((code) => requirements.get(code)).filter(Boolean) },
    { title: "Out of scope", items: task.scope?.out ?? [] },
  ];
}

export function planGraphs(plan) {
  if (!plan) return [];
  const ids = new Set(plan.milestones.map((milestone) => milestone.id));
  const overview = directedLayout(plan.milestones.map((milestone, index) => ({
    code: milestone.id, title: `${index + 1}. ${label(milestone.title)}`, phase: milestone.phase,
    detail: { title: `${index + 1}. ${label(milestone.title)}`, description: label(milestone.outcome ?? milestone.error),
      sections: [
        { title: "Delivery state", items: [stateLabel(milestone.state)].filter(Boolean) },
        { title: "Execution status", items: [executionLabel(milestone.execution)].filter(Boolean) },
        { title: "Ready markers", items: readyBadges(milestone) },
        { title: "Requires", items: milestone.requires ?? [] },
        { title: "Blocked by", items: milestone.blockedBy ?? [] },
        { title: "Acceptance", items: (milestone.acceptance ?? []).map(label) },
      ], target: `milestone-${milestone.id}` },
  })), plan.milestones.flatMap((milestone) => (milestone.requires ?? []).filter((from) => ids.has(from)).map((from) => ({ from, to: milestone.id }))));
  return [overview, ...plan.milestones.map((milestone) => {
    // A planned outline and a broken export have no execution graph to draw.
    if (!milestone.tasks) return null;
    const requirements = new Map((milestone.requirements ?? []).map((requirement) => [requirement.code, requirement.statement]));
    const names = new Map(milestone.tasks.flatMap((task) => task.nodes.map((node) => [node.code, `${label(task.title)} · ${label(node.title)}`])));
    const lanes = milestone.tasks.map((task) => ({ ...task, title: label(task.title),
      detail: task.detail ?? { title: label(task.title), description: label(task.outcome), sections: taskSections(task, requirements) },
      nodes: task.nodes.map((node) => ({ ...node, title: label(node.title), outcome: label(node.outcome),
        detail: node.detail ?? { title: label(node.title), description: label(node.outcome), sections: [
          { title: "Owner", items: [label(task.title)] },
          { title: "This Worker's delivery outcome", items: [label(task.outcome)] },
          { title: "Prerequisite deliverables", items: node.prerequisites.map((code) => names.get(code)) },
          ...taskSections(task, requirements, node),
        ] },
      })),
    }));
    // Preserve the tool's execution graph; lifecycle review is not a synthetic Node.
    return laneLayout(lanes);
  })];
}

function deliveryList(page, plan) {
  if (!plan.milestones.length) return "";
  const rows = plan.milestones.map((milestone, index) => {
    const detail = {
      title: `${index + 1}. ${label(milestone.title)}`,
      description: label(milestone.outcome ?? milestone.error),
      sections: [
        { title: "Delivery state", items: [stateLabel(milestone.state) ?? "Unknown"] },
        { title: "Execution status", items: [executionLabel(milestone.execution) ?? "Unknown"] },
        { title: "Ready markers", items: readyBadges(milestone) },
        { title: "Requires", items: milestone.requires ?? [] },
        { title: "Blocked by", items: milestone.blockedBy ?? [] },
        { title: "Open decisions", items: (milestone.decisions ?? []).map(decisionLine) },
      ],
    };
    const marks = [stateLabel(milestone.state), executionLabel(milestone.execution), ...readyBadges(milestone)].filter(Boolean);
    return `<button type="button" class="delivery-row" data-detail="${page.detail(detail)}" role="button"><span class="delivery-name">${escape(`${index + 1}. ${label(milestone.title)}`)}</span>${marks.map((mark) => `<span class="badge">${escape(mark)}</span>`).join("")}</button>`;
  }).join("");
  return `<div class="delivery-list">${rows}</div>`;
}

function coverageCard(page, coverage) {
  if (!coverage || (!coverage.total && !coverage.uncovered.length && !coverage.excluded.length && !coverage.unknown.length)) return "";
  const entryRow = (entry) => {
    const owners = entry.owners?.deliveries ?? [];
    const tasks = (entry.owners?.tasks ?? []).map((task) => [task.delivery, task.task].filter(Boolean).join(" · "));
    const detail = {
      title: `${entry.id}${entry.title ? ` · ${entry.title}` : ""}`,
      description: entry.statement,
      sections: [
        { title: "Status", items: [entry.status].filter(Boolean) },
        { title: "Owning deliveries", items: owners },
        { title: "Owning tasks", items: tasks },
        { title: "Acceptance", items: entry.acceptance },
        { title: "Scope note", items: entry.scopeNote },
        { title: "Exclusion", items: entry.exclusion },
      ],
    };
    const parts = [`<code>${escape(entry.id)}</code>`];
    if (entry.title) parts.push(`<span class="coverage-title">${escape(entry.title)}</span>`);
    if (entry.status) parts.push(`<span class="badge">${escape(entry.status)}</span>`);
    if (owners.length) parts.push(`<span class="coverage-owners">Owned by ${escape(owners.join(", "))}</span>`);
    if (tasks.length) parts.push(`<span class="coverage-owners">Tasks: ${escape(tasks.join("; "))}</span>`);
    if (entry.exclusion.length) parts.push(`<span class="coverage-reason">${escape(entry.exclusion.join(" "))}</span>`);
    return `<li class="coverage-entry" data-detail="${page.detail(detail)}" role="button" tabindex="0">${parts.join(" ")}</li>`;
  };
  const totals = coverage.counts.map(([status, count]) => `<span class="badge">${escape(status)} <b>${count}</b></span>`).join("");
  const groups = coverage.groups.map((group) => `<h3>${escape(group.prefix)} (${group.entries.length})</h3><ul class="coverage-list">${group.entries.map(entryRow).join("")}</ul>`).join("");
  const uncovered = coverage.uncovered.length ? `<h3>Uncovered (${coverage.uncovered.length})</h3><ul class="coverage-list">${coverage.uncovered.map(entryRow).join("")}</ul>` : "";
  const excluded = coverage.excluded.length ? `<details class="coverage-excluded"><summary>Excluded (${coverage.excluded.length})</summary><ul class="coverage-list">${coverage.excluded.map(entryRow).join("")}</ul></details>` : "";
  const unknown = coverage.unknown.length ? `<h3>Unknown references (${coverage.unknown.length})</h3><ul>${coverage.unknown.map((ref) => `<li>${escape([ref.delivery, ref.task, ref.ref].filter(Boolean).join(" · "))}</li>`).join("")}</ul>` : "";
  const body = `${totals ? `<div class="coverage-totals">${totals}</div>` : ""}${groups}${uncovered}${excluded}${unknown}`;
  return page.card({ id: "requirement-coverage", kind: "coverage", title: "Requirement coverage", badge: `${coverage.total} catalogue entries`,
    detail: { title: "Requirement coverage", description: "Catalogue status, delivery ownership and uncovered or excluded entries reported by Better Plan.", sections: [
      { title: "Totals by status", items: coverage.counts.map(([status, count]) => `${status}: ${count}`) },
      { title: "Unknown references", items: coverage.unknown.map((ref) => [ref.delivery, ref.task, ref.ref].filter(Boolean).join(" · ")) },
    ] }, body });
}

function metricsCard(page, plan) {
  const metrics = plan.metrics ?? [];
  if (!metrics.length) return "";
  const headers = plan.milestones.map((milestone, index) => `<th>${escape(`${index + 1}. ${label(milestone.title)}`)}</th>`).join("");
  const rows = metrics.map((metric) => {
    const detail = {
      title: metric.name,
      description: "Recorded values by delivery, in programme order.",
      sections: plan.milestones.map((milestone) => ({
        title: `${milestone.id} · ${label(milestone.title)}`,
        items: metric.entries.filter((entry) => entry.delivery === milestone.id).map((entry) =>
          [entry.check, entry.owner ? `owner ${entry.owner}` : "", entry.value != null ? String(entry.value) : "", entry.status]
            .filter(Boolean).join(" · ")),
      })),
    };
    const cells = plan.milestones.map((milestone) => {
      const values = metric.entries.filter((entry) => entry.delivery === milestone.id).map((entry) => String(entry.value ?? "—"));
      return `<td>${values.length ? escape(values.join(", ")) : "—"}</td>`;
    }).join("");
    return `<tr class="metric-row" data-detail="${page.detail(detail)}" role="button" tabindex="0"><th scope="row">${escape(metric.name)}</th>${cells}</tr>`;
  }).join("");
  return page.card({ id: "metrics", kind: "metrics", title: "Metrics", badge: `${metrics.length} recorded ${metrics.length === 1 ? "metric" : "metrics"}`,
    detail: { title: "Metrics", description: "Recorded metric values by delivery.", sections: [{ title: "Metric names", items: metrics.map((metric) => metric.name) }] },
    body: `<div class="table-wrap"><table class="metrics-table"><thead><tr><th>Metric</th>${headers}</tr></thead><tbody>${rows}</tbody></table></div>` });
}

function milestoneCard(page, milestone, index, graph) {
  const position = `${index + 1}. ${label(milestone.title)}`;
  const marks = [stateLabel(milestone.state), executionLabel(milestone.execution), ...readyBadges(milestone)].filter(Boolean);
  if (milestone.kind === "planned") {
    const requirements = milestone.requirements.map((requirement) =>
      `<li><code>${escape(requirement.code ?? "")}</code> ${escape(requirement.statement ?? "")}${requirement.sourceIds.map((id) => ` <span class="badge">${escape(id)}</span>`).join("")}</li>`).join("");
    const meta = [
      milestone.requires.length ? `Requires: ${milestone.requires.join(", ")}` : "",
      milestone.blockedBy.length ? `Blocked by: ${milestone.blockedBy.join(", ")}` : "",
    ].filter(Boolean);
    const body = [
      milestone.acceptance.length ? `<h3>Success</h3>${list(milestone.acceptance)}` : "",
      requirements ? `<h3>Requirements</h3><ul class="requirement-list">${requirements}</ul>` : "",
      milestone.decisions.length ? `<h3>Open decisions</h3>${list(milestone.decisions.map(decisionLine))}` : "",
      meta.length ? `<p class="meta-line">${escape(meta.join(" · "))}</p>` : "",
    ].join("");
    return page.card({ id: `milestone-${milestone.id}`, kind: "milestone outline", title: position, subtitle: milestone.outcome,
      badge: milestone.readyToDesign ? "Ready to design" : "Planned", detail: {
        title: label(milestone.title), description: milestone.outcome, sections: [
          { title: "Goal", items: milestone.outcome ? [milestone.outcome] : [] },
          { title: "Success", items: milestone.acceptance },
          { title: "Requirements", items: milestone.requirements.map((requirement) => [`${requirement.code ?? ""} ${requirement.statement ?? ""}`.trim(), requirement.sourceIds.length ? `covers ${requirement.sourceIds.join(", ")}` : ""].filter(Boolean).join(" · ")) },
          { title: "Open decisions", items: milestone.decisions.map(decisionLine) },
          { title: "Delivery state", items: marks },
          { title: "Requires", items: milestone.requires },
          { title: "Blocked by", items: milestone.blockedBy },
        ] }, body });
  }
  if (milestone.kind === "error") {
    return page.card({ id: `milestone-${milestone.id}`, kind: "milestone error", title: position, subtitle: milestone.error,
      badge: "Error", detail: { title: label(milestone.title), description: milestone.error, sections: [
        { title: "Export error", items: [milestone.error] },
        { title: "Delivery state", items: marks },
        { title: "Requires", items: milestone.requires },
        { title: "Blocked by", items: milestone.blockedBy },
      ] }, body: `<p class="error-note">${escape(milestone.error)}</p>` });
  }
  return page.card({ id: `milestone-${milestone.id}`, kind: "milestone", title: position,
    subtitle: milestone.outcome, bullets: milestone.acceptance.slice(0, 3), badge: marks,
    detail: { title: label(milestone.title), description: label(milestone.outcome), sections: [
      { title: "Delivery state", items: marks },
      { title: "Acceptance", items: milestone.acceptance.map(label) },
      { title: "Entry condition", items: [label(milestone.entry)] },
      { title: "Current evidence", items: (Array.isArray(milestone.evidence) ? milestone.evidence : [milestone.evidence]).filter(Boolean).map(label) },
      { title: "Shared requirements", items: (milestone.sharedRequirements ?? []).map(label) },
      { title: "Delivery policy", items: milestone.deliveryPolicy ?? [] },
      { title: "Checks", items: milestone.checkSummary ?? [] },
      { title: "Overall design", items: [milestone.architecture?.summary, ...(milestone.architecture?.notes ?? [])].filter(Boolean) },
      { title: "Integration regression commands", items: milestone.fullRegression?.commands ?? [] },
      { title: "Integration regression scope", items: milestone.fullRegression?.paths ?? [] },
      { title: "Requires", items: milestone.requires ?? [] },
      { title: "Blocked by", items: milestone.blockedBy ?? [] },
      { title: "Decisions to discuss", items: (milestone.decisions ?? []).map(decisionLine) },
    ] }, body: graph ? graphView(page, graph, `${label(milestone.title)} execution graph`) : "" });
}

export function renderPlan({ plan, now }) {
  const page = new ReportPage("Delivery plan", "delivery-plan.html", now, { planAvailable: true });
  const graphs = planGraphs(plan);
  const overview = page.card({ id: "milestone-overview", kind: "milestone-overview", title: "Delivery overview",
    subtitle: plan.summary, bullets: plan.success ?? [], badge: `${plan.milestones.length} ${plan.milestones.length === 1 ? "delivery" : "deliveries"}`,
    detail: { title: "Delivery plan", description: label(plan.summary), sections: [
      { title: "Goal", items: plan.outcome ? [plan.outcome] : [] },
      { title: "Success", items: plan.success ?? [] },
      { title: "Execution boundary", items: (plan.rules ?? []).map(label) },
      { title: "Warnings", items: plan.warnings ?? [] },
      { title: "Open decisions", items: (plan.decisions ?? []).map(decisionLine) },
    ] },
    body: `${plan.warnings?.length ? `<p class="warning-note">${escape(plan.warnings.join(" "))}</p>` : ""}${deliveryList(page, plan)}${graphView(page, graphs[0], "Delivery dependency graph")}` });
  const coverage = coverageCard(page, plan.requirements);
  const metrics = metricsCard(page, plan);
  const milestones = plan.milestones.map((milestone, index) => milestoneCard(page, milestone, index, graphs[index + 1])).join("");
  return page.render(overview + coverage + metrics + milestones);
}
