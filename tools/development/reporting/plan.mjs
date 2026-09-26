import { ReportPage, label } from "./page.mjs";
import { graphView } from "./graph.mjs";
import { directedLayout, laneLayout } from "./graph-layout.mjs";

function taskSections(task, requirements, node = null) {
  const nodeContracts = (task.design?.["node-contracts"] ?? []).filter((item) => node && item.startsWith(`${node.title}:`));
  return [
    { title: "本节点的修改与验证", items: nodeContracts },
    { title: "工作范围", items: task.scope?.in ?? [] },
    { title: "设计方案", items: Object.entries(task.design ?? {}).filter(([topic]) => !nodeContracts.length || topic !== "node-contracts").flatMap(([topic, items]) => items.map((item) => `${topic}：${label(item)}`)) },
    { title: "修改文件与目录", items: task.ownership?.write_paths ?? [] },
    { title: "交付物", items: (task.outputs ?? []).map((output) => `${output.title} · ${output.artifact}：${output.guarantee}`) },
    { title: "验收目标与判定方法", items: (task.acceptance ?? []).map((criterion) => `前提：${criterion.given}\n操作：${criterion.when}\n预期：${criterion.then}\n判定：${criterion.oracle}\n证据：${criterion.evidence?.source ?? ""}`) },
    { title: "验证文件与范围", items: task.regression?.paths ?? [] },
    { title: "验证命令", items: task.regression?.commands ?? [] },
    { title: "并行资源与独占边界", items: task.ownership?.shared_exclusive ?? [] },
    { title: "覆盖需求", items: (task.requirements ?? []).map((code) => requirements.get(code)).filter(Boolean) },
    { title: "范围外", items: task.scope?.out ?? [] },
  ];
}

export function planGraphs(plan) {
  if (!plan) return [];
  const overview = directedLayout(plan.milestones.map((milestone, index) => ({
    code: milestone.id, title: `${index + 1}. ${label(milestone.title)}`,
    detail: { title: label(milestone.title), description: label(milestone.outcome),
      sections: [{ title: "验收目标", items: milestone.acceptance.map(label) }], target: `milestone-${milestone.id}` },
  })), plan.milestones.flatMap((milestone) => milestone.requires.map((from) => ({ from, to: milestone.id }))));
  return [overview, ...plan.milestones.map((milestone) => {
    const requirements = new Map((milestone.requirements ?? []).map((requirement) => [requirement.code, requirement.statement]));
    const names = new Map(milestone.tasks.flatMap((task) => task.nodes.map((node) => [node.code, `${label(task.title)} · ${label(node.title)}`])));
    const lanes = milestone.tasks.map((task) => ({ ...task, title: label(task.title),
      detail: { title: label(task.title), description: label(task.outcome), sections: taskSections(task, requirements) },
      nodes: task.nodes.map((node) => ({ ...node, title: label(node.title), outcome: label(node.outcome),
        detail: { title: label(node.title), description: label(node.outcome), sections: [
          { title: "负责人", items: [label(task.title)] },
          { title: "所属 Worker 的交付目标", items: [label(task.outcome)] },
          { title: "前置交付", items: node.prerequisites.map((code) => names.get(code)) },
          ...taskSections(task, requirements, node),
        ] },
      })),
    }));
    // Better Plan's declared full regression follows every Task. Show that
    // lifecycle join without adding a Task, checkpoint or execution authority.
    if (milestone.fullRegression?.commands?.length && lanes.length) {
      const nodes = lanes.flatMap((lane) => lane.nodes);
      const predecessors = new Set(nodes.flatMap((node) => node.prerequisites));
      const detail = { title: "里程碑集成交付", description: "所有 Worker 完成交付后，由集成负责人完成源码审阅、范围内修复和确定性回归。", sections: [
        { title: "汇合条件", items: lanes.map((lane) => `${lane.title}：${label(lane.outcome)}`) },
        { title: "验收目标", items: milestone.acceptance.map(label) },
        { title: "验证命令", items: milestone.fullRegression.commands },
        { title: "验证范围", items: milestone.fullRegression.paths ?? [] },
        { title: "停止条件", items: ["交付工程证据；真实验收和下一里程碑由维护者另行安排。"] },
      ] };
      lanes.push({ title: "集成负责人", detail, nodes: [{ code: `${milestone.id}-handoff`, title: "审阅 · 回归 · 交付",
        terminal: true, detail, prerequisites: nodes.filter((node) => !predecessors.has(node.code)).map((node) => node.code) }] });
    }
    return laneLayout(lanes);
  })];
}

export function renderPlan({ plan, now }) {
  const page = new ReportPage("交付计划", "delivery-plan.html", now, { planAvailable: true });
  const graphs = planGraphs(plan);
  const overview = page.card({ id: "milestone-overview", kind: "milestone-overview", title: "交付总览", badge: "Better Plan",
    detail: { title: "交付计划", description: label(plan.summary), sections: [
      { title: "执行边界", items: (plan.rules ?? []).map(label) },
      { title: "待确定", items: (plan.decisions ?? []).map(label) },
    ] }, body: graphView(page, graphs[0], "里程碑依赖图") });
  const milestones = plan.milestones.map((milestone, index) => page.card({
    id: `milestone-${milestone.id}`, kind: "milestone", title: `${index + 1}. ${label(milestone.title)}`,
    subtitle: milestone.outcome, bullets: milestone.acceptance.slice(0, 3),
    badge: ({ draft: "草案", designing: "设计中", ready: "就绪", authorized: "已授权", revising: "修订中", completed: "已完成", blocked: "受阻" })[milestone.phase],
    detail: { title: label(milestone.title), description: label(milestone.outcome), sections: [
      { title: "验收目标", items: milestone.acceptance.map(label) },
      { title: "开始条件", items: [label(milestone.entry)] },
      { title: "当前证据", items: [label(milestone.evidence)] },
      { title: "总体设计", items: [milestone.architecture?.summary, ...(milestone.architecture?.notes ?? [])].filter(Boolean) },
      { title: "集成验证命令", items: milestone.fullRegression?.commands ?? [] },
      { title: "集成验证范围", items: milestone.fullRegression?.paths ?? [] },
      { title: "待讨论的决定", items: (milestone.decisions ?? []).map((decision) => typeof decision === "string" ? decision : decision.question ?? decision.statement ?? decision.summary ?? decision.code) },
    ] }, body: graphView(page, graphs[index + 1], `${label(milestone.title)}执行图`),
  })).join("");
  return page.render(overview + milestones);
}
