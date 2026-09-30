import { escape, label } from "./page.mjs";

function lines(value, width = 160) {
  const result = [];
  let current = "", used = 0;
  const measure = (token) => [...token].reduce((sum, character) => sum + (/[^\x00-\x7F]/u.test(character) ? 12 : 6.3), 0);
  const tokens = String(value ?? "").match(/[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*|\s+|[^\s]/gu) ?? [];
  for (const token of tokens) {
    const pieces = measure(token) > width ? [...token] : [token];
    for (const piece of pieces) {
      const size = measure(piece);
      if (used + size > width && current) { result.push(current.trimEnd()); current = ""; used = 0; }
      if (!current && /^\s+$/u.test(piece)) continue;
      current += piece; used += size;
    }
  }
  if (current) result.push(current.trimEnd());
  return result;
}
function text(value, x, y, width, className) {
  const parts = lines(value, width);
  return `<text class="${className}" x="${x}" y="${y}" text-anchor="middle">${parts.map((part, index) => `<tspan x="${x}" dy="${index ? 16 : -(parts.length - 1) * 8}">${escape(part)}</tspan>`).join("")}</text>`;
}

export function graphView(page, graph, title) {
  const id = `graph-${++page.graphCount}`;
  const marker = `${id}-arrow`;
  const lanes = (graph.lanes ?? []).map((lane) => `<g class="graph-lane" ${lane.detail ? `data-detail="${page.detail(lane.detail)}" role="button" tabindex="0" aria-label="${escape(lane.title)}"` : ""}><path d="M12,${lane.top + lane.height} H${graph.width - 12}"/><rect class="lane-hit" x="8" y="${lane.top}" width="140" height="${lane.height}"/>${text(label(lane.title), 76, lane.top + lane.height / 2 + 4, 140, "lane-title")}</g>`).join("");
  const edges = graph.edges.map((edge) => {
    const detail = edge.detail ? `data-detail="${page.detail(edge.detail)}" role="button" tabindex="0" aria-label="${escape(edge.label ?? edge.detail.title)}"` : "";
    const route = edge.path;
    return `<g class="graph-edge" ${detail}><path class="edge-line" d="${route}" marker-end="url(#${marker})"/>${edge.detail ? `<path class="edge-target" d="${route}"/>` : ""}${edge.label && Number.isFinite(edge.x) ? `<rect class="edge-label-bg" x="${edge.x - edge.width / 2}" y="${edge.y - edge.height / 2}" width="${edge.width}" height="${edge.height}" rx="5"/>${text(edge.label, edge.x, edge.y + 4, edge.width - 6, "edge-label")}` : ""}</g>`;
  }).join("");
  // The Tree's derived state reaches the graph as `status` on every Node; the
  // milestone overview carries the delivery's `phase` instead. Both render, because
  // a graph that cannot show which Nodes are done makes the reader open every panel
  // to answer the only question they came with.
  const state = (node) => String(node.status ?? node.phase ?? "").toLowerCase().replace(/[^a-z]/gu, "");
  const counts = graph.nodes.reduce((map, node) => {
    const key = state(node);
    return key ? map.set(key, (map.get(key) ?? 0) + 1) : map;
  }, new Map());
  // Only states the legend can style are counted; a delivery state such as
  // "planned" must not produce an empty legend or a duplicate of the badge.
  const legend = ["completed", "running", "ready", "pending", "failed", "blocked", "cancelled"]
    .map((key) => [key, counts.get(key)]).filter(([, count]) => count);
  const nodes = graph.nodes.map((node) => {
    const description = node.detail ?? { title: label(node.title), description: label(node.outcome), sections: node.owner ? [{ title: "Owner", items: [label(node.owner)] }] : [] };
    const nodeState = state(node);
    return `<g class="graph-node ${node.initial ? "initial" : ""} ${node.terminal ? "terminal" : ""} ${nodeState}${node.needsReview ? " needs-review" : ""}" data-node="${escape(node.code)}" data-detail="${page.detail(description)}" role="button" tabindex="0" aria-label="${escape(node.title)}"><title>${escape(node.title)}${nodeState ? ` — ${escape(nodeState)}` : ""}${node.needsReview ? " — Review needed" : ""}</title><rect x="${node.x - node.width / 2}" y="${node.y - node.height / 2}" width="${node.width}" height="${node.height}" rx="10"/>${node.terminal ? `<rect class="terminal-ring" x="${node.x - node.width / 2 + 4}" y="${node.y - node.height / 2 + 4}" width="${node.width - 8}" height="${node.height - 8}" rx="7"/>` : ""}${node.initial ? `<circle class="initial-dot" cx="${node.x - node.width / 2 + 12}" cy="${node.y - node.height / 2 + 12}" r="3"/>` : ""}${text(label(node.title), node.x, node.y + 4, node.width - 26, "node-title")}</g>`;
  }).join("");
  // A legend only when the graph actually carries state, and never for a single
  // value: "49 pending" beside a whole pending graph says nothing new.
  const legendMarkup = legend.length > 1 ? `<div class="graph-legend">${legend.map(([key, count]) => `<span class="legend-item"><i class="legend-swatch ${key}"></i>${key} <b>${count}</b></span>`).join("")}</div>` : "";
  return `<div class="graph-wrap"><div class="graph-tools"><button data-zoom="out" aria-label="Zoom out"><svg viewBox="0 0 20 20"><path d="M5 10h10"/></svg></button><button data-zoom="fit" aria-label="Fit width"><svg viewBox="0 0 20 20"><path d="M7 4H4v3m9-3h3v3M4 13v3h3m9-3v3h-3"/></svg></button><button data-zoom="in" aria-label="Zoom in"><svg viewBox="0 0 20 20"><path d="M5 10h10M10 5v10"/></svg></button></div><div class="graph-viewport"><svg class="execution-graph" id="${id}" viewBox="0 0 ${graph.width} ${graph.height}" style="width:${graph.width}px" data-width="${graph.width}" role="group" aria-label="${escape(title)}"><defs><marker id="${marker}" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="10" markerHeight="10" markerUnits="userSpaceOnUse" orient="auto"><path d="M2 2 10 6 2 10"/></marker></defs>${lanes}${edges}${nodes}</svg></div>${legendMarkup}${graph.nodes.some((node) => node.needsReview) ? '<div class="graph-legend">Dashed outline: review needed; completion results are retained.</div>' : ""}</div>`;
}
