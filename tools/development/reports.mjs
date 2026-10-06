import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync, rmSync } from "node:fs";
import { parseArgs } from "node:util";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { renderIndex, renderWorkflows, renderMachines, renderArchitecture } from "./reporting/render.mjs";

import { renderPlan } from "./reporting/plan.mjs";
import { loadBetterPlan } from "./reporting/adapters/better-plan.mjs";
import { architectureViews } from "./reporting/architecture.mjs";

const repository = fileURLToPath(new URL("../..", import.meta.url));
const json = (file) => JSON.parse(readFileSync(file, "utf8"));

// Report generation reads declared project sources. It never runs checks, Agents,
// migrations or client processes, and never interprets a saved receipt as a pass
// for the current working tree.
export function generateReports({ root = repository, output = path.join(root, "build/reports"), now = new Date().toISOString(), planSource = null } = {}) {
  const workflowDirectory = path.join(root, "tools/development/workflows");
  const workflows = readdirSync(workflowDirectory).filter((name) => name.endsWith(".json")).sort()
    .map((name) => json(path.join(workflowDirectory, name)));
  const plan = planSource ? loadBetterPlan(path.resolve(root, planSource)) : null;
  const registry = json(path.join(root, "tools/development/state-machines.json"));
  const machines = registry.map((entry) => {
    if (!entry.configuration) return { ...entry, machines: [], eventLabels: {} };
    const document = json(path.join(root, entry.configuration));
    const events = [...(Array.isArray(document.events) ? document.events : []), ...(Array.isArray(document.actions) ? document.actions : [])];
    const eventLabels = Object.fromEntries(events.filter((event) => typeof event === "object").map((event) => [event.id, event.label ?? event.id]));
    return { ...entry, machines: document.machines, eventLabels };
  });
  const sources = [
    ["Workflow report tooling", "workflow-report-tooling.json"],
    ["Change impact", "change-impact.json"],
    ["Source structure", "source-structure.json"],
    ["State machine review", "state-machines.json"],
    ["Upstream observations", "upstream-observations.json"],
    ["Module regression", "client-module-regression.json"],
    ["Privacy check summary", "../../.general-auditor/local/repo-local-info-hygiene.json"],
    ["Local contextual audit report", "../../.general-auditor/local/index.html"],
    ["Release acceptance", "client-release-acceptance.json"],
  ];
  const receipts = sources.map(([title, file]) => {
    const present = existsSync(path.join(output, file));
    return { title, file, present, modified: present ? statSync(path.join(output, file)).mtime.toISOString() : null };
  });
  // Link only local final privacy reports; raw matches must never be copied into
  // the navigation page or another generated report.
  for (const [directory, suffix, title] of [["closure", ".json", "Engineering closure receipt"]]) {
    const folder = path.join(output, directory);
    const names = existsSync(folder) ? readdirSync(folder).filter((name) => name.endsWith(suffix)).sort() : [];
    const latest = names.at(-1);
    receipts.push({ title, file: latest ? `${directory}/${latest}` : null, present: !!latest,
      modified: latest ? statSync(path.join(folder, latest)).mtime.toISOString() : null });
  }
  const context = { now, plan, workflows, machines, receipts, architecture: architectureViews(root) };
  mkdirSync(output, { recursive: true });
  const pages = {
    "index.html": renderIndex(context),
    "workflows.html": renderWorkflows(context),
    "state-machines.html": renderMachines(context),
    "architecture.html": renderArchitecture(context),
  };
  if (plan) pages["delivery-plan.html"] = renderPlan(context);
  else rmSync(path.join(output, "delivery-plan.html"), { force: true });
  for (const [name, content] of Object.entries(pages)) writeFileSync(path.join(output, name), content);
  return { pages: Object.keys(pages), workflows: workflows.length,
    configuredMachines: machines.reduce((sum, entry) => sum + entry.machines.length, 0),
    plan: plan ? "available" : "not-present" };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { values } = parseArgs({ options: { "better-plan": { type: "string" } } });
  const result = generateReports({ planSource: values["better-plan"] });
  process.stdout.write(`Generated ${result.pages.length} local HTML pages: build/reports/index.html\n`);
}
