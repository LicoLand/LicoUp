import dagre from "@dagrejs/dagre";
import { cubicConnector, routedConnector } from "./edge-routing.mjs";

// Extracted from Better Plan's dagLayers: preserve its dependency columns for
// execution lanes. State graphs use Dagre because they can contain cycles.
export function dagLayers(nodes) {
  const byCode = new Map(nodes.map((node) => [node.code, node]));
  const depth = new Map();
  function visit(node, stack) {
    if (depth.has(node.code)) return depth.get(node.code);
    if (stack.has(node.code)) throw new Error("Execution graph contains a cycle");
    stack.add(node.code);
    let value = 0;
    for (const code of node.prerequisites ?? []) {
      if (!byCode.has(code)) throw new Error("Execution graph has an unknown prerequisite");
      value = Math.max(value, visit(byCode.get(code), stack) + 1);
    }
    stack.delete(node.code);
    depth.set(node.code, value);
    return value;
  }
  const layers = [];
  for (const node of nodes) {
    const rank = visit(node, new Set());
    (layers[rank] ??= []).push(node);
  }
  return layers.filter(Boolean);
}

export function laneLayout(tasks) {
  const all = tasks.flatMap((task) => task.nodes);
  const layers = dagLayers(all);
  const columns = new Map(layers.flatMap((layer, rank) => layer.map((node) => [node.code, rank])));
  const nodes = [];
  const lanes = [];
  let top = 24;
  for (const task of tasks) {
    const groups = layers.map((layer) => layer.filter((node) => task.nodes.includes(node)));
    const height = Math.max(1, ...groups.map((group) => group.length)) * 84 + 16;
    lanes.push({ title: task.title, detail: task.detail, top, height });
    for (const group of groups) group.forEach((node, row) => {
      nodes.push({ ...node, owner: task.title, x: 166 + columns.get(node.code) * 210 + 85,
        y: top + height / 2 + (row - (group.length - 1) / 2) * 84, width: 170, height: 60 });
    });
    top += height;
  }
  const byCode = new Map(nodes.map((node) => [node.code, node]));
  const edges = nodes.flatMap((node) => (node.prerequisites ?? []).map((code) => {
    const from = byCode.get(code);
    return { from: code, to: node.code, ...cubicConnector(from, node) };
  }));
  return { nodes, edges, lanes, width: 190 + layers.length * 210, height: top + 8 };
}

// Node and edge identities remain intact through layout. Multigraph routing
// retains return paths, parallel transitions and self-loops.
export function directedLayout(nodes, edges, { labeled = false } = {}) {
  const graph = new dagre.graphlib.Graph({ multigraph: true });
  graph.setGraph({ rankdir: "LR", nodesep: 40, ranksep: labeled ? 120 : 72, edgesep: 30, marginx: labeled ? 65 : 30, marginy: labeled ? 95 : 35 });
  graph.setDefaultEdgeLabel(() => ({}));
  for (const node of nodes) graph.setNode(node.code, { width: node.width ?? 176, height: node.height ?? 64 });
  edges.forEach((edge, index) => graph.setEdge(edge.from, edge.to, {
    width: labeled ? Math.min(156, Math.max(64, (edge.label?.length ?? 0) * 9)) : 0,
    height: labeled ? 28 : 0, labelpos: "c",
  }, String(index)));
  dagre.layout(graph);
  const positioned = nodes.map((node) => ({ ...node, ...graph.node(node.code) }));
  const byCode = new Map(positioned.map((node) => [node.code, node]));
  return {
    nodes: positioned,
    edges: edges.map((edge, index) => {
      const layout = graph.edge({ v: edge.from, w: edge.to, name: String(index) });
      return { ...edge, ...layout, ...routedConnector(byCode.get(edge.from), byCode.get(edge.to), layout, positioned) };
    }),
    lanes: [], width: graph.graph().width ?? 300, height: graph.graph().height ?? 120,
  };
}
