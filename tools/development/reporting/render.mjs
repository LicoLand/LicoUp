import { ReportPage, escape, label, chevron } from "./page.mjs";
import { graphView } from "./graph.mjs";
import { directedLayout } from "./graph-layout.mjs";

const moduleNames = {
  conversation: "Conversation", workflow: "Workflow engine", presentation: "Presentation data", "endpoint-collaboration": "Endpoint collaboration",
  "extension-platform": "Extension platform", "client-ui": "Client UI", "agent-runtime": "Agent runtime",
  "native-bridge": "Native bridge", catalogs: "Models and usage", gateway: "Model gateway", "data-migration": "Data migration",
  distribution: "Distribution", development: "Development tooling",
};
const name = (value) => moduleNames[value] ?? String(value).replaceAll(/[._-]/gu, " ");
const evidenceNames = {
  "Workflow report tooling": "Report tooling", "Change impact": "Change impact", "Source structure": "Source structure",
  "State machine review": "State machine review", "Upstream observations": "Upstream observations", "Module regression": "Module regression",
  "Privacy review summary": "Privacy review", "Release acceptance": "Release acceptance", "Completed privacy review": "Completed privacy review",
  "Engineering closure receipt": "Engineering closure receipt",
};

export function renderIndex({ now, receipts, plan }) {
  const page = new ReportPage("Project reports", "index.html", now, { planAvailable: !!plan });
  const cards = [
    ...(plan ? [["delivery-plan.html", "Delivery plan", "Local Better Plan workspace"]] : []),
    ["workflows.html", "Workflows", "From requirements discussion to engineering handoff"],
    ["state-machines.html", "State machines", "States, events and transitions"],
    ["architecture.html", "Architecture", "Modules and their dependencies"],
  ];
  const links = cards.map(([href, title, subtitle]) => `<article class="report-card"><a class="report-link" href="${href}"><div class="card-heading"><h2>${title}</h2>${chevron}</div><p>${subtitle}</p></a></article>`).join("");
  const evidence = receipts.map((entry) => page.card({ title: evidenceNames[entry.title] ?? entry.title,
    subtitle: entry.present ? "Record present, scope to confirm" : "Not generated",
    detail: { title: evidenceNames[entry.title] ?? entry.title,
      description: entry.present ? "A record is stored; whether it covers the current source must be confirmed against its scope." : "This report has not been generated.",
      sections: entry.modified ? [{ title: "File updated", items: [entry.modified] }] : [],
      ...(entry.present ? { link: { label: "Open record", href: entry.file } } : {}),
    },
  })).join("");
  return page.render(`<div class="card-grid">${links}</div><h2 class="section-heading">Engineering records</h2><div class="card-grid evidence-grid">${evidence}</div>`);
}

export function renderWorkflows({ now, workflows, plan }) {
  const page = new ReportPage("Workflows", "workflows.html", now, { planAvailable: !!plan });
  return page.render(workflows.map((flow, index) => {
    const details = { title: label(flow.title), description: label(flow.purpose), sections: [
      { title: "Owner", items: [label(flow.owner)] }, { title: "Entry condition", items: [label(flow.entry)] },
      { title: "Exit condition", items: [label(flow.exit)] }, { title: "Failure handling", items: [label(flow.failure)] },
      { title: "Execution boundary", items: [label(flow.boundary)] },
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
      detail: { title: `${stateNames.get(first.from_state)} to ${stateNames.get(first.to_state)}`,
        sections: [{ title: "Triggering events", items: transitions.map((edge) => `${eventName(edge)}${edge.guard ? ` · ${typeof edge.guard === "string" ? edge.guard : JSON.stringify(edge.guard)}` : ""}`) }] },
    };
  });
  const initial = machine.initial ?? machine.initial_state;
  const terminals = new Set(machine.terminal ?? []);
  const nodes = machine.states.map((state) => ({ code: state.id, title: stateNames.get(state.id), initial: state.id === initial,
    terminal: terminals.has(state.id), detail: { title: stateNames.get(state.id),
      description: state.id === initial ? "Initial state" : terminals.has(state.id) ? "Terminal state" : undefined,
      sections: [
        { title: "Outgoing", items: outgoing.get(state.id) },
        { title: "Incoming", items: incoming.get(state.id) },
      ],
    },
  }));
  return directedLayout(nodes, edges, { labeled: true });
}

export function renderMachines({ now, machines, plan }) {
  const page = new ReportPage("State machines", "state-machines.html", now, { planAvailable: !!plan });
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
    if (entry.kind === "dynamic") groups.get(owner).push(page.card({ title: "User-defined workflow", subtitle: "Provided at runtime",
      detail: { title: "User-defined workflow", description: "The graph is supplied by the user; this report reads no private execution instance.",
        sections: [{ title: "Implementation owner", items: [entry.provider, entry.executor] }] } }));
  }
  return page.render([...groups].map(([owner, cards]) => `<h2 class="group-title">${escape(owner)}</h2>${cards.join("")}`).join(""));
}

export function renderArchitecture({ now, architecture, plan }) {
  const page = new ReportPage("Architecture", "architecture.html", now, { planAvailable: !!plan });
  return page.render(architecture.map((view) => page.card({ title: view.title,
    detail: { title: view.title, description: "Edges point from a component to its direct dependencies and are generated from the current component definitions.",
      sections: [{ title: "Scope", items: ["Runtime component dependencies within this view; test and build-tool dependencies are not shown."] }] },
    body: graphView(page, directedLayout(view.nodes, view.edges), view.title),
  })).join(""));
}
