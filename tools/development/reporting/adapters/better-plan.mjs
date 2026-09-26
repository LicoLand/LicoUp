import { readFileSync } from "node:fs";
import path from "node:path";

const read = (file) => JSON.parse(readFileSync(file, "utf8"));

// Read Better Plan's semantic files only. No workspace discovery, lifecycle
// commands, checkpoint mutations, HTML parsing or repository-specific plan format.
export function loadBetterPlan(source) {
  const document = read(source);
  const indexed = document.schema === "better-plan.manifest/v3";
  const plans = indexed
    ? document.plans.map((entry) => read(path.resolve(path.dirname(source), entry.plan)))
    : [document];
  if (plans.some((plan) => plan.schema !== "better-plan.plan/v3")) throw new Error("Expected current Better Plan Plan.json or Manifest.json");
  if (!plans.length) return null;
  const directories = new Map(plans.map((plan) => [plan.directory, plan.code]));
  const prerequisites = (plan) => {
    const declaration = (plan.spec.architecture?.notes ?? []).find((note) => note.startsWith("Milestone prerequisites: "));
    if (!declaration) return [];
    const names = declaration.slice("Milestone prerequisites: ".length).replace(/\.$/, "").split(",").map((name) => name.trim());
    if (names.length === 1 && names[0] === "none") return [];
    return names.flatMap((name) => {
      if (!directories.has(name)) {
        if (indexed) throw new Error("A declared milestone prerequisite is outside the selected workspace");
        // A single-Plan view retains external prerequisites in its architecture
        // notes without discovering or reading unselected sibling Plans.
        return [];
      }
      return [directories.get(name)];
    });
  };
  return {
    summary: "Better Plan · read-only projection of the selected plan source",
    rules: ["Execute one authorized milestone at a time; a declared edge expresses a design prerequisite and the page schedules nothing."],
    decisions: plans.flatMap((plan) => (plan.ledger?.unresolved ?? []).map((decision) => decision.statement)),
    milestones: plans.map((plan) => ({
      id: plan.code, title: plan.title, outcome: plan.intent.goal, acceptance: plan.intent.success,
      phase: plan.phase, entry: plan.intent.scope.in.join(" · "),
      evidence: (plan.ledger?.observed ?? []).map((entry) => `${entry.fact} (${entry.source})`).join("\n"),
      architecture: plan.spec.architecture,
      requirements: plan.spec.requirements,
      fullRegression: plan.spec.full_regression,
      decisions: plan.ledger?.unresolved ?? [],
      // Explicit architecture declarations are design constraints, not an added
      // execution field. Never infer them from Manifest order or arbitrary prose.
      requires: prerequisites(plan),
      tasks: plan.spec.tasks.map((task) => ({ code: task.code, title: task.title,
        outcome: task.outcome, scope: task.scope, design: task.design, ownership: task.ownership,
        acceptance: task.acceptance, outputs: task.outputs, requirements: task.requirements,
        regression: task.focused_regression, worker: task.worker, workload: task.workload,
        nodes: task.nodes.map((node) => ({ code: node.code,
          title: node.title, outcome: node.outcome, prerequisites: node.prerequisites })) })),
    })),
  };
}
