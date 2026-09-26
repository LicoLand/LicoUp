"use strict";

const records = JSON.parse(document.getElementById("report-data").textContent);
const drawer = document.getElementById("detail");
let origin;
function fitVisibleGraphs() {
  for (const svg of document.querySelectorAll(".execution-graph")) {
    const viewport = svg.closest(".graph-viewport");
    if (!viewport.clientWidth || svg.dataset.manual) continue;
    const scale = Math.max(0.75, Math.min(1, (viewport.clientWidth - 12) / Number(svg.dataset.width)));
    svg.dataset.scale = scale;
    svg.style.width = `${Number(svg.dataset.width) * scale}px`;
  }
}
fitVisibleGraphs();
window.addEventListener("resize", fitVisibleGraphs);
document.addEventListener("toggle", fitVisibleGraphs, true);
function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text != null) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function closeDetail() { drawer.hidden = true; origin?.focus(); }
function openDetail(index, trigger) {
  const record = records[index];
  if (!record) return;
  origin = trigger;
  document.getElementById("detail-title").textContent = record.title;
  const body = document.getElementById("detail-body");
  body.replaceChildren();
  if (record.description) body.appendChild(element("p", record.description, "detail-description"));
  for (const section of record.sections ?? []) {
    if (!(section.items ?? []).length) continue;
    body.appendChild(element("h3", section.title));
    const list = element("ul");
    for (const item of section.items) list.appendChild(element("li", item));
    body.appendChild(list);
  }
  if (record.link) {
    const link = element("a", record.link.label, "detail-link");
    link.href = record.link.href;
    body.appendChild(link);
  }
  if (record.target) {
    const button = element("button", "查看里程碑", "detail-link");
    button.addEventListener("click", () => { closeDetail(); document.getElementById(record.target)?.scrollIntoView({ block: "start", behavior: "smooth" }); });
    body.appendChild(button);
  }
  drawer.hidden = false;
  drawer.querySelector(".close").focus();
}
document.addEventListener("click", (event) => {
  const trigger = event.target.closest("[data-detail]");
  if (trigger) openDetail(Number(trigger.dataset.detail), trigger);
  const control = event.target.closest("[data-zoom]");
  if (control) {
    const viewport = control.closest(".graph-wrap").querySelector(".graph-viewport");
    const svg = viewport.querySelector("svg");
    svg.dataset.manual = "true";
    const width = Number(svg.dataset.width);
    const current = Number(svg.dataset.scale || 1);
    const next = control.dataset.zoom === "fit" ? Math.min(1, viewport.clientWidth / width)
      : Math.min(2, Math.max(0.15, current * (control.dataset.zoom === "in" ? 1.2 : 1 / 1.2)));
    svg.dataset.scale = next;
    svg.style.width = `${width * next}px`;
  }
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeDetail();
  if ((event.key === "Enter" || event.key === " ") && event.target.matches("[data-detail][role=button]")) {
    event.preventDefault(); openDetail(Number(event.target.dataset.detail), event.target);
  }
});
drawer.querySelector(".close").addEventListener("click", closeDetail);
