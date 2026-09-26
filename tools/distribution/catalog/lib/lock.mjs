import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import { assertRepoRelativePath, digestOf, GraphError, requireFact } from "../../../architecture-graph/lib/canonical.mjs";

/**
 * The install lock (C12/C08 deployment side) and the byte-attribution entry.
 *
 * A lock records, for each distribution profile, the exact installed set: the
 * package ids and versions, the artifact paths, and the bytes and sha256 values
 * **computed from the files on disk**. Nothing here is estimated: a build result
 * may declare a size or a digest, and the declared value is checked against the
 * real bytes and refused when it differs. A tool that copies an asserted digest
 * into a lock would launder exactly the claim it is supposed to verify.
 *
 * The lock is deterministic: the same graph and the same build result produce
 * byte-identical output, and `lock_digest` covers every field except itself.
 *
 * This module never installs, downloads, executes or removes anything. It reads
 * graph declarations and local build output only.
 */

export const BUILD_SCHEMA = "licoup.distribution-build.v1";
export const LOCK_SCHEMA = "licoup.distribution-lock.v1";
export const LOCK_VERIFICATION_SCHEMA = "licoup.distribution-lock-verification.v1";
export const ATTRIBUTION_SCHEMA = "licoup.distribution-byte-attribution.v1";

const SEMVER_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$/u;
const SHA256_PATTERN = /^[0-9a-f]{64}$/u;
const ARTIFACT_FIELDS = new Set(["path", "bytes", "sha256"]);
const BUILD_PACKAGE_FIELDS = new Set(["id", "version", "root", "artifacts"]);

/** A repository-relative *file* path: normalized, no trailing separator, no glob. */
function requireArtifactPath(value, label) {
  assertRepoRelativePath(value, label);
  requireFact(!value.endsWith("/") && !value.endsWith("/**"), `${label} must name a file: ${value}`);
  return value;
}

function rootDirectoryFacts(absolutePath) {
  try {
    return fs.lstatSync(absolutePath);
  } catch {
    return null;
  }
}

/** Two package roots may not share bytes: no two roots overlap on the same path. */
function requireDisjointRoots(roots) {
  const sorted = [...roots].sort();
  for (let i = 1; i < sorted.length; i += 1) {
    const previous = sorted[i - 1];
    const current = sorted[i];
    requireFact(
      current !== previous && !current.startsWith(`${previous}/`),
      `package artifact roots overlap: ${previous} and ${current}`,
    );
  }
}

/**
 * The tasks that carry delivery responsibility for one package: the tasks the
 * package names as its implementation and the tasks that declare the package.
 * Responsibility is a delivery fact and never a development prerequisite.
 */
export function deliveryTasksForPackage(graph, packageId) {
  const pkg = graph.packages.get(packageId);
  requireFact(pkg !== undefined, `unknown package: ${packageId}`);
  const declared = [...pkg.implementation_tasks].filter((taskId) =>
    (graph.tasks.get(taskId).packages ?? []).includes(packageId));
  const owners = [...graph.tasks.values()]
    .filter((task) => (task.packages ?? []).includes(packageId))
    .map((task) => task.id);
  return [...new Set([...declared, ...owners])].sort();
}

export async function fileFacts(absolutePath, label) {
  let stats;
  try {
    // lstat on purpose: a symlinked artifact is refused rather than followed,
    // so a link cannot attribute bytes outside its own package root.
    stats = fs.lstatSync(absolutePath);
  } catch {
    throw new GraphError(`${label} is missing under the artifacts root`);
  }
  requireFact(stats.isFile(), `${label} is not a regular file`);
  const hash = createHash("sha256");
  let bytes = 0;
  await new Promise((resolve, reject) => {
    const stream = fs.createReadStream(absolutePath);
    stream.on("data", (chunk) => {
      bytes += chunk.length;
      hash.update(chunk);
    });
    stream.on("error", reject);
    stream.on("end", resolve);
  });
  return { bytes, sha256: hash.digest("hex") };
}

function compareArtifactFact(actual, artifact, packageId) {
  if (artifact.bytes !== undefined) {
    requireFact(Number.isInteger(artifact.bytes) && artifact.bytes >= 0,
      `build result declares an invalid byte count for ${packageId} / ${artifact.path}`);
    requireFact(artifact.bytes === actual.bytes,
      `build result declares ${artifact.bytes} bytes for ${packageId} / ${artifact.path} but the file is ${actual.bytes} bytes`);
  }
  if (artifact.sha256 !== undefined) {
    requireFact(typeof artifact.sha256 === "string" && SHA256_PATTERN.test(artifact.sha256),
      `build result declares an invalid sha256 for ${packageId} / ${artifact.path}`);
    requireFact(artifact.sha256 === actual.sha256,
      `build result declares a sha256 for ${packageId} / ${artifact.path} that does not match the file`);
  }
}

/**
 * Build the lock from a real local build result.
 *
 * `build` names, per package, the artifact files a build produced (paths
 * relative to the package root). Byte counts and digests are read from those
 * files; a declared value that does not match the bytes refuses the lock.
 */
export async function buildInstallLock({ graph, build, artifactsRoot }) {
  requireFact(typeof artifactsRoot === "string" && artifactsRoot.length > 0,
    "an artifacts root directory is required");
  requireFact(build !== null && typeof build === "object" && !Array.isArray(build),
    "a build result object is required");
  requireFact(build.schema === BUILD_SCHEMA,
    `build result schema must be ${BUILD_SCHEMA}`);
  requireFact(build.graph_digest === graph.graphDigest,
    `build result was produced from graph ${String(build.graph_digest)} but the current graph digest is ${graph.graphDigest}`);
  requireFact(typeof build.source_revision === "string" && build.source_revision.length > 0,
    "build result must name the source revision it was produced from");
  requireFact(Array.isArray(build.packages) && build.packages.length > 0,
    "build result declares no packages");

  const seenPackages = new Set();
  const seenArtifacts = new Set();
  const resolved = [];
  for (const entry of build.packages) {
    requireFact(entry !== null && typeof entry === "object" && !Array.isArray(entry),
      "each build package must be an object");
    for (const key of Object.keys(entry)) {
      requireFact(BUILD_PACKAGE_FIELDS.has(key), `build package has an unknown field: ${key}`);
    }
    requireFact(typeof entry.id === "string" && graph.packages.has(entry.id),
      `build result names a package outside the distribution graph: ${String(entry.id)}`);
    requireFact(!seenPackages.has(entry.id), `build result repeats a package: ${entry.id}`);
    seenPackages.add(entry.id);
    requireFact(typeof entry.version === "string" && SEMVER_PATTERN.test(entry.version),
      `build package ${entry.id} needs a semver version`);
    const root = requireArtifactPath(entry.root, `build root of ${entry.id}`);
    const rootFacts = rootDirectoryFacts(path.resolve(artifactsRoot, root));
    requireFact(rootFacts !== null && rootFacts.isDirectory(),
      `build root of ${entry.id} is not a real directory: ${root}`);
    requireFact(Array.isArray(entry.artifacts) && entry.artifacts.length > 0,
      `built package ${entry.id} declares no artifact`);
    const artifacts = [];
    for (const artifact of entry.artifacts) {
      requireFact(artifact !== null && typeof artifact === "object" && !Array.isArray(artifact),
        `build artifact of ${entry.id} must be an object`);
      for (const key of Object.keys(artifact)) {
        requireFact(ARTIFACT_FIELDS.has(key), `build artifact of ${entry.id} has an unknown field: ${key}`);
      }
      const relative = requireArtifactPath(artifact.path, `build artifact of ${entry.id}`);
      const combined = `${root}/${relative}`;
      requireArtifactPath(combined, `artifact path of ${entry.id}`);
      requireFact(!seenArtifacts.has(combined), `build result attributes one file to two artifacts: ${combined}`);
      seenArtifacts.add(combined);
      const absolute = path.resolve(artifactsRoot, combined);
      const insideRoot = path.relative(artifactsRoot, absolute);
      requireFact(insideRoot.length > 0 && !insideRoot.startsWith("..") && !path.isAbsolute(insideRoot),
        `artifact escapes the artifacts root: ${combined}`);
      const facts = await fileFacts(absolute, `artifact ${combined}`);
      compareArtifactFact(facts, artifact, entry.id);
      artifacts.push({ path: combined, bytes: facts.bytes, sha256: facts.sha256 });
    }
    artifacts.sort((a, b) => a.path.localeCompare(b.path));
    resolved.push({ id: entry.id, version: entry.version, root, artifacts });
  }
  requireDisjointRoots(resolved.map((entry) => entry.root));

  const packageRecords = {};
  for (const entry of [...resolved].sort((a, b) => a.id.localeCompare(b.id))) {
    const declaration = graph.packages.get(entry.id);
    packageRecords[entry.id] = {
      version: entry.version,
      declaration_digest: digestOf(declaration),
      root: entry.root,
      bytes: entry.artifacts.reduce((total, artifact) => total + artifact.bytes, 0),
      artifacts: entry.artifacts,
    };
  }

  const taskRecords = {};
  for (const packageId of Object.keys(packageRecords)) {
    for (const taskId of deliveryTasksForPackage(graph, packageId)) {
      taskRecords[taskId] = {
        fingerprint: graph.taskFingerprint(taskId),
        packages: [...graph.tasks.get(taskId).packages].sort(),
      };
    }
  }
  const sortedTaskRecords = {};
  for (const taskId of Object.keys(taskRecords).sort()) sortedTaskRecords[taskId] = taskRecords[taskId];

  const profileRecords = {};
  for (const profileId of [...graph.profiles.keys()].sort()) {
    const profile = graph.profiles.get(profileId);
    const closure = [...graph.packageClosure(profile.selected_packages)].sort();
    const missing = closure.filter((packageId) => !(packageId in packageRecords));
    requireFact(missing.length === 0,
      `profile ${profileId} cannot be installed: the build has no artifact for ${missing.join(", ")}`);
    profileRecords[profileId] = {
      selected_packages: [...profile.selected_packages].sort(),
      forbidden_packages: [...profile.forbidden_packages].sort(),
      closure,
      not_selected: [...graph.packages.keys()].filter((packageId) => !closure.includes(packageId)).sort(),
      bytes: closure.reduce((total, packageId) => total + packageRecords[packageId].bytes, 0),
      delivery_tasks: [...new Set(closure.flatMap((packageId) => deliveryTasksForPackage(graph, packageId)))].sort(),
    };
  }

  const lock = {
    schema: LOCK_SCHEMA,
    graph_digest: graph.graphDigest,
    graph_version: graph.graphVersion,
    source_revision: build.source_revision,
    core_package: graph.distribution.core_package,
    packages: packageRecords,
    tasks: sortedTaskRecords,
    profiles: profileRecords,
  };
  lock.lock_digest = digestOf(lock);
  return lock;
}

/** Structural validation of a lock document, independent of any graph. */
export function checkLockStructure(lock) {
  const issues = [];
  const fail = (code, detail) => issues.push({ code, severity: "error", detail });
  if (lock === null || typeof lock !== "object" || Array.isArray(lock)) {
    return { ok: false, issues: [{ code: "lock_malformed", severity: "error", detail: "a lock must be a JSON object" }] };
  }
  if (lock.schema !== LOCK_SCHEMA) fail("lock_malformed", `lock schema must be ${LOCK_SCHEMA}`);
  if (typeof lock.graph_digest !== "string" || !SHA256_PATTERN.test(lock.graph_digest)) fail("lock_malformed", "graph_digest must be a sha256");
  if (typeof lock.source_revision !== "string" || lock.source_revision.length === 0) fail("lock_malformed", "source_revision is required");
  if (typeof lock.core_package !== "string") fail("lock_malformed", "core_package is required");

  const packages = lock.packages;
  if (packages === null || typeof packages !== "object" || Array.isArray(packages)) {
    fail("lock_malformed", "packages must be an object keyed by package id");
  } else {
    for (const [packageId, record] of Object.entries(packages)) {
      const label = `package ${packageId}`;
      if (record === null || typeof record !== "object") { fail("lock_malformed", `${label} must be an object`); continue; }
      if (typeof record.version !== "string" || !SEMVER_PATTERN.test(record.version)) fail("lock_malformed", `${label} needs a semver version`);
      if (typeof record.declaration_digest !== "string" || !SHA256_PATTERN.test(record.declaration_digest)) fail("lock_malformed", `${label} needs a declaration digest`);
      if (typeof record.root !== "string") { fail("lock_malformed", `${label} needs a root`); continue; }
      try {
        requireArtifactPath(record.root, `${label} root`);
      } catch (error) {
        fail("lock_malformed", error.message);
      }
      if (!Array.isArray(record.artifacts) || record.artifacts.length === 0) { fail("lock_malformed", `${label} has no artifact`); continue; }
      let total = 0;
      for (const artifact of record.artifacts) {
        if (artifact === null || typeof artifact !== "object") { fail("lock_malformed", `${label} has a malformed artifact`); continue; }
        if (typeof artifact.path !== "string" || !artifact.path.startsWith(`${record.root}/`)) {
          fail("lock_malformed", `${label} artifact is not inside its own root`);
          continue;
        }
        if (!Number.isInteger(artifact.bytes) || artifact.bytes < 0) fail("lock_malformed", `${label} artifact ${artifact.path} has an invalid byte count`);
        if (typeof artifact.sha256 !== "string" || !SHA256_PATTERN.test(artifact.sha256)) fail("lock_malformed", `${label} artifact ${artifact.path} has an invalid digest`);
        total += artifact.bytes;
      }
      if (record.bytes !== total) fail("lock_malformed", `${label} byte total is not the sum of its artifacts`);
    }
  }

  const tasks = lock.tasks;
  if (tasks === null || typeof tasks !== "object" || Array.isArray(tasks)) {
    fail("lock_malformed", "tasks must be an object keyed by task id");
  } else {
    for (const [taskId, record] of Object.entries(tasks)) {
      const label = `task ${taskId}`;
      if (record === null || typeof record !== "object") { fail("lock_malformed", `${label} must be an object`); continue; }
      if (typeof record.fingerprint !== "string" || !SHA256_PATTERN.test(record.fingerprint)) fail("lock_malformed", `${label} needs a fingerprint`);
      if (!Array.isArray(record.packages)) fail("lock_malformed", `${label} needs its packages`);
    }
  }

  const profiles = lock.profiles;
  if (profiles === null || typeof profiles !== "object" || Array.isArray(profiles)) {
    fail("lock_malformed", "profiles must be an object keyed by profile id");
  } else {
    for (const [profileId, record] of Object.entries(profiles)) {
      const label = `profile ${profileId}`;
      if (record === null || typeof record !== "object" || !Array.isArray(record.closure)) { fail("lock_malformed", `${label} must list a closure`); continue; }
      if (!Array.isArray(record.delivery_tasks)) fail("lock_malformed", `${label} must list its delivery tasks`);
      for (const packageId of record.closure) {
        if (packages === null || typeof packages !== "object" || !(packageId in packages)) fail("lock_malformed", `${label} closes over an unbuilt package: ${packageId}`);
      }
      const total = record.closure.reduce((sum, packageId) => sum + (packages?.[packageId]?.bytes ?? 0), 0);
      if (record.bytes !== total) fail("lock_malformed", `${label} byte total is not the sum of its closure`);
    }
  }

  if (typeof lock.lock_digest !== "string" || !SHA256_PATTERN.test(lock.lock_digest)) {
    fail("lock_malformed", "lock_digest must be a sha256");
  } else {
    const { lock_digest: claimed, ...rest } = lock;
    if (digestOf(rest) !== claimed) fail("lock_malformed", "lock_digest does not cover the document");
  }
  return { ok: issues.length === 0, issues };
}

/**
 * Verify that the lock's artifact facts still describe the bytes on disk, and
 * attribute every byte under a package root to exactly one package.
 */
export async function verifyByteAttribution({ lock, artifactsRoot, strict = false }) {
  const issues = [];
  const error = (code, detail, extra = {}) => issues.push({ code, severity: "error", detail, ...extra });
  const warning = (code, detail, extra = {}) => issues.push({ code, severity: "warning", detail, ...extra });
  requireFact(typeof artifactsRoot === "string" && artifactsRoot.length > 0,
    "an artifacts root directory is required");
  const packageIds = Object.keys(lock.packages ?? {}).sort();
  const totals = { bytes: 0, artifacts: 0, packages: packageIds.length, unattributed_bytes: 0, unattributed_files: 0 };

  try {
    requireDisjointRoots(packageIds.map((id) => lock.packages[id].root));
  } catch (failure) {
    error("package_roots_overlap", failure.message);
  }

  for (const packageId of packageIds) {
    const record = lock.packages[packageId];
    const rootAbsolute = path.resolve(artifactsRoot, record.root);
    const rootFacts = rootDirectoryFacts(rootAbsolute);
    if (rootFacts === null) {
      error("package_root_missing", `package ${packageId} has no directory under the artifacts root`);
      continue;
    }
    if (!rootFacts.isDirectory()) {
      error("package_root_not_directory", `package ${packageId} root is not a real directory`);
      continue;
    }
    const declared = new Set(record.artifacts.map((artifact) => artifact.path));
    let packageBytes = 0;
    for (const artifact of record.artifacts) {
      totals.artifacts += 1;
      let facts;
      try {
        facts = await fileFacts(path.resolve(artifactsRoot, artifact.path), `artifact ${artifact.path}`);
      } catch (failure) {
        error("artifact_missing", failure.message, { package: packageId, artifact: artifact.path });
        continue;
      }
      if (facts.bytes !== artifact.bytes) {
        error("artifact_bytes_changed", `artifact ${artifact.path} is ${facts.bytes} bytes, the lock says ${artifact.bytes}`, { package: packageId, artifact: artifact.path });
      }
      if (facts.sha256 !== artifact.sha256) {
        error("artifact_digest_changed", `artifact ${artifact.path} does not match the locked digest`, { package: packageId, artifact: artifact.path });
      }
      packageBytes += facts.bytes;
      totals.bytes += facts.bytes;
    }
    const walk = (directory) => {
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const absolute = path.join(directory, entry.name);
        const relative = path.relative(artifactsRoot, absolute).split(path.sep).join("/");
        if (entry.isDirectory()) { walk(absolute); continue; }
        if (declared.has(relative)) continue;
        totals.unattributed_files += 1;
        if (entry.isFile()) {
          totals.unattributed_bytes += fs.statSync(absolute).size;
          warning("unattributed_file", `file under package ${packageId} is not attributed to an artifact: ${relative}`, { package: packageId, artifact: relative });
        } else {
          warning("unattributed_entry", `entry under package ${packageId} is neither a file nor a directory: ${relative}`, { package: packageId, artifact: relative });
        }
      }
    };
    walk(rootAbsolute);
    if (strict && packageBytes !== record.bytes) {
      error("package_bytes_unaccounted", `package ${packageId} attributes ${packageBytes} bytes but the lock records ${record.bytes}`);
    }
  }

  const errors = issues.filter((issue) => issue.severity === "error").length;
  const warnings = issues.filter((issue) => issue.severity === "warning").length;
  return {
    kind: ATTRIBUTION_SCHEMA,
    ok: errors === 0 && (!strict || warnings === 0),
    strict,
    totals,
    issues,
    note: "Bytes are read from local files and attributed to one package root each. Unattributed files are reported, never silently counted.",
  };
}

/**
 * Compare a lock against the current graph and, when given, the current bytes.
 *
 * Drift is reported, never repaired: a changed package declaration or task
 * fingerprint means the recorded evidence is stale, and the decision to rebuild
 * belongs to the caller.
 */
export async function verifyInstallLock({ graph, lock, artifactsRoot = null, strict = false }) {
  const issues = [];
  const error = (code, detail, extra = {}) => issues.push({ code, severity: "error", detail, ...extra });

  const structure = checkLockStructure(lock);
  if (!structure.ok) {
    return {
      kind: LOCK_VERIFICATION_SCHEMA,
      ok: false,
      graph: { expected_digest: lock?.graph_digest ?? null, actual_digest: graph.graphDigest, matches: false },
      packages: [],
      profiles: [],
      tasks: [],
      attribution: null,
      issues: structure.issues,
      note: "A malformed lock is reported, not interpreted.",
    };
  }

  const graphMatches = lock.graph_digest === graph.graphDigest;
  if (!graphMatches) error("graph_digest_changed", `the lock was built from graph ${lock.graph_digest}, the current graph is ${graph.graphDigest}`);

  const packageDrift = [];
  for (const [packageId, record] of Object.entries(lock.packages)) {
    const declaration = graph.packages.get(packageId);
    if (declaration === undefined) {
      error("package_absent", `locked package ${packageId} is no longer declared`, { package: packageId });
      packageDrift.push({ id: packageId, present: false, declaration_digest_matches: false });
      continue;
    }
    const matches = digestOf(declaration) === record.declaration_digest;
    if (!matches) {
      error("package_declaration_changed", `package ${packageId} declarations changed after the lock was built`, { package: packageId });
    }
    packageDrift.push({ id: packageId, present: true, declaration_digest_matches: matches });
  }

  const profileDrift = [];
  for (const [profileId, record] of Object.entries(lock.profiles)) {
    const profile = graph.profiles.get(profileId);
    if (profile === undefined) {
      error("profile_absent", `locked profile ${profileId} is no longer declared`, { profile: profileId });
      profileDrift.push({ id: profileId, present: false, closure_matches: false, added: record.closure, removed: [] });
      continue;
    }
    const closure = [...graph.packageClosure(profile.selected_packages)].sort();
    const added = closure.filter((id) => !record.closure.includes(id));
    const removed = record.closure.filter((id) => !closure.includes(id));
    const matches = added.length === 0 && removed.length === 0;
    if (!matches) {
      error("profile_closure_changed", `profile ${profileId} closure changed after the lock was built`, { profile: profileId, added, removed });
    }
    profileDrift.push({ id: profileId, present: true, closure_matches: matches, added, removed });
  }

  const taskDrift = [];
  for (const [taskId, record] of Object.entries(lock.tasks ?? {})) {
    if (!graph.tasks.has(taskId)) {
      error("task_absent", `locked delivery task ${taskId} is no longer declared`, { task: taskId });
      taskDrift.push({ id: taskId, present: false, fingerprint_matches: false });
      continue;
    }
    const matches = graph.taskFingerprint(taskId) === record.fingerprint;
    if (!matches) {
      error("task_fingerprint_changed", `delivery task ${taskId} fingerprint changed; its evidence is stale`, { task: taskId });
    }
    taskDrift.push({ id: taskId, present: true, fingerprint_matches: matches });
  }
  for (const task of graph.tasks.values()) {
    const delivers = (task.packages ?? []).some((packageId) => packageId in lock.packages)
      || [...graph.packages.values()].some((pkg) => (pkg.implementation_tasks ?? []).includes(task.id) && pkg.id in lock.packages);
    if (delivers && !(task.id in lock.tasks)) {
      error("task_added", `delivery task ${task.id} is declared but absent from the lock`, { task: task.id });
    }
  }

  const attribution = artifactsRoot === null ? null : await verifyByteAttribution({ lock, artifactsRoot, strict });
  if (attribution !== null && !attribution.ok) {
    issues.push(...attribution.issues.filter((issue) => issue.severity === "error"));
  }

  const allIssues = [...issues, ...(attribution?.issues.filter((issue) => issue.severity === "warning") ?? [])];
  return {
    kind: LOCK_VERIFICATION_SCHEMA,
    ok: allIssues.every((issue) => issue.severity !== "error") && !(strict && allIssues.some((issue) => issue.severity === "warning")),
    strict,
    graph: { expected_digest: lock.graph_digest, actual_digest: graph.graphDigest, matches: graphMatches },
    packages: packageDrift,
    profiles: profileDrift,
    tasks: taskDrift,
    attribution,
    issues: allIssues,
    note: "Drift means recorded evidence is stale. Verification never mutates the graph, the lock or an installation.",
  };
}
