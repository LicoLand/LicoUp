import { readFileSync } from "node:fs";

const style = readFileSync(new URL("style.css", import.meta.url), "utf8");
const interaction = readFileSync(new URL("interaction.js", import.meta.url), "utf8");
// Reports are English. A bilingual source object carries its maintained English text in
// `en`; `zh` is a review label and is never what a generated report shows.
export const label = (value) => value && typeof value === "object" ? value.en : value;
export const escape = (value) => String(label(value) ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
export const list = (items) => `<ul>${items.map((item) => `<li>${escape(item)}</li>`).join("")}</ul>`;
export const chevron = '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m7 4 6 6-6 6"/></svg>';

export class ReportPage {
  constructor(title, active, now, { planAvailable = false } = {}) { this.title = title; this.active = active; this.now = now; this.planAvailable = planAvailable; this.details = []; this.graphCount = 0; }
  detail(value) { this.details.push(value); return this.details.length - 1; }
  card({ id, title, subtitle, body = "", detail, bullets = [], badge, collapsed = false, open = false, kind = "" }) {
    const attributes = detail ? `data-detail="${this.detail(detail)}"` : "";
    const badges = (Array.isArray(badge) ? badge : badge ? [badge] : []).filter(Boolean).map((value) => `<span class="badge">${escape(value)}</span>`).join("");
    const heading = `<div class="card-heading"><h2>${escape(title)}</h2>${badges}${chevron}</div>${subtitle ? `<p>${escape(subtitle)}</p>` : ""}`;
    const inside = `${bullets.length ? `<div class="acceptance">${list(bullets)}</div>` : ""}${body}`;
    return collapsed
      ? `<details class="report-card ${kind}" ${id ? `id="${escape(id)}"` : ""} ${open ? "open" : ""}><summary class="card-head">${heading}</summary><div class="card-content">${inside}</div></details>`
      : `<article class="report-card ${kind}" ${id ? `id="${escape(id)}"` : ""}><button class="card-head" ${attributes}>${heading}</button><div class="card-content">${inside}</div></article>`;
  }
  render(body) {
    const navigation = [["index.html", "Overview"], ...(this.planAvailable ? [["delivery-plan.html", "Delivery plan"]] : []), ["workflows.html", "Workflows"], ["state-machines.html", "State machines"], ["architecture.html", "Architecture"]];
    const data = JSON.stringify(this.details).replaceAll("<", "\\u003c");
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,"><title>${escape(this.title)} · LicoUp</title><style>${style}</style></head><body><header class="site-header"><a class="brand" href="index.html">LicoUp<span>Engineering reports</span></a><nav aria-label="Reports">${navigation.map(([href, title]) => `<a href="${href}" ${href === this.active ? 'aria-current="page"' : ""}>${title}</a>`).join("")}</nav></header><main><div class="page-heading"><h1>${escape(this.title)}</h1></div>${body}<footer>${escape(this.now)}</footer></main><aside id="detail" role="dialog" aria-modal="false" aria-labelledby="detail-title" hidden><header><h2 id="detail-title"></h2><button class="close" aria-label="Close detail"><svg viewBox="0 0 20 20"><path d="m5 5 10 10M15 5 5 15"/></svg></button></header><div id="detail-body"></div></aside><script id="report-data" type="application/json">${data}</script><script>${interaction}</script></body></html>`;
  }
}
