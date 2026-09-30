import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import path from "node:path";
import { label } from "../page.mjs";

const EXPORT_SCHEMA = "better-plan.programme-export";
const DEFAULT_TOOL = path.join(homedir(), ".agents/skills/better-plan/scripts/manifest_tool.py");

// One read-only command derives the whole programme. The page never re-derives
// state, and it never falls back to per-Tree inspection when the command is
// unavailable: a missing 'programme export' tells the operator to update the
// Better Plan skill instead of rendering a second, silent ledger.
function programmeExport(root) {
  const tool = process.env.LICOUP_BETTER_PLAN_TOOL ?? DEFAULT_TOOL;
  let raw;
  try {
    raw = execFileSync("python3", [tool, "programme", "export", root], { encoding: "utf8", maxBuffer: 256 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] });
  } catch (error) {
    const detail = String(error.stderr ?? "").trim() || error.message;
    throw new Error(`The Better Plan tool could not export the programme at ${root}. If 'programme export' is not supported, update the Better Plan skill. Tool: ${tool}. ${detail}`);
  }
  let document;
  try {
    document = JSON.parse(raw);
  } catch (error) {
    throw new Error(`The Better Plan tool returned unreadable JSON for ${root}; update the Better Plan skill. ${error.message}`);
  }
  if (document.schema !== EXPORT_SCHEMA) {
    throw new Error(`The Better Plan tool returned '${document.schema ?? "no schema"}' instead of '${EXPORT_SCHEMA}' for ${root}; update the Better Plan skill.`);
  }
  return document;
}

const nodePrerequisites = (node) => (Array.isArray(node.after) ? node.after : []);
const factLines = (value, prefix = "") => {
  if (value == null) return [];
  if (Array.isArray(value)) return value.flatMap((item) => factLines(item, prefix));
  if (typeof value === "object" && ("en" in value || "zh" in value)) return factLines(value.en, prefix);
  if (typeof value === "object") return Object.entries(value).flatMap(([key, item]) =>
    factLines(item, `${prefix}${key.replaceAll("_", " ")}: `));
  return [`${prefix}${value}`];
};
const projectedContractFields = new Set(["scope", "design", "ownership", "acceptance", "outputs", "requirements", "regression_paths"]);

const owns = (node) => {
  const contract = node.contract ?? {};
  const design = contract.design ?? {};
  return {
    scope: { in: factLines(Array.isArray(contract.scope) || typeof contract.scope === "string" ? contract.scope : contract.scope?.in), out: factLines(contract.scope?.out) },
    design: Object.fromEntries(
      Object.entries({ approach: design.approach ?? [], ...design }).filter(([, items]) => Array.isArray(items) && items.length),
    ),
    ownership: contract.ownership ?? {},
    acceptance: contract.acceptance ?? [],
    outputs: contract.outputs ?? [],
    requirements: contract.requirements ?? [],
    regression: { paths: contract.regression_paths ?? [], commands: (node.checks ?? []).flatMap((check) => check.commands ?? []) },
    worker: contract.worker,
    additionalContract: factLines(Object.fromEntries(Object.entries(contract).filter(([key]) => !projectedContractFields.has(key)))),
  };
};

// Requirement ids travel beside their statement. The catalogue refs carried as
// `source_ids` are the traceability this page previously dropped on the floor.
const requirementIds = (item) => {
  if (!item || typeof item !== "object") return [];
  const value = item.source_ids ?? item.sourceIds ?? [];
  return Array.isArray(value) ? value.filter((id) => typeof id === "string") : [];
};
const requirementText = (item) => {
  if (typeof item === "string") return item;
  if (item.statement != null) return label(item.statement);
  if (item.source) return `${item.source.kind}/${item.source.id}: ${item.reason}`;
  return JSON.stringify(item);
};
const requirementLine = (item) => {
  const text = requirementText(item);
  const ids = requirementIds(item);
  return ids.length ? `${text} · covers ${ids.join(", ")}` : text;
};
const decisionLine = (decision) => typeof decision === "string"
  ? decision
  : label(decision?.statement ?? decision?.question ?? decision?.summary ?? decision?.code) ?? JSON.stringify(decision);
const criterionLine = (criterion) => typeof criterion === "string"
  ? criterion
  : `Given: ${label(criterion.given) ?? ""}\nWhen: ${label(criterion.when) ?? ""}\nThen: ${label(criterion.then) ?? ""}\nOracle: ${label(criterion.oracle) ?? ""}\nEvidence: ${label(criterion.evidence?.source) ?? ""}`;

function treeMilestone(definition, report, payload) {
  const { tree = {}, derived = {}, checks = [] } = payload.export ?? {};
  const nodes = (tree.tasks ?? []).flatMap((task) => task.nodes ?? []);
  const completed = derived.node_counts?.completed ?? 0;
  const reviewNodes = new Set(derived.review_nodes ?? []);
  const checkLines = (selected) => selected.map((check) => {
    const state = check.running ? "Running" : check.pending ? (check.ready ? "Ready to check" : "Waiting for covered work") : "Recorded";
    return `${check.title ?? check.id}: ${state}${check.dirty ? " · Review needed" : ""}${check.result?.status ? ` · ${check.result.status}` : ""} · Covers ${(check.covers ?? []).join(", ")}`;
  });
  const contention = (derived.contention ?? []).flatMap((item) => (item.unordered ?? []).map((pair) => `${item.resource}: ${pair[0]} <-> ${pair[1]}`));
  return {
    id: definition.id,
    kind: "tree",
    title: label(definition.title ?? report.title ?? tree.title),
    state: report.state,
    execution: report.execution_status,
    outcome: label(tree.goal ?? tree.title),
    acceptance: (tree.success ?? []).map(label),
    // Execution status colours the overview drawing; the delivery state is a badge.
    phase: report.execution_status ?? derived.status,
    entry: (derived.ready ?? []).join(" · "),
    evidence: [`${completed}/${nodes.length} Nodes completed · ${reviewNodes.size} awaiting review`],
    architecture: { summary: `${nodes.length} executable Nodes in ${(tree.tasks ?? []).length} Tasks`, notes: factLines(tree.architecture) },
    requirements: tree.requirements ?? [],
    fullRegression: { commands: [...new Set([...(tree.checks ?? []), ...checks].flatMap((check) => check.commands ?? []))], paths: [] },
    sharedRequirements: (tree.requirements ?? []).map(requirementLine),
    deliveryPolicy: factLines(tree.delivery_policy),
    checkSummary: checkLines(checks),
    decisions: (tree.open_decisions ?? []).map(decisionLine),
    unconfirmedTasks: Array.isArray(report.unconfirmed_tasks) ? report.unconfirmed_tasks : [],
    counts: derived.node_counts ?? {},

    tasks: (tree.tasks ?? []).map((task) => {
      const taskNodes = task.nodes ?? [];

      const detail = {
        title: task.title,
        description: task.outcome,
        sections: [
          { title: "Node execution status", items: [derived.task_status?.[task.id] ?? "pending"] },
          { title: "Draft pull request", items: task.draft_pr ? [task.draft_pr] : [] },
          { title: "Execution role", items: taskNodes.map((node) => `${node.id} · ${node.role}`) },
          { title: "Direct dependencies", items: [...new Set(taskNodes.flatMap(nodePrerequisites))] },
          { title: "Shared requirements", items: (task.requirements ?? []).map(requirementLine) },
          { title: "Checks", items: checkLines(checks.filter((check) => check.owner?.kind === "task" && check.owner.id === task.id)) },
        ],
      };
      return {
        code: task.id,
        title: task.title,
        outcome: task.outcome,
        detail,
        ...owns(task),
        nodes: taskNodes.map((node) => {
          const owned = owns(node);
          return {
            code: node.id,
            title: node.title,
            outcome: node.outcome,
            owner: node.role,
            // The Tree's own state, carried to the drawing rather than only into the
            // panel. Dropping it here is what left a 50-Node graph undifferentiated.
            status: node.status,
            needsReview: reviewNodes.has(node.id),
            prerequisites: nodePrerequisites(node),
            detail: {
              title: `${node.id} · ${node.title}`,
              description: node.outcome,
              sections: [
                { title: "Role", items: [node.role] },
                { title: "Execution state", items: [node.status] },
                { title: "Commit", items: node.commit ? [node.commit] : [] },
                { title: "Pending review", items: (node.review ?? []).map(requirementText) },
                { title: "Current result", items: node.result ? [typeof node.result === "string" ? node.result : node.result.summary ?? JSON.stringify(node.result)] : [] },
                { title: "Checks", items: checkLines(checks.filter((check) => (check.covers ?? []).includes(node.id))) },
                { title: "Resources contended", items: node.resources ?? [] },
                { title: "Direct dependencies", items: nodePrerequisites(node) },
                { title: "Work scope", items: owned.scope.in },
                { title: "Additional Node contract", items: owned.additionalContract },
                { title: "Design", items: Object.entries(owned.design).flatMap(([topic, items]) => items.map((item) => `${topic}: ${item}`)) },
                { title: "Files and directories written", items: owned.ownership.write_paths ?? [] },
                { title: "Deliverables", items: owned.outputs.map((output) => `${output.title} · ${output.artifact}: ${output.guarantee}`) },
                { title: "Acceptance and oracle", items: owned.acceptance.map(criterionLine) },
                { title: "Regression files and scope", items: owned.regression.paths },
                { title: "Verification commands", items: owned.regression.commands.map((command) => `$ ${command}`) },
                { title: "Parallel resources and exclusive ownership", items: owned.ownership.shared_exclusive ?? [] },
                { title: "Requirements covered", items: owned.requirements.map(requirementLine) },
                { title: "Out of scope", items: owned.scope.out },
              ],
            },
          };
        }),
      };
    }),
  };
}

function plannedMilestone(definition, report, payload) {
  const outline = payload.outline ?? {};
  const requirements = outline.requirements ?? definition.requirements ?? [];
  const decisions = outline.open_decisions ?? definition.open_decisions ?? [];
  return {
    id: definition.id,
    kind: "planned",
    title: label(definition.title ?? report.title),
    state: report.state ?? "planned",
    execution: report.execution_status ?? "planned",
    phase: report.execution_status ?? "planned",
    outcome: label(outline.goal ?? definition.goal),
    acceptance: (outline.success ?? definition.success ?? []).map(label),
    requirements: requirements.map((requirement) => ({
      code: requirement?.code,
      statement: label(requirement?.statement),
      sourceIds: requirementIds(requirement),
    })),
    decisions: decisions.map(decisionLine),
  };
}

function errorMilestone(definition, report, message) {
  return {
    id: definition.id,
    kind: "error",
    title: label(definition.title ?? report.title ?? definition.id),
    state: report.state ?? "error",
    execution: report.execution_status ?? "missing",
    phase: report.execution_status ?? "missing",
    outcome: null,
    error: message ?? report.error ?? "The export contains no projection for this delivery.",
    acceptance: [],
    decisions: [],
    requirements: [],
  };
}

const PREFIX_ORDER = ["AS", "OR", "MP", "CG", "AR", "EX", "UI", "LA", "PR", "DOC", "BUS", "QA"];
const prefixOf = (id) => {
  const index = id.indexOf("-");
  return (index > 0 ? id.slice(0, index) : id).toUpperCase();
};

function requirementCoverage(requirements) {
  const catalogue = (requirements?.catalogue ?? []).filter((item) => item && typeof item.id === "string");
  const coverage = requirements?.coverage ?? {};
  const ownerIndex = coverage.by_requirement ?? {};
  const uncoveredIds = Array.isArray(coverage.uncovered) ? coverage.uncovered : [];
  const excludedIds = new Set(Array.isArray(coverage.excluded) ? coverage.excluded : []);
  const unknown = (Array.isArray(coverage.unknown_refs) ? coverage.unknown_refs : []).map((ref) => ({
    delivery: ref?.delivery ?? "", task: ref?.task ?? "", ref: ref?.ref ?? "",
  }));
  const entryOf = (item) => ({
    id: item.id,
    title: label(item.title) ?? "",
    status: item.status ?? "",
    statement: label(item.statement) ?? "",
    // Catalogue acceptance may be one bilingual statement or a list of criteria.
    acceptance: (Array.isArray(item.acceptance) ? item.acceptance : item.acceptance == null ? [] : [item.acceptance])
      .map((criterion) => (typeof criterion === "object" && criterion !== null && ("en" in criterion || "zh" in criterion)
        ? label(criterion) ?? ""
        : criterionLine(criterion))),
    scopeNote: factLines(item.scope_note),
    exclusion: factLines(item.exclusion),
    owners: ownerIndex[item.id] ?? {},
  });

  const counts = new Map();
  const excluded = [];
  const uncovered = [];
  const inScope = [];
  const seen = new Set();
  for (const item of catalogue) {
    seen.add(item.id);
    counts.set(item.status ?? "unknown", (counts.get(item.status ?? "unknown") ?? 0) + 1);
    const entry = entryOf(item);
    if (excludedIds.has(item.id) || item.exclusion != null || item.status === "excluded") excluded.push(entry);
    else if (uncoveredIds.includes(item.id)) uncovered.push(entry);
    else inScope.push(entry);
  }
  // An uncovered or excluded id can be referenced without a catalogue entry; it
  // still belongs on the page instead of becoming an invisible gap.
  for (const id of uncoveredIds) if (!seen.has(id)) uncovered.push({ id, title: "", status: "", statement: "", acceptance: [], scopeNote: [], exclusion: [], owners: ownerIndex[id] ?? {} });
  for (const id of excludedIds) if (!seen.has(id)) excluded.push({ id, title: "", status: "", statement: "", acceptance: [], scopeNote: [], exclusion: [], owners: ownerIndex[id] ?? {} });

  const grouped = new Map();
  for (const entry of inScope) {
    const prefix = prefixOf(entry.id);
    if (!grouped.has(prefix)) grouped.set(prefix, []);
    grouped.get(prefix).push(entry);
  }
  const groups = [
    ...PREFIX_ORDER.filter((prefix) => grouped.has(prefix)).map((prefix) => ({ prefix, entries: grouped.get(prefix) })),
    ...[...grouped.keys()].filter((prefix) => !PREFIX_ORDER.includes(prefix)).map((prefix) => ({ prefix, entries: grouped.get(prefix) })),
  ];
  return { total: catalogue.length, counts: [...counts], groups, uncovered, excluded, unknown };
}

const metricEntries = (entries) => (Array.isArray(entries) ? entries : []).map((entry) => ({
  delivery: entry?.delivery, check: entry?.check, owner: entry?.owner, value: entry?.value, status: entry?.status,
}));

// Read Better Plan's projected programme only. The programme holds identity and
// order; the tool derives state for every delivery, including planned outlines
// and per-delivery export errors. No workspace discovery, lifecycle mutation,
// HTML parsing or per-delivery fallback.
export function loadBetterPlan(source) {
  const directory = path.dirname(path.resolve(source));
  const document = programmeExport(directory);
  const programme = document.programme ?? {};
  const report = document.report ?? {};
  const payloads = document.deliveries ?? {};
  const definitions = (programme.deliveries ?? []).filter((entry) => entry && typeof entry.id === "string");
  if (!definitions.length) return null;
  const reportIndex = new Map((report.deliveries ?? []).map((entry) => [entry.id, entry]));
  const deliveryIds = new Set(definitions.map((entry) => entry.id));
  const ready = new Set(report.ready ?? []);
  const readyToDesign = new Set(report.ready_to_design ?? []);

  const warnings = [];
  for (const definition of definitions) {
    for (const value of Array.isArray(definition.requires) ? definition.requires : []) {
      const id = typeof value === "string" ? value : value?.id;
      if (typeof id === "string" && !deliveryIds.has(id)) {
        warnings.push(`${definition.id} requires '${id}', which is not a delivery; the dependency edge is ignored.`);
      }
    }
  }
  for (const line of factLines(report.errors ?? [])) warnings.push(line);

  const milestones = definitions.map((definition) => {
    const reportEntry = reportIndex.get(definition.id) ?? {};
    const payload = payloads[definition.id];
    let milestone;
    if (payload?.kind === "tree" && payload.export) milestone = treeMilestone(definition, reportEntry, payload);
    else if (payload?.kind === "planned") milestone = plannedMilestone(definition, reportEntry, payload);
    else if (payload?.kind === "error") milestone = errorMilestone(definition, reportEntry, payload.error);
    else milestone = errorMilestone(definition, reportEntry, payload ? `The export used the unknown kind '${payload.kind}'.` : "The export contains no entry for this delivery.");
    milestone.requires = (Array.isArray(definition.requires) ? definition.requires : []).filter((id) => deliveryIds.has(id));
    milestone.blockedBy = (Array.isArray(reportEntry.blocked_by) ? reportEntry.blocked_by : []).filter((id) => typeof id === "string");
    milestone.readyToExecute = ready.has(definition.id);
    milestone.readyToDesign = readyToDesign.has(definition.id);
    return milestone;
  });

  return {
    summary: programme.title ? `Better Plan · ${label(programme.title)}` : "Better Plan · delivery programme",
    outcome: label(programme.goal),
    success: (programme.success ?? []).map(label),
    rules: [
      "One Checkpoints Tree per delivery; Programme.json holds order only and never status.",
      "Current state and pending review are supplied by the Better Plan tool; archives are not loaded.",
      "Execute one delivery at a time; a declared edge expresses a design prerequisite and the page schedules nothing.",
    ],
    warnings,
    decisions: milestones.flatMap((milestone) => milestone.decisions ?? []),
    requirements: requirementCoverage(document.requirements),
    metrics: Object.entries(document.metrics ?? {}).map(([name, entries]) => ({ name, entries: metricEntries(entries) })),
    milestones,
  };
}
