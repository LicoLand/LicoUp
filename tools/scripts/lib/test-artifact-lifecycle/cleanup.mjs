import { existsSync, readdirSync, rmSync } from "node:fs";
import path from "node:path";
import { REGISTRY_PATH } from "./constants.mjs";
import { classifyLeases } from "./lease.mjs";
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

function recordIds(repoRoot) {
  const registry = artifactRegistryRoot(repoRoot);
  if (!existsSync(registry)) return [];
  return readdirSync(registry, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => /^[a-f0-9]{24}$/u.test(name));
}

function inspectRecord(repoRoot, artifactId, options = {}) {
  const paths = artifactRecordPaths(repoRoot, artifactId);
  const descriptor = readJson(paths.descriptor);
  validateDescriptor(descriptor, artifactId, descriptor.relativeTarget);
  const target = normalizeTestArtifactTarget(repoRoot, descriptor.relativeTarget);
  rejectSymlinkComponents(repoRoot, target.normalized);
  const leases = classifyLeases(paths, { ...options, artifactId });
  return Object.freeze({ descriptor, leases, paths, target });
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
      // Invalid records cannot establish ownership over a build directory.
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

export function testArtifactStatus(options) {
  const counts = { active: 0, cleaned: 0, invalid: 0, reclaimable: 0 };
  for (const artifactId of recordIds(options.repoRoot)) {
    try {
      const { leases, paths } = inspectRecord(options.repoRoot, artifactId, options);
      if (leases.invalid) counts.invalid += 1;
      else if (leases.active) counts.active += 1;
      else if (
        leases.staleFiles.length > 0 || existsSync(paths.reclaimable)
      ) counts.reclaimable += 1;
      else if (existsSync(paths.cleaned)) counts.cleaned += 1;
      else counts.invalid += 1;
    } catch {
      counts.invalid += 1;
    }
  }
  return { ...counts, unmanaged: unmanagedArtifactCount(options.repoRoot) };
}

export function pruneReclaimableTestArtifacts({ dryRun = false, ...options }) {
  const result = { active: 0, eligible: 0, failed: 0, removed: 0, skipped: 0 };
  for (const artifactId of recordIds(options.repoRoot)) {
    try {
      withArtifactLock(artifactRecordPaths(options.repoRoot, artifactId), () => {
        const { leases, paths, target } = inspectRecord(options.repoRoot, artifactId, options);
        if (leases.invalid) {
          result.failed += 1;
          return;
        }
        if (leases.active) {
          result.active += 1;
          return;
        }
        for (const staleFile of leases.staleFiles) {
          rmSync(staleFile, { force: true });
        }
        if (leases.staleFiles.length > 0) {
          writeJson(paths.reclaimable, marker(artifactId, "reclaimable", options.now));
        }
        if (!existsSync(paths.reclaimable)) {
          result.skipped += 1;
          return;
        }
        result.eligible += 1;
        if (dryRun) return;
        try {
          rmSync(target.absoluteTarget, { force: true, recursive: true });
          rmSync(paths.reclaimable, { force: true });
          rmSync(paths.cleanupPending, { force: true });
          writeJson(paths.cleaned, marker(artifactId, "cleaned", options.now));
          result.removed += 1;
        } catch {
          writeJson(paths.cleanupPending, marker(artifactId, "cleanup-pending", options.now));
          result.failed += 1;
        }
      }, options);
    } catch {
      result.failed += 1;
    }
  }
  return { ...result, unmanaged: unmanagedArtifactCount(options.repoRoot) };
}

export { REGISTRY_PATH, testArtifactId };
