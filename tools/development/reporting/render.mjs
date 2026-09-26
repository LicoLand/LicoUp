import { ReportPage, escape, label, chevron } from "./page.mjs";
import { graphView } from "./graph.mjs";
import { directedLayout } from "./graph-layout.mjs";

const moduleNames = {
  conversation: "会话", workflow: "工作流引擎", presentation: "界面数据", "endpoint-collaboration": "端点与协作",
  "extension-platform": "扩展平台", "client-ui": "客户端界面", "agent-runtime": "智能体运行时",
  "native-bridge": "原生桥接", catalogs: "模型与用量", gateway: "模型网关", "data-migration": "数据迁移",
  distribution: "分发与发布", development: "开发工具",
};
const name = (value) => moduleNames[value] ?? String(value).replaceAll(/[._-]/gu, " ");
const evidenceNames = {
  "Workflow report tooling": "报告工具", "Change impact": "改动影响", "Source structure": "源码结构",
  "State machine review": "状态机检查", "Upstream observations": "上游观察", "Module regression": "模块回归",
  "Privacy review summary": "隐私审阅", "Release acceptance": "发布验收", "Completed privacy review": "隐私审阅结论",
  "Engineering closure receipt": "工程交付记录",
};

export function renderIndex({ now, receipts, plan }) {
  const page = new ReportPage("项目报告", "index.html", now, { planAvailable: !!plan });
  const cards = [
    ...(plan ? [["delivery-plan.html", "临时计划", "Better Plan 本地工作区"]] : []),
    ["workflows.html", "工作流", "从需求讨论到工程交付"],
    ["state-machines.html", "状态机", "状态、事件与转移"],
    ["architecture.html", "架构", "模块及其依赖"],
  ];
  const links = cards.map(([href, title, subtitle]) => `<article class="report-card"><a class="report-link" href="${href}"><div class="card-heading"><h2>${title}</h2>${chevron}</div><p>${subtitle}</p></a></article>`).join("");
  const evidence = receipts.map((entry) => page.card({ title: evidenceNames[entry.title] ?? entry.title,
    subtitle: entry.present ? "已有记录 · 待核对" : "尚未生成",
    detail: { title: evidenceNames[entry.title] ?? entry.title,
      description: entry.present ? "记录已保存；是否适用于当前源码需核对其范围。" : "尚未生成这项报告。",
      sections: entry.modified ? [{ title: "文件更新时间", items: [entry.modified] }] : [],
      ...(entry.present ? { link: { label: "查看记录", href: entry.file } } : {}),
    },
  })).join("");
  return page.render(`<div class="card-grid">${links}</div><h2 class="section-heading">工程记录</h2><div class="card-grid evidence-grid">${evidence}</div>`);
}

export function renderWorkflows({ now, workflows, plan }) {
  const page = new ReportPage("工作流", "workflows.html", now, { planAvailable: !!plan });
  return page.render(workflows.map((flow, index) => {
    const details = { title: label(flow.title), description: label(flow.purpose), sections: [
      { title: "负责人", items: [label(flow.owner)] }, { title: "开始条件", items: [label(flow.entry)] },
      { title: "完成条件", items: [label(flow.exit)] }, { title: "异常处理", items: [label(flow.failure)] },
      { title: "执行边界", items: [label(flow.boundary)] },
    ] };
    const nodes = flow.steps.map((step, stepIndex) => ({ code: `${flow.id}-${stepIndex}`, title: label(step),
      detail: { ...details, title: label(step) }, initial: stepIndex === 0, terminal: stepIndex === flow.steps.length - 1,
    }));
    const edges = nodes.slice(1).map((node, nodeIndex) => ({ from: nodes[nodeIndex].code, to: node.code }));
    return page.card({ id: flow.id, title: `${index + 1}. ${label(flow.title)}`, detail: details,
      body: graphView(page, directedLayout(nodes, edges), label(flow.title)) });
  }).join(""));
}

export function stateGraph(machine, eventLabels = {}) {
  const stateNames = new Map(machine.states.map((state) => [state.id, label(state.label ?? state.title ?? state.id)]));
  const localLabels = Object.fromEntries((machine.events ?? []).filter((event) => typeof event === "object").map((event) => [event.id, event.label ?? event.id]));
  const eventName = (edge) => label(localLabels[edge.event ?? edge.action] ?? eventLabels[edge.event ?? edge.action] ?? edge.event ?? edge.action);
  const groups = new Map();
  const incoming = new Map(machine.states.map((state) => [state.id, []]));
  const outgoing = new Map(machine.states.map((state) => [state.id, []]));
  for (const transition of machine.transitions) {
    const key = JSON.stringify([transition.from_state, transition.to_state]);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(transition);
    incoming.get(transition.to_state).push(`${eventName(transition)}：${stateNames.get(transition.from_state)}`);
    outgoing.get(transition.from_state).push(`${eventName(transition)}：${stateNames.get(transition.to_state)}`);
  }
  // Group only parallel edges with the same endpoints; every triggering event
  // and condition remains available on that edge's detail record.
  const edges = [...groups.values()].map((transitions) => {
    const first = transitions[0];
    const events = [...new Set(transitions.map(eventName))];
    const full = events.join(" / ");
    const short = full.length > 25 ? `${String(events[0]).slice(0, 21)} …` : full;
    return { from: first.from_state, to: first.to_state, label: short,
      detail: { title: `${stateNames.get(first.from_state)} 至 ${stateNames.get(first.to_state)}`,
        sections: [{ title: "触发事件", items: transitions.map((edge) => `${eventName(edge)}${edge.guard ? ` · ${typeof edge.guard === "string" ? edge.guard : JSON.stringify(edge.guard)}` : ""}`) }] },
    };
  });
  const initial = machine.initial ?? machine.initial_state;
  const terminals = new Set(machine.terminal ?? []);
  const nodes = machine.states.map((state) => ({ code: state.id, title: stateNames.get(state.id), initial: state.id === initial,
    terminal: terminals.has(state.id), detail: { title: stateNames.get(state.id),
      description: state.id === initial ? "初始状态" : terminals.has(state.id) ? "终止状态" : undefined,
      sections: [
        { title: "转出", items: outgoing.get(state.id) },
        { title: "转入", items: incoming.get(state.id) },
      ],
    },
  }));
  return directedLayout(nodes, edges, { labeled: true });
}

export function renderMachines({ now, machines, plan }) {
  const page = new ReportPage("状态机", "state-machines.html", now, { planAvailable: !!plan });
  let first = true;
  const groups = new Map();
  for (const entry of machines) {
    const owner = name(entry.owner);
    if (!groups.has(owner)) groups.set(owner, []);
    for (const machine of entry.machines) {
      const title = label(machine.label ?? machine.title ?? name(machine.id));
      const graph = stateGraph(machine, entry.eventLabels);
      groups.get(owner).push(page.card({ title, collapsed: true, open: first, kind: "state-card",
        body: graphView(page, graph, title) }));
      first = false;
    }
    if (entry.kind === "dynamic") groups.get(owner).push(page.card({ title: "用户定义工作流", subtitle: "运行时提供",
      detail: { title: "用户定义工作流", description: "图由用户提供，此报告不读取私人执行实例。",
        sections: [{ title: "实现归属", items: [entry.provider, entry.executor] }] } }));
  }
  return page.render([...groups].map(([owner, cards]) => `<h2 class="group-title">${escape(owner)}</h2>${cards.join("")}`).join(""));
}

export function renderArchitecture({ now, architecture, plan }) {
  const page = new ReportPage("架构", "architecture.html", now, { planAvailable: !!plan });
  return page.render(architecture.map((view) => page.card({ title: view.title,
    detail: { title: view.title, description: "连线从组件指向其直接依赖，读取当前组件定义自动生成。",
      sections: [{ title: "范围", items: ["当前视图内的运行时组件依赖；测试和构建工具依赖不在此图中。"] }] },
    body: graphView(page, directedLayout(view.nodes, view.edges), view.title),
  })).join(""));
}
