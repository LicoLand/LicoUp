import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const CLIENT_RELEASE_TARGET_CATALOG_SCHEMA_VERSION =
  "licolite.client-release-target-catalog.v2";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
export const CLIENT_RELEASE_TARGET_CATALOG_PATH = "tools/client-release-targets.json";

function text(value) {
  return String(value || "").trim();
}

function stableStringList(values) {
  return [...new Set((Array.isArray(values) ? values : []).map(text).filter(Boolean))].sort();
}

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function validateTarget(rawTarget, seenIds) {
  const target = rawTarget && typeof rawTarget === "object" && !Array.isArray(rawTarget)
    ? rawTarget
    : {};
  const id = text(target.id);
  requireValue(id, "client release target id is required");
  requireValue(!seenIds.has(id), `duplicate client release target: ${id}`);
  seenIds.add(id);
  for (const field of ["platform", "osFamily", "arch", "installerStrategy"]) {
    requireValue(text(target[field]), `client release target ${id} is missing ${field}`);
  }
  requireValue(typeof target.supported === "boolean", `client release target ${id} must declare supported`);
  requireValue(typeof target.releaseSupported === "boolean",
    `client release target ${id} must declare releaseSupported`);
  const builderKind = text(target.builder?.kind);
  requireValue(builderKind, `client release target ${id} is missing builder.kind`);
  const blockers = stableStringList(target.blockers);
  const releaseBlockers = stableStringList(target.releaseBlockers);
  if (target.supported) {
    requireValue(builderKind !== "unavailable", `supported client release target ${id} has no builder`);
    requireValue(blockers.length === 0, `supported client release target ${id} must not declare blockers`);
  } else {
    requireValue(builderKind === "unavailable", `unsupported client release target ${id} must use unavailable builder`);
    requireValue(blockers.length > 0, `unsupported client release target ${id} must declare blockers`);
  }
  if (target.releaseSupported) {
    requireValue(target.supported === true,
      `release-supported client target ${id} is not build-supported`);
    requireValue(releaseBlockers.length === 0,
      `release-supported client target ${id} must not declare release blockers`);
  } else {
    requireValue(releaseBlockers.length > 0,
      `release-unsupported client target ${id} must declare release blockers`);
  }
  return Object.freeze({
    ...target,
    id,
    platform: text(target.platform),
    osFamily: text(target.osFamily),
    arch: text(target.arch),
    installerStrategy: text(target.installerStrategy),
    supported: target.supported === true,
    releaseSupported: target.releaseSupported === true,
    builder: Object.freeze({ ...target.builder, kind: builderKind }),
    blockers: Object.freeze(blockers),
    releaseBlockers: Object.freeze(releaseBlockers)
  });
}

export function validateClientReleaseTargetCatalog(rawCatalog = {}) {
  requireValue(
    rawCatalog?.schemaVersion === CLIENT_RELEASE_TARGET_CATALOG_SCHEMA_VERSION,
    `unexpected client release target catalog schema: ${text(rawCatalog?.schemaVersion)}`
  );
  requireValue(Array.isArray(rawCatalog.targets) && rawCatalog.targets.length > 0, "client release target catalog is empty");
  const seenIds = new Set();
  const targets = rawCatalog.targets.map((target) => validateTarget(target, seenIds));
  const iosTarget = targets.find((target) => target.id === "ios-arm64");
  requireValue(iosTarget, "client release target catalog must explicitly declare ios-arm64");
  return Object.freeze({
    schemaVersion: CLIENT_RELEASE_TARGET_CATALOG_SCHEMA_VERSION,
    targets: Object.freeze(targets)
  });
}

export function loadClientReleaseTargetCatalog(catalogPath = path.join(repoRoot, CLIENT_RELEASE_TARGET_CATALOG_PATH)) {
  return validateClientReleaseTargetCatalog(JSON.parse(readFileSync(catalogPath, "utf8")));
}

export function clientReleaseTargets(catalog, {
  includeUnsupported = true,
  includeReleaseUnsupported = true,
} = {}) {
  const validated = validateClientReleaseTargetCatalog(catalog);
  return validated.targets.filter((target) =>
    (includeUnsupported || target.supported) &&
    (includeReleaseUnsupported || target.releaseSupported));
}

export function selectClientReleaseTargets(catalog, selectedTargetIds = []) {
  const validated = validateClientReleaseTargetCatalog(catalog);
  requireValue(Array.isArray(selectedTargetIds) && selectedTargetIds.length > 0, "GitHub Release target selection is empty");
  const normalizedIds = selectedTargetIds.map(text);
  requireValue(normalizedIds.every(Boolean), "GitHub Release target id is empty");
  requireValue(new Set(normalizedIds).size === normalizedIds.length, "GitHub Release target selection contains duplicates");
  const selectedIds = new Set(normalizedIds);
  const knownIds = new Set(validated.targets.map((target) => target.id));
  const unknownIds = normalizedIds.filter((id) => !knownIds.has(id));
  requireValue(unknownIds.length === 0, `GitHub Release contains unknown targets: ${unknownIds.join(", ")}`);
  const selected = validated.targets.filter((target) => selectedIds.has(target.id));
  const unsupported = selected.filter((target) => !target.releaseSupported);
  requireValue(
    unsupported.length === 0,
    `GitHub Release contains targets outside its closure authority: ${unsupported.map((target) => `${target.id} (${target.releaseBlockers.join(",")})`).join("; ")}`
  );
  return selected;
}

function artifactByTarget(selectedTargets, artifacts) {
  requireValue(Array.isArray(artifacts), "GitHub Release artifacts must be an array");
  const selectedIds = new Set(selectedTargets.map((target) => target.id));
  const byTarget = new Map();
  for (const artifact of artifacts) {
    const targetId = text(artifact?.targetId);
    requireValue(targetId, "GitHub Release artifact targetId is required");
    requireValue(!byTarget.has(targetId), `GitHub Release contains duplicate artifact target: ${targetId}`);
    requireValue(selectedIds.has(targetId), `GitHub Release contains artifact outside selected targets: ${targetId}`);
    const target = selectedTargets.find((candidate) => candidate.id === targetId);
    requireValue(
      text(artifact.platform) === target.platform &&
        text(artifact.osFamily) === target.osFamily &&
        text(artifact.arch) === target.arch,
      `GitHub Release artifact metadata does not match target: ${targetId}`
    );
    requireValue(
      /^sha256:[0-9a-f]{64}$/u.test(text(artifact.sha256)),
      `GitHub Release artifact digest is missing or invalid: ${targetId}`
    );
    byTarget.set(targetId, artifact);
  }
  const missing = selectedTargets.filter((target) => !byTarget.has(target.id));
  requireValue(missing.length === 0, `GitHub Release is missing artifacts: ${missing.map((target) => target.id).join(", ")}`);
  return byTarget;
}

export function createClientGitHubReleaseClosure({
  catalog,
  selectedTargetIds = [],
  artifacts = [],
  targetReadiness = [],
  githubReleaseReducer
} = {}) {
  requireValue(typeof githubReleaseReducer === "function", "canonical GitHub Release reducer is required");
  const validated = validateClientReleaseTargetCatalog(catalog);
  const selectedTargets = selectClientReleaseTargets(validated, selectedTargetIds);
  const artifactsByTarget = artifactByTarget(selectedTargets, artifacts);
  requireValue(Array.isArray(targetReadiness), "GitHub Release target readiness must be an array");
  const readinessByTarget = new Map();
  const knownTargetIds = new Set(validated.targets.map((target) => target.id));
  for (const readiness of targetReadiness) {
    const targetId = text(readiness?.targetId);
    requireValue(targetId, "GitHub Release readiness targetId is required");
    requireValue(knownTargetIds.has(targetId), `GitHub Release readiness contains unknown target: ${targetId}`);
    requireValue(!readinessByTarget.has(targetId), `GitHub Release contains duplicate target readiness: ${targetId}`);
    readinessByTarget.set(targetId, readiness);
  }
  const selectedIds = new Set(selectedTargets.map((target) => target.id));
  const githubReleaseReadiness = validated.targets.map((target) => {
    if (!selectedIds.has(target.id)) {
      const readiness = readinessByTarget.get(target.id);
      const blockers = target.releaseSupported
        ? stableStringList(readiness?.blockers)
        : [...target.releaseBlockers];
      const githubReleaseReady = target.releaseSupported &&
        readiness?.githubReleaseReady === true && blockers.length === 0;
      return {
        targetId: target.id,
        platform: target.platform,
        osFamily: target.osFamily,
        arch: target.arch,
        selected: false,
        status: !target.releaseSupported
          ? (target.supported ? "blocked" : "unsupported")
          : readiness
            ? (githubReleaseReady ? "ready" : "blocked")
            : "unverified",
        githubReleaseReady,
        blockers
      };
    }
    const readiness = readinessByTarget.get(target.id) || {};
    const blockers = stableStringList(readiness.blockers);
    if (readiness.githubReleaseReady !== true && blockers.length === 0) {
      blockers.push("github_release_evidence_not_ready");
    }
    const githubReleaseReady = readiness.githubReleaseReady === true && blockers.length === 0;
    const artifact = artifactsByTarget.get(target.id);
    return {
      targetId: target.id,
      platform: target.platform,
      osFamily: target.osFamily,
      arch: target.arch,
      selected: true,
      status: githubReleaseReady ? "ready" : "blocked",
      githubReleaseReady,
      blockers,
      evidenceRefs: stableStringList(readiness.evidenceRefs),
      artifactDigest: text(artifact.sha256)
    };
  });
  const selectedReadiness = githubReleaseReadiness.filter((entry) => entry.selected);
  const canonicalClosure = githubReleaseReducer({
    selectedTargetIds: selectedTargets.map((target) => target.id),
    targetReadiness: selectedReadiness,
    artifacts: selectedTargets.map((target) => ({
      targetId: target.id,
      artifactDigest: text(artifactsByTarget.get(target.id)?.sha256)
    })),
    knownTargetIds: validated.targets.map((target) => target.id)
  });
  return {
    ...canonicalClosure,
    githubReleaseReadiness,
    projectionOnly: true,
    notProductionReadinessInput: true,
    productionReady: false,
    productionReleaseReady: false
  };
}
