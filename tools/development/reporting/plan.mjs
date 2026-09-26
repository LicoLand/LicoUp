import { ReportPage, label } from "./page.mjs";
import { graphView } from "./graph.mjs";
import { directedLayout, laneLayout } from "./graph-layout.mjs";

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
  const overview = directedLayout(plan.milestones.map((milestone, index) => ({
    code: milestone.id, title: `${index + 1}. ${label(milestone.title)}`,
    detail: { title: label(milestone.title), description: label(milestone.outcome),
      sections: [{ title: "Acceptance", items: milestone.acceptance.map(label) }], target: `milestone-${milestone.id}` },
  })), plan.milestones.flatMap((milestone) => milestone.requires.map((from) => ({ from, to: milestone.id }))));
  return [overview, ...plan.milestones.map((milestone) => {
    const requirements = new Map((milestone.requirements ?? []).map((requirement) => [requirement.code, requirement.statement]));
    const names = new Map(milestone.tasks.flatMap((task) => task.nodes.map((node) => [node.code, `${label(task.title)} · ${label(node.title)}`])));
    const lanes = milestone.tasks.map((task) => ({ ...task, title: label(task.title),
      detail: { title: label(task.title), description: label(task.outcome), sections: taskSections(task, requirements) },
      nodes: task.nodes.map((node) => ({ ...node, title: label(node.title), outcome: label(node.outcome),
        detail: { title: label(node.title), description: label(node.outcome), sections: [
          { title: "Owner", items: [label(task.title)] },
          { title: "This Worker's delivery outcome", items: [label(task.outcome)] },
          { title: "Prerequisite deliverables", items: node.prerequisites.map((code) => names.get(code)) },
          ...taskSections(task, requirements, node),
        ] },
      })),
    }));
    // Better Plan's declared full regression follows every Task. Show that
    // lifecycle join without adding a Task, checkpoint or execution authority.
    if (milestone.fullRegression?.commands?.length && lanes.length) {
      const nodes = lanes.flatMap((lane) => lane.nodes);
      const predecessors = new Set(nodes.flatMap((node) => node.prerequisites));
      const detail = { title: "Milestone integration handoff", description: "After every Worker has delivered, the integration owner completes source review, in-scope repairs and deterministic regression.", sections: [
        { title: "Join condition", items: lanes.map((lane) => `${lane.title}: ${label(lane.outcome)}`) },
        { title: "Acceptance", items: milestone.acceptance.map(label) },
        { title: "Regression commands", items: milestone.fullRegression.commands },
        { title: "Regression scope", items: milestone.fullRegression.paths ?? [] },
        { title: "Stopping condition", items: ["Deliver the engineering evidence; live acceptance and the next milestone are assigned separately by the maintainer."] },
      ] };
      lanes.push({ title: "Integration owner", detail, nodes: [{ code: `${milestone.id}-handoff`, title: "Review · regression · handoff",
        terminal: true, detail, prerequisites: nodes.filter((node) => !predecessors.has(node.code)).map((node) => node.code) }] });
    }
    return laneLayout(lanes);
  })];
}

export function renderPlan({ plan, now }) {
  const page = new ReportPage("Delivery plan", "delivery-plan.html", now, { planAvailable: true });
  const graphs = planGraphs(plan);
  const overview = page.card({ id: "milestone-overview", kind: "milestone-overview", title: "Delivery overview", badge: "Better Plan",
    detail: { title: "Delivery plan", description: label(plan.summary), sections: [
      { title: "Execution boundary", items: (plan.rules ?? []).map(label) },
      { title: "Open decisions", items: (plan.decisions ?? []).map(label) },
    ] }, body: graphView(page, graphs[0], "Milestone dependency graph") });
  const milestones = plan.milestones.map((milestone, index) => page.card({
    id: `milestone-${milestone.id}`, kind: "milestone", title: `${index + 1}. ${label(milestone.title)}`,
    subtitle: milestone.outcome, bullets: milestone.acceptance.slice(0, 3),
    badge: ({ draft: "Draft", designing: "Designing", ready: "Ready", authorized: "Authorized", revising: "Revising", completed: "Completed", blocked: "Blocked" })[milestone.phase],
    detail: { title: label(milestone.title), description: label(milestone.outcome), sections: [
      { title: "Acceptance", items: milestone.acceptance.map(label) },
      { title: "Entry condition", items: [label(milestone.entry)] },
      { title: "Current evidence", items: [label(milestone.evidence)] },
      { title: "Overall design", items: [milestone.architecture?.summary, ...(milestone.architecture?.notes ?? [])].filter(Boolean) },
      { title: "Integration regression commands", items: milestone.fullRegression?.commands ?? [] },
      { title: "Integration regression scope", items: milestone.fullRegression?.paths ?? [] },
      { title: "Decisions to discuss", items: (milestone.decisions ?? []).map((decision) => typeof decision === "string" ? decision : decision.question ?? decision.statement ?? decision.summary ?? decision.code) },
    ] }, body: graphView(page, graphs[index + 1], `${label(milestone.title)} execution graph`),
  })).join("");
  return page.render(overview + milestones);
}
