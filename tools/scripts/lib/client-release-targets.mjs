import { lstatSync, readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

export const CLIENT_RELEASE_TARGET_CATALOG_SCHEMA_VERSION =
  "licomesh.client-release-target-catalog.v4";
export const CLIENT_RELEASE_TARGET_CATALOG_PATH =
  "tools/client-release-targets.json";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const idPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;
const artifactPattern = /^[A-Za-z0-9][A-Za-z0-9._{}-]{0,159}$/u;
const outputLayoutPattern = /^build\/releases\/\{version\}\/\{targetId\}$/u;
const metadataPattern = /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/u;
const templatePathPattern = /^apps\/desktop\/[A-Za-z0-9._/-]+$/u;
const catalogKeys = Object.freeze(["schemaVersion", "outputLayout", "targets"]);
const targetKeys = Object.freeze([
  "id", "platform", "distributionFamily", "baseline", "channel",
  "packageFormat", "arch", "updateAuthority", "buildHost", "runtimeTargetId",
  "packageBuildSupported", "releaseSupported", "packageBlockers",
  "releaseBlockers", "artifacts", "update", "builder",
]);

function text(value) {
  return String(value || "").trim();
}

function stableStringList(values) {
  return [...new Set((Array.isArray(values) ? values : [])
    .map(text).filter(Boolean))].sort();
}

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function exactObjectKeys(value, keys) {
  return value && typeof value === "object" && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
}

function requireStringList(values, label) {
  requireValue(Array.isArray(values) && values.every((value) =>
    typeof value === "string" && value === value.trim() && value.length > 0) &&
    new Set(values).size === values.length,
  `${label} must be an exact string list`);
}

function validateArtifact(rawArtifact, targetId, seenRoles) {
  const artifact = rawArtifact && typeof rawArtifact === "object" &&
    !Array.isArray(rawArtifact) ? rawArtifact : {};
  const role = text(artifact.role);
  const file = text(artifact.file);
  requireValue(idPattern.test(role),
    `client release target ${targetId} has an invalid artifact role`);
  requireValue(artifactPattern.test(file) && path.basename(file) === file,
    `client release target ${targetId} has an invalid artifact file`);
  requireValue(!file.includes(".."),
    `client release target ${targetId} artifact escapes its package directory`);
  if (role !== "checksum") {
    requireValue(!seenRoles.has(role),
      `client release target ${targetId} has duplicate artifact role ${role}`);
    seenRoles.add(role);
  }
  const forRole = text(artifact.for);
  const source = text(artifact.source);
  if (role === "checksum") {
    requireValue(exactObjectKeys(artifact, ["role", "file", "for"]),
      `client release target ${targetId} checksum schema is not exact`);
    requireValue(forRole && seenRoles.has(forRole),
      `client release target ${targetId} checksum does not follow its artifact`);
  } else {
    requireValue(exactObjectKeys(artifact, ["role", "file", "source"]),
      `client release target ${targetId} artifact schema is not exact`);
    requireValue(!forRole,
      `client release target ${targetId} non-checksum artifact declares for`);
    requireValue(Boolean(source),
      `client release target ${targetId} artifact source is missing`);
  }
  if (source) {
    requireValue(source.startsWith("build/") && !source.includes("..") &&
      !path.isAbsolute(source),
    `client release target ${targetId} artifact source is not a build reference`);
  }
  return Object.freeze({
    role,
    file,
    ...(forRole ? { for: forRole } : {}),
    ...(source ? { source } : {}),
  });
}

function validateTarget(rawTarget, seenIds) {
  const target = rawTarget && typeof rawTarget === "object" &&
    !Array.isArray(rawTarget) ? rawTarget : {};
  const id = text(target.id);
  requireValue(idPattern.test(id), "client release target id is invalid");
  requireValue(exactObjectKeys(target, targetKeys),
    `client release target ${id} schema is not exact`);
  requireValue(!seenIds.has(id), `duplicate client release target: ${id}`);
  seenIds.add(id);

  const normalized = {};
  for (const field of [
    "platform", "distributionFamily", "baseline", "channel", "packageFormat",
    "arch", "updateAuthority", "buildHost", "runtimeTargetId",
  ]) {
    normalized[field] = text(target[field]);
    requireValue(normalized[field],
      `client release target ${id} is missing ${field}`);
  }
  requireValue(metadataPattern.test(normalized.platform) &&
    metadataPattern.test(normalized.distributionFamily) &&
    metadataPattern.test(normalized.baseline) &&
    metadataPattern.test(normalized.channel) &&
    metadataPattern.test(normalized.packageFormat) &&
    metadataPattern.test(normalized.arch) &&
    metadataPattern.test(normalized.updateAuthority) &&
    metadataPattern.test(normalized.buildHost) &&
    metadataPattern.test(normalized.runtimeTargetId),
  `client release target ${id} contains invalid target metadata`);
  requireValue(typeof target.packageBuildSupported === "boolean",
    `client release target ${id} must declare packageBuildSupported`);
  requireValue(typeof target.releaseSupported === "boolean",
    `client release target ${id} must declare releaseSupported`);

  requireStringList(target.packageBlockers,
    `client release target ${id} packageBlockers`);
  requireStringList(target.releaseBlockers,
    `client release target ${id} releaseBlockers`);
  const packageBlockers = stableStringList(target.packageBlockers);
  const releaseBlockers = stableStringList(target.releaseBlockers);
  const builderKind = text(target.builder?.kind);
  requireStringList(target.builder?.hosts,
    `client release target ${id} builder.hosts`);
  requireStringList(target.builder?.templates,
    `client release target ${id} builder.templates`);
  const hosts = stableStringList(target.builder?.hosts);
  const ciRunner = stableStringList(target.builder?.ciRunner);
  const templates = stableStringList(target.builder?.templates);
  requireValue(["command", "unavailable"].includes(builderKind) && hosts.length > 0,
    `client release target ${id} has an invalid builder`);
  requireValue(hosts.includes(normalized.buildHost),
    `client release target ${id} builder does not include its owning host`);
  requireValue(Array.isArray(target.builder?.templates),
    `client release target ${id} must declare builder.templates`);
  requireValue(templates.every((template) => templatePathPattern.test(template) &&
    !template.includes("..") && !path.isAbsolute(template)),
  `client release target ${id} has invalid builder templates`);
  if (target.packageBuildSupported) {
    requireValue(exactObjectKeys(target.builder,
      ["kind", "hosts", "ciRunner", "program", "args", "templates"]),
    `build-supported client package target ${id} builder schema is not exact`);
    requireStringList(target.builder.ciRunner,
      `client release target ${id} builder.ciRunner`);
    requireValue(builderKind === "command" && packageBlockers.length === 0,
      `build-supported client package target ${id} has no exact command`);
    requireValue(typeof target.builder?.program === "string" &&
      target.builder.program === text(target.builder.program) &&
      text(target.builder.program) &&
      Array.isArray(target.builder?.args) &&
      target.builder.args.every((entry) => typeof entry === "string" &&
        entry === text(entry) && entry.length > 0) && ciRunner.length > 0,
    `build-supported client package target ${id} has an invalid command`);
  } else {
    requireValue(exactObjectKeys(target.builder, ["kind", "hosts", "templates"]),
      `build-unsupported client package target ${id} builder schema is not exact`);
    requireValue(builderKind === "unavailable" && packageBlockers.length > 0 &&
      templates.length > 0 && templates.every((template) =>
        template.startsWith("apps/desktop/") && !template.includes("..") &&
        !path.isAbsolute(template)),
      `build-unsupported client package target ${id} must be blocked`);
  }
  if (target.releaseSupported) {
    requireValue(target.packageBuildSupported && releaseBlockers.length === 0,
      `release-supported client package target ${id} lacks package closure`);
  } else {
    requireValue(releaseBlockers.length > 0,
      `release-unsupported client package target ${id} must be blocked`);
  }

  requireValue(Array.isArray(target.artifacts) && target.artifacts.length > 0,
    `client release target ${id} has no artifacts`);
  const seenRoles = new Set();
  const seenFiles = new Set();
  const artifacts = target.artifacts.map((artifact) =>
    validateArtifact(artifact, id, seenRoles));
  for (const artifact of artifacts) {
    requireValue(!seenFiles.has(artifact.file),
      `client release target ${id} has duplicate artifact file ${artifact.file}`);
    seenFiles.add(artifact.file);
  }
  requireValue(seenRoles.has("installer") || seenRoles.has("submission"),
    `client release target ${id} has no installer or submission artifact`);
  requireValue(seenRoles.has("build-manifest"),
    `client release target ${id} has no build manifest artifact`);

  const updateKind = text(target.update?.kind);
  const updateArtifactRole = text(target.update?.artifactRole);
  requireValue(exactObjectKeys(target.update,
    updateArtifactRole ? ["kind", "artifactRole"] : ["kind"]),
  `client release target ${id} update schema is not exact`);
  requireValue(updateKind,
    `client release target ${id} must declare an update kind`);
  if (updateArtifactRole) {
    requireValue(seenRoles.has(updateArtifactRole),
      `client release target ${id} update artifact role is missing`);
  }

  return Object.freeze({
    id,
    ...normalized,
    packageBuildSupported: target.packageBuildSupported === true,
    releaseSupported: target.releaseSupported === true,
    packageBlockers: Object.freeze(packageBlockers),
    releaseBlockers: Object.freeze(releaseBlockers),
    artifacts: Object.freeze(artifacts),
    update: Object.freeze({
      kind: updateKind,
      ...(updateArtifactRole ? { artifactRole: updateArtifactRole } : {}),
    }),
    builder: Object.freeze({
      kind: builderKind,
      hosts: Object.freeze(hosts),
      templates: Object.freeze(templates),
      ...(builderKind === "command" ? {
        program: text(target.builder.program),
        args: Object.freeze(target.builder.args.map(text)),
        ciRunner: Object.freeze(ciRunner),
      } : {}),
    }),
  });
}

export function validateClientReleaseTargetCatalog(rawCatalog = {}) {
  requireValue(exactObjectKeys(rawCatalog, catalogKeys),
    "client release target catalog schema is not exact");
  requireValue(
    rawCatalog?.schemaVersion === CLIENT_RELEASE_TARGET_CATALOG_SCHEMA_VERSION,
    `unexpected client release target catalog schema: ${text(rawCatalog?.schemaVersion)}`,
  );
  requireValue(outputLayoutPattern.test(text(rawCatalog.outputLayout)),
    "client release output layout is not canonical");
  requireValue(Array.isArray(rawCatalog.targets) && rawCatalog.targets.length > 0,
    "client release target catalog is empty");
  const seenIds = new Set();
  const targets = rawCatalog.targets.map((target) => validateTarget(target, seenIds));
  requireValue(targets.some((target) => target.platform === "macos") &&
    targets.some((target) => target.platform === "windows") &&
    targets.some((target) => target.platform === "linux") &&
    targets.some((target) => target.platform === "android") &&
    targets.some((target) => target.platform === "ios"),
  "client release target catalog must cover every product platform");
  requireValue(!targets.some((target) => target.packageFormat === "tar" ||
    target.packageFormat === "tar.gz"),
  "generic archives are not installable release packages");
  return Object.freeze({
    schemaVersion: CLIENT_RELEASE_TARGET_CATALOG_SCHEMA_VERSION,
    outputLayout: text(rawCatalog.outputLayout),
    targets: Object.freeze(targets),
  });
}

export function loadClientReleaseTargetCatalog(
  catalogPath = path.join(repoRoot, CLIENT_RELEASE_TARGET_CATALOG_PATH),
) {
  const catalog = validateClientReleaseTargetCatalog(
    JSON.parse(readFileSync(catalogPath, "utf8")),
  );
  for (const target of catalog.targets) {
    if (target.builder.kind === "command" && target.builder.program === "node") {
      const script = target.builder.args[0];
      const info = lstatSync(path.join(repoRoot, script), { throwIfNoEntry: false });
      requireValue(info?.isFile() && !info.isSymbolicLink(),
        `client release target ${target.id} builder is missing: ${script}`);
    }
    for (const template of target.builder.templates || []) {
      const info = lstatSync(path.join(repoRoot, template), { throwIfNoEntry: false });
      requireValue(info?.isFile() && !info.isSymbolicLink(),
        `client release target ${target.id} template is missing: ${template}`);
    }
  }
  return catalog;
}

export function clientReleaseTargets(catalog, {
  includeBuildUnsupported = true,
  includeReleaseUnsupported = true,
} = {}) {
  const validated = validateClientReleaseTargetCatalog(catalog);
  return validated.targets.filter((target) =>
    (includeBuildUnsupported || target.packageBuildSupported) &&
    (includeReleaseUnsupported || target.releaseSupported));
}

function normalizedTargetIds(values) {
  const ids = values.flatMap((value) => String(value).split(","));
  requireValue(ids.length > 0 && ids.every((id) => id === id.trim() && idPattern.test(id)),
    "client release target selection contains an invalid token");
  requireValue(new Set(ids).size === ids.length,
    "client release target selection contains duplicates");
  return ids;
}

export function parseClientReleaseTargetArgs(
  argv = process.argv.slice(2),
  { environment = process.env, allowAll = true } = {},
) {
  const values = [];
  const remaining = [];
  let all = false;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if ((arg === "--target" || arg === "--targets") && argv[index + 1]) {
      values.push(argv[index + 1]);
      index += 1;
    } else if (arg === "--all" && allowAll) {
      all = true;
    } else {
      remaining.push(arg);
    }
  }
  requireValue(!(all && values.length > 0),
    "client release target selection cannot combine --all with explicit targets");
  const environmentSelection = text(environment.LICO_CLIENT_RELEASE_TARGETS);
  requireValue(!(environmentSelection && (all || values.length > 0)),
    "client release target selection has multiple authorities");
  return Object.freeze({
    all,
    targetIds: Object.freeze(all ? [] : normalizedTargetIds(
      values.length > 0 ? values : environmentSelection ? [environmentSelection] : [],
    )),
    remaining: Object.freeze(remaining),
  });
}

export function selectClientReleaseTargets(catalog, selectedTargetIds = [], {
  requireBuildSupported = false,
  requireReleaseSupported = true,
} = {}) {
  const validated = validateClientReleaseTargetCatalog(catalog);
  const normalizedIds = normalizedTargetIds(selectedTargetIds);
  const byId = new Map(validated.targets.map((target) => [target.id, target]));
  const unknownIds = normalizedIds.filter((id) => !byId.has(id));
  requireValue(unknownIds.length === 0,
    `client release contains unknown package targets: ${unknownIds.join(", ")}`);
  const selected = normalizedIds.map((id) => byId.get(id));
  if (requireBuildSupported) {
    const unsupported = selected.filter((target) => !target.packageBuildSupported);
    requireValue(unsupported.length === 0,
      `client package build is blocked: ${unsupported.map((target) =>
        `${target.id} (${target.packageBlockers.join(",")})`).join("; ")}`);
  }
  if (requireReleaseSupported) {
    const unsupported = selected.filter((target) => !target.releaseSupported);
    requireValue(unsupported.length === 0,
      `client release contains targets outside closure authority: ${unsupported
        .map((target) => `${target.id} (${target.releaseBlockers.join(",")})`)
        .join("; ")}`);
  }
  return Object.freeze(selected);
}

export function resolveClientReleaseTarget(target, productVersion) {
  requireValue(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(text(productVersion)),
    "client release product version is invalid");
  const replacements = Object.freeze({
    "{version}": text(productVersion),
    "{targetId}": target.id,
  });
  const resolveTemplate = (value) => Object.entries(replacements)
    .reduce((resolved, [token, replacement]) => resolved.replaceAll(token, replacement), value);
  return Object.freeze({
    ...target,
    outputRef: resolveTemplate(`build/releases/{version}/{targetId}`),
    artifacts: Object.freeze(target.artifacts.map((artifact) => Object.freeze({
      ...artifact,
      file: resolveTemplate(artifact.file),
      ...(artifact.source ? { source: resolveTemplate(artifact.source) } : {}),
    }))),
  });
}

function artifactByTarget(selectedTargets, artifacts) {
  requireValue(Array.isArray(artifacts), "GitHub Release artifacts must be an array");
  const selectedIds = new Set(selectedTargets.map((target) => target.id));
  const byTarget = new Map();
  for (const artifact of artifacts) {
    const targetId = text(artifact?.targetId);
    requireValue(targetId && !byTarget.has(targetId) && selectedIds.has(targetId),
      `GitHub Release contains an invalid artifact target: ${targetId}`);
    const target = selectedTargets.find((candidate) => candidate.id === targetId);
    requireValue(
      text(artifact.platform) === target.platform &&
      text(artifact.channel) === target.channel &&
      text(artifact.packageFormat) === target.packageFormat &&
      text(artifact.arch) === target.arch,
      `GitHub Release artifact metadata does not match target: ${targetId}`,
    );
    requireValue(/^sha256:[0-9a-f]{64}$/u.test(text(artifact.sha256)),
      `GitHub Release artifact digest is missing or invalid: ${targetId}`);
    byTarget.set(targetId, artifact);
  }
  const missing = selectedTargets.filter((target) => !byTarget.has(target.id));
  requireValue(missing.length === 0,
    `GitHub Release is missing artifacts: ${missing.map((target) => target.id).join(", ")}`);
  return byTarget;
}

export function createClientGitHubReleaseClosure({
  catalog,
  selectedTargetIds = [],
  artifacts = [],
  targetReadiness = [],
  githubReleaseReducer,
} = {}) {
  requireValue(typeof githubReleaseReducer === "function",
    "canonical GitHub Release reducer is required");
  const validated = validateClientReleaseTargetCatalog(catalog);
  const selectedTargets = selectClientReleaseTargets(validated, selectedTargetIds);
  const artifactsByTarget = artifactByTarget(selectedTargets, artifacts);
  requireValue(Array.isArray(targetReadiness),
    "GitHub Release target readiness must be an array");
  const readinessByTarget = new Map();
  const knownTargetIds = new Set(validated.targets.map((target) => target.id));
  for (const readiness of targetReadiness) {
    const targetId = text(readiness?.targetId);
    requireValue(targetId && knownTargetIds.has(targetId) &&
      !readinessByTarget.has(targetId),
    `GitHub Release contains invalid target readiness: ${targetId}`);
    readinessByTarget.set(targetId, readiness);
  }
  const selectedIds = new Set(selectedTargets.map((target) => target.id));
  const githubReleaseReadiness = validated.targets.map((target) => {
    const readiness = readinessByTarget.get(target.id);
    const selected = selectedIds.has(target.id);
    const blockers = selected
      ? stableStringList(readiness?.blockers)
      : target.releaseSupported
        ? stableStringList(readiness?.blockers)
        : [...target.releaseBlockers];
    if (selected && readiness?.githubReleaseReady !== true && blockers.length === 0) {
      blockers.push("github_release_evidence_not_ready");
    }
    const githubReleaseReady = target.releaseSupported &&
      readiness?.githubReleaseReady === true && blockers.length === 0;
    const artifact = artifactsByTarget.get(target.id);
    return {
      targetId: target.id,
      platform: target.platform,
      osFamily: target.distributionFamily,
      channel: target.channel,
      packageFormat: target.packageFormat,
      arch: target.arch,
      selected,
      status: !target.packageBuildSupported ? "unsupported"
        : githubReleaseReady ? "ready"
          : target.releaseSupported ? "unverified" : "blocked",
      githubReleaseReady,
      blockers,
      ...(selected ? {
        evidenceRefs: stableStringList(readiness?.evidenceRefs),
        artifactDigest: text(artifact?.sha256),
      } : {}),
    };
  });
  const selectedReadiness = githubReleaseReadiness.filter((entry) => entry.selected);
  const canonicalClosure = githubReleaseReducer({
    selectedTargetIds: selectedTargets.map((target) => target.id),
    targetReadiness: selectedReadiness,
    artifacts: selectedTargets.map((target) => ({
      targetId: target.id,
      artifactDigest: text(artifactsByTarget.get(target.id)?.sha256),
    })),
    knownTargetIds: validated.targets.map((target) => target.id),
  });
  return {
    ...canonicalClosure,
    githubReleaseReadiness,
    projectionOnly: true,
    notProductionReadinessInput: true,
    productionReady: false,
    productionReleaseReady: false,
  };
}
