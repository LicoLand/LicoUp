import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, readdirSync, rmSync } from "node:fs";
import path from "node:path";
import {
  DEAD_LEASE_GRACE_MS,
  FLUTTER_TEST_TARGET,
  REGISTRY_PATH,
} from "./constants.mjs";
import { classifyLeases } from "./lease.mjs";
import { inspectRunningExecutables, targetProcessUsage } from "./process-use.mjs";
import {
  normalizeTestArtifactTarget,
  rejectSymlinkComponents,
  testArtifactId,
  validateDescriptor,
} from "./policy.mjs";
import {
  artifactRecordPaths,
  artifactRegistryRoot,
  marker,
  readJson,
  withArtifactLock,
  writeJson,
} from "./registry.mjs";

function targetContainsTrackedFiles(repoRoot, relativeTarget) {
  try {
    return execFileSync("git", ["-C", repoRoot, "ls-files", "--", relativeTarget], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      maxBuffer: 1024 * 1024,
    }).length > 0;
  } catch {
    return true;
  }
}

function recordIds(repoRoot) {
  const registry = artifactRegistryRoot(repoRoot);
  if (!existsSync(registry)) return [];
  return readdirSync(registry, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => /^[a-f0-9]{24}$/u.test(name));
}

function descriptorTarget(repoRoot, artifactId) {
  try {
    const descriptor = readJson(artifactRecordPaths(repoRoot, artifactId).descriptor);
    validateDescriptor(descriptor, artifactId, descriptor.relativeTarget);
    const target = normalizeTestArtifactTarget(repoRoot, descriptor.relativeTarget);
    rejectSymlinkComponents(repoRoot, target.normalized);
    return target.normalized;
  } catch {
    return null;
  }
}

function managedAgentRoots(repoRoot) {
  const managed = new Set();
  for (const artifactId of recordIds(repoRoot)) {
    try {
      const descriptor = readJson(artifactRecordPaths(repoRoot, artifactId).descriptor);
      validateDescriptor(descriptor, artifactId, descriptor.relativeTarget);
      const match = /^build\/agents\/([^/]+)(?:\/|$)/u.exec(descriptor.relativeTarget);
      if (match) managed.add(match[1]);
    } catch {
      // Invalid records cannot establish ownership over an agent directory.
    }
  }
  return managed;
}

export function unmanagedArtifactCount(repoRoot) {
  const agentRoot = path.join(repoRoot, "build", "agents");
  if (!existsSync(agentRoot)) return 0;
  const managed = managedAgentRoots(repoRoot);
  return readdirSync(agentRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !managed.has(entry.name)).length;
}

function knownTargetPaths(repoRoot) {
  const targets = new Set([FLUTTER_TEST_TARGET]);
  for (const artifactId of recordIds(repoRoot)) {
    const relativeTarget = descriptorTarget(repoRoot, artifactId);
    if (relativeTarget) targets.add(relativeTarget);
  }
  return targets;
}

function fileMetadata(rootPath) {
  const stack = [rootPath];
  let bytes = 0;
  let latestModified = 0;
  let unsafe = false;
  while (stack.length > 0) {
    const current = stack.pop();
    let stat;
    try {
      stat = lstatSync(current);
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    latestModified = Math.max(latestModified, stat.mtimeMs);
    const name = path.basename(current);
    if ([".git", ".hg", ".svn"].includes(name) || stat.isSymbolicLink()) unsafe = true;
    if (stat.isDirectory() && !stat.isSymbolicLink()) {
      for (const entry of readdirSync(current, { withFileTypes: true })) {
        stack.push(path.join(current, entry.name));
      }
    } else {
      bytes += stat.size;
    }
  }
  return {
    bytes,
    reclaimableBytes: bytes,
    unsafe,
    lastUsedAt: latestModified > 0 ? new Date(latestModified).toISOString() : null,
  };
}

function artifactState(repoRoot, relativeTarget, processSnapshot, options = {}) {
  const target = normalizeTestArtifactTarget(repoRoot, relativeTarget);
  const artifactId = testArtifactId(target.normalized);
  const paths = artifactRecordPaths(repoRoot, artifactId);
  const protectedReasons = [];
  let descriptorExists = false;
  try {
    const descriptor = readJson(paths.descriptor);
    validateDescriptor(descriptor, artifactId, target.normalized);
    descriptorExists = true;
  } catch (error) {
    if (error?.code !== "ENOENT") protectedReasons.push("invalid-record");
  }

  let leases = { active: false, invalid: false, staleFiles: [] };
  if (existsSync(paths.leases)) {
    leases = classifyLeases(paths, {
      ...options,
      artifactId,
      deadLeaseGraceMs: options.deadLeaseGraceMs ?? DEAD_LEASE_GRACE_MS,
    });
    if (leases.invalid) protectedReasons.push("invalid-record");
    else if (leases.active) protectedReasons.push("active-lease");
  }

  const use = targetProcessUsage(target.absoluteTarget, processSnapshot, repoRoot);
  if (!use.available) protectedReasons.push("process-probe-unavailable");
  else {
    if (use.binaryPids.length > 0) protectedReasons.push("running-binary");
    if (use.buildPids.length > 0) protectedReasons.push("active-build");
  }

  if (targetContainsTrackedFiles(repoRoot, target.normalized)) {
    protectedReasons.push("tracked-source");
  }

  const protectedState = protectedReasons.some((reason) =>
    reason !== "active-lease" && reason !== "running-binary" &&
    reason !== "active-build");
  const active = protectedReasons.includes("active-lease") ||
    protectedReasons.includes("running-binary") ||
    protectedReasons.includes("active-build");
  const state = protectedState ? "protected" : active ? "active" : "reclaimable";
  return Object.freeze({
    artifactId,
    descriptorExists,
    leases,
    paths,
    protectedReasons: Object.freeze([...new Set(protectedReasons)]),
    state,
    target,
  });
}

export function inventoryTestArtifacts({
  repoRoot,
  processSnapshot = inspectRunningExecutables(),
  ...options
}) {
  const entries = [];
  for (const relativeTarget of knownTargetPaths(repoRoot)) {
    try {
      const target = normalizeTestArtifactTarget(repoRoot, relativeTarget);
      rejectSymlinkComponents(repoRoot, target.normalized);
      if (!existsSync(target.absoluteTarget)) continue;
      const state = artifactState(repoRoot, target.normalized, processSnapshot, options);
      const metadata = fileMetadata(target.absoluteTarget);
      const protectedReasons = [...state.protectedReasons];
      if (metadata.unsafe) protectedReasons.push("unsafe-output-content");
      entries.push(Object.freeze({
        relativeTarget: target.normalized,
        bytes: metadata.bytes,
        reclaimableBytes: metadata.reclaimableBytes,
        lastUsedAt: metadata.lastUsedAt,
        state: protectedReasons.length ? "protected" : state.state,
        protectedReasons,
      }));
    } catch {
      if (existsSync(path.resolve(repoRoot, relativeTarget))) entries.push(Object.freeze({
        relativeTarget, bytes: null, reclaimableBytes: null, lastUsedAt: null,
        state: "protected", protectedReasons: ["unmanaged-or-unreadable-output"],
      }));
    }
  }
  entries.sort((left, right) => left.relativeTarget.localeCompare(right.relativeTarget));
  return Object.freeze({ entries: Object.freeze(entries) });
}

export function testArtifactStatus(options) {
  const counts = { active: 0, cleaned: 0, invalid: 0, reclaimable: 0 };
  for (const artifactId of recordIds(options.repoRoot)) {
    try {
      const relativeTarget = descriptorTarget(options.repoRoot, artifactId);
      if (!relativeTarget) {
        counts.invalid += 1;
        continue;
      }
      const { leases, paths } = artifactState(
        options.repoRoot,
        relativeTarget,
        { available: true, entries: [] },
        options,
      );
      if (leases.invalid) counts.invalid += 1;
      else if (leases.active) counts.active += 1;
      else if (leases.staleFiles.length > 0 || existsSync(paths.reclaimable)) {
        counts.reclaimable += 1;
      } else if (existsSync(paths.cleaned)) counts.cleaned += 1;
      else counts.invalid += 1;
    } catch {
      counts.invalid += 1;
    }
  }
  return { ...counts, unmanaged: unmanagedArtifactCount(options.repoRoot) };
}

function targetIsKnown(repoRoot, targetPath) {
  const target = normalizeTestArtifactTarget(repoRoot, targetPath);
  return knownTargetPaths(repoRoot).has(target.normalized);
}

function ensureDescriptor(paths, target, now) {
  if (existsSync(paths.descriptor)) {
    validateDescriptor(readJson(paths.descriptor), target.artifactId, target.normalized);
    return;
  }
  writeJson(paths.descriptor, {
    artifactClass: "compiler-output",
    artifactId: target.artifactId,
    containsDownloadedDependencies: false,
    createdAt: new Date(now()).toISOString(),
    relativeTarget: target.normalized,
    retention: "reclaimable",
    schemaVersion: "licoup.test-artifact.v1",
  });
}

function pruneResult(state, {
  dryRun = false,
  remove = false,
  repoRoot,
  now = Date.now,
} = {}) {
  if (state.protectedReasons.includes("active-lease") ||
      state.protectedReasons.includes("running-binary") ||
      state.protectedReasons.includes("active-build")) {
    return { active: 1, eligible: 0, failed: 0, removed: 0, skipped: 0 };
  }
  if (state.state === "protected") {
    return { active: 0, eligible: 0, failed: 1, removed: 0, skipped: 0 };
  }
  if (!existsSync(state.target.absoluteTarget)) {
    return { active: 0, eligible: 0, failed: 0, removed: 0, skipped: 1 };
  }
  if (dryRun) return { active: 0, eligible: 1, failed: 0, removed: 0, skipped: 0 };
  if (!remove) {
    writeJson(state.paths.reclaimable, marker(state.artifactId, "reclaimable", now));
    return { active: 0, eligible: 1, failed: 0, removed: 0, skipped: 0 };
  }

  const before = fileMetadata(state.target.absoluteTarget);
  if (before.unsafe) return {
    active: 0, eligible: 0, failed: 1, removed: 0, skipped: 0,
    protectedReasons: ["unsafe-output-content"],
  };
  const bytesBefore = before.bytes;

  rmSync(state.target.absoluteTarget, { force: true, recursive: true });
  for (const staleFile of state.leases.staleFiles) rmSync(staleFile, { force: true });
  rmSync(state.paths.reclaimable, { force: true });
  rmSync(state.paths.cleanupPending, { force: true });
  writeJson(state.paths.cleaned, marker(state.artifactId, "cleaned", now));
  return {
    active: 0,
    eligible: 1,
    failed: 0,
    removed: 1,
    skipped: 0,
    bytesAfter: 0,
    bytesBefore,
  };
}

export function pruneTestArtifactTarget({
  repoRoot,
  targetPath,
  dryRun = false,
  env = process.env,
  now = Date.now,
  deadLeaseGraceMs = DEAD_LEASE_GRACE_MS,
  isAlive,
  processSnapshot,
} = {}) {
  const target = normalizeTestArtifactTarget(repoRoot, targetPath);
  rejectSymlinkComponents(repoRoot, target.normalized);
  if (!targetIsKnown(repoRoot, target.normalized)) {
    throw new Error("test artifact target is not owned by this checkout");
  }
  const options = { deadLeaseGraceMs, env, isAlive, now };
  const initialSnapshot = processSnapshot || inspectRunningExecutables();
  if (dryRun) {
    const state = artifactState(repoRoot, target.normalized, initialSnapshot, options);
    const result = pruneResult(state, { dryRun, now, repoRoot });
    return {
      ...result,
      removed: false,
      removedCount: result.removed,
      relativeTarget: target.normalized,
      protectedReasons: state.protectedReasons,
    };
  }

  const artifactId = testArtifactId(target.normalized);
  const paths = artifactRecordPaths(repoRoot, artifactId);
  return withArtifactLock(paths, () => {
    const currentSnapshot = processSnapshot || inspectRunningExecutables();
    const state = artifactState(repoRoot, target.normalized, currentSnapshot, options);
    if (state.state !== "protected" && !state.protectedReasons.includes("active-lease") &&
        !state.protectedReasons.includes("running-binary") &&
        !state.protectedReasons.includes("active-build") &&
        existsSync(target.absoluteTarget)) {
      ensureDescriptor(paths, { ...target, artifactId }, now);
    }
    const result = pruneResult(state, { now, remove: true, repoRoot });
    return {
      ...result,
      removed: result.removed === 1,
      removedCount: result.removed,
      relativeTarget: target.normalized,
      protectedReasons: result.protectedReasons || state.protectedReasons,
    };
  }, { deadLeaseGraceMs, isAlive, now });
}

export function completeTestArtifactWorkspace({ repoRoot, ...options }) {
  const targets = [...knownTargetPaths(repoRoot)]
    .filter((relativeTarget) => existsSync(path.join(repoRoot, ...relativeTarget.split("/"))))
    .sort();
  const results = targets.map((targetPath) =>
    pruneTestArtifactTarget({ repoRoot, targetPath, ...options }));
  const counts = { active: 0, eligible: 0, failed: 0, removedCount: 0, skipped: 0 };
  const protectedReasons = new Set();
  for (const result of results) {
    for (const key of Object.keys(counts)) counts[key] += result[key] || 0;
    for (const reason of result.protectedReasons || []) protectedReasons.add(reason);
  }
  return {
    ...counts,
    removed: results.some((result) => result.removed === true),
    relativeTargets: targets,
    protectedReasons: [...protectedReasons],
  };
}

export function pruneReclaimableTestArtifacts({ dryRun = false, ...options }) {
  const result = { active: 0, eligible: 0, failed: 0, removed: 0, skipped: 0 };
  const processSnapshot = options.processSnapshot || inspectRunningExecutables();
  for (const artifactId of recordIds(options.repoRoot)) {
    const relativeTarget = descriptorTarget(options.repoRoot, artifactId);
    if (!relativeTarget) {
      result.failed += 1;
      continue;
    }
    const state = artifactState(
      options.repoRoot,
      relativeTarget,
      processSnapshot,
      options,
    );
    if (state.state === "protected" || state.protectedReasons.includes("active-lease") ||
        state.protectedReasons.includes("running-binary") ||
        state.protectedReasons.includes("active-build")) {
      if (state.protectedReasons.includes("active-lease") ||
          state.protectedReasons.includes("running-binary") ||
          state.protectedReasons.includes("active-build")) result.active += 1;
      else result.failed += 1;
      continue;
    }
    if (dryRun) {
      if (existsSync(state.paths.reclaimable) || state.leases.staleFiles.length > 0) {
        result.eligible += 1;
      } else {
        result.skipped += 1;
      }
      continue;
    }
    try {
      withArtifactLock(state.paths, () => {
        const currentSnapshot = options.processSnapshot || inspectRunningExecutables();
        const locked = artifactState(
          options.repoRoot,
          relativeTarget,
          currentSnapshot,
          options,
        );
        if (locked.state === "protected" ||
            locked.protectedReasons.includes("active-lease") ||
            locked.protectedReasons.includes("running-binary") ||
            locked.protectedReasons.includes("active-build")) {
          if (locked.protectedReasons.includes("active-lease") ||
              locked.protectedReasons.includes("running-binary") ||
              locked.protectedReasons.includes("active-build")) result.active += 1;
          else result.failed += 1;
          return;
        }
        if (!existsSync(locked.paths.reclaimable) && locked.leases.staleFiles.length === 0) {
          result.skipped += 1;
          return;
        }
        const pruned = pruneResult(locked, {
          now: options.now,
          remove: true,
          repoRoot: options.repoRoot,
        });
        for (const key of ["active", "eligible", "failed", "removed", "skipped"]) {
          result[key] += pruned[key];
        }
      }, options);
    } catch {
      result.failed += 1;
    }
  }
  return { ...result, unmanaged: unmanagedArtifactCount(options.repoRoot) };
}

export { REGISTRY_PATH, testArtifactId };
