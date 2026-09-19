import path from "node:path";
import { fileURLToPath } from "node:url";

import { MigrationStateError } from "./errors.mjs";
import { isNonEmptyText, isPlainObject, readJsonArtifact, requireValue } from "./util.mjs";

export const FRONTIER_SCHEMA = "v0.0.1:client-state-migration-frontier-1";

// The embedded frontier is the admission's own definition. This tool never
// accepts an alternative: an operator-supplied frontier could authorize a step
// the running binary does not implement.
export const FRONTIER_REF = "crates/licoup-native/resources/client-state-migration-frontier.json";

export const REPO_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

const DOMAIN_ID_PATTERN = /^[a-z0-9-]+$/u;

/**
 * Validates the frontier as a document contract. Chain contiguity is
 * deliberately *not* checked here: the per-domain plan check reports a gap or
 * an ambiguous step as its own diagnosis, which is what an operator needs.
 */
export function loadEmbeddedFrontier() {
  const document = readJsonArtifact(path.join(REPO_ROOT, FRONTIER_REF));
  requireValue(document !== null, "migration_frontier_incomplete");
  return validateFrontier(document);
}

export function validateFrontier(document) {
  requireValue(
    isPlainObject(document) && document.schemaVersion === FRONTIER_SCHEMA,
    "migration_frontier_incomplete",
  );
  requireValue(isNonEmptyText(document.frontierId), "migration_frontier_incomplete");
  requireValue(
    Array.isArray(document.domains) && document.domains.length > 0,
    "migration_frontier_incomplete",
  );
  const domainIds = new Set();
  const stepIds = new Set();
  const domains = document.domains.map((domain) => {
    requireValue(
      isPlainObject(domain) &&
        isNonEmptyText(domain.domainId) &&
        DOMAIN_ID_PATTERN.test(domain.domainId) &&
        !domainIds.has(domain.domainId) &&
        (domain.durability === "durable" || domain.durability === "derived") &&
        Number.isInteger(domain.targetSchemaVersion) &&
        domain.targetSchemaVersion > 0 &&
        Array.isArray(domain.steps) &&
        domain.steps.length > 0,
      "migration_frontier_incomplete",
    );
    domainIds.add(domain.domainId);
    const sources = new Set();
    const steps = domain.steps.map((step) => {
      requireValue(
        isPlainObject(step) &&
          isNonEmptyText(step.stepId) &&
          !stepIds.has(step.stepId) &&
          Number.isInteger(step.fromSchemaVersion) &&
          step.fromSchemaVersion >= 0 &&
          Number.isInteger(step.toSchemaVersion) &&
          step.toSchemaVersion > step.fromSchemaVersion &&
          step.toSchemaVersion <= domain.targetSchemaVersion &&
          !sources.has(step.fromSchemaVersion),
        "migration_frontier_incomplete",
      );
      stepIds.add(step.stepId);
      sources.add(step.fromSchemaVersion);
      return Object.freeze({
        stepId: step.stepId,
        fromSchemaVersion: step.fromSchemaVersion,
        toSchemaVersion: step.toSchemaVersion,
      });
    });
    return Object.freeze({
      domainId: domain.domainId,
      durability: domain.durability,
      targetSchemaVersion: domain.targetSchemaVersion,
      steps: Object.freeze(steps),
    });
  });
  return Object.freeze({
    schemaVersion: document.schemaVersion,
    frontierId: document.frontierId,
    domains: Object.freeze(domains),
  });
}

export function findDomain(frontier, domainId) {
  return frontier.domains.find((domain) => domain.domainId === domainId) ?? null;
}

/**
 * Every step between the observed version and the domain target, in order.
 * A version with no step and a version with more than one step are both
 * ambiguous plans, and each gets its own stable code.
 */
export function planSteps(domain, fromSchemaVersion) {
  const steps = [];
  let cursor = fromSchemaVersion;
  while (cursor < domain.targetSchemaVersion) {
    const candidates = domain.steps.filter((step) => step.fromSchemaVersion === cursor);
    if (candidates.length === 0) return { steps: [], code: "migration_plan_gap" };
    if (candidates.length > 1) return { steps: [], code: "migration_plan_ambiguous" };
    const [step] = candidates;
    steps.push(step);
    cursor = step.toSchemaVersion;
  }
  return { steps, code: null };
}

/** The completed step ids the admission records for a given domain version. */
export function completedStepIdsFor(domain, schemaVersion) {
  return domain.steps
    .filter((step) => step.toSchemaVersion <= schemaVersion)
    .map((step) => step.stepId);
}

export function missingStepIdsFor(domain, schemaVersion) {
  return domain.steps
    .filter((step) => step.toSchemaVersion > schemaVersion)
    .map((step) => step.stepId);
}

export function requireDomain(frontier, domainId) {
  const domain = findDomain(frontier, domainId);
  if (domain === null) throw new MigrationStateError("repair_domain_unknown");
  return domain;
}
