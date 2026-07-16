import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import {
  DEAD_LEASE_GRACE_MS,
  LOCK_TIMEOUT_MS,
  LOCK_WAIT_MS,
  REGISTRY_PATH,
} from "./constants.mjs";

const waitBuffer = new Int32Array(new SharedArrayBuffer(4));

export function artifactRegistryRoot(repoRoot) {
  return path.join(repoRoot, ...REGISTRY_PATH.split("/"));
}

export function artifactRecordPaths(repoRoot, artifactId) {
  const record = path.join(artifactRegistryRoot(repoRoot), artifactId);
  return Object.freeze({
    cleaned: path.join(record, "cleaned.json"),
    cleanupPending: path.join(record, "cleanup-pending.json"),
    descriptor: path.join(record, "descriptor.json"),
    leases: path.join(record, "leases"),
    lock: path.join(record, ".lock"),
    reclaimable: path.join(record, "reclaimable.json"),
    record,
  });
}

export function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

export function writeJson(filePath, value) {
  mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value)}\n`, { flag: "wx" });
  renameSync(temporary, filePath);
}

export function processIsAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function staleLock(paths, { deadLeaseGraceMs, isAlive, now }) {
  const ownerPath = path.join(paths.lock, "owner.json");
  try {
    const owner = readJson(ownerPath);
    const acquiredAt = Date.parse(owner.acquiredAt);
    return Number.isFinite(acquiredAt) &&
      now() - acquiredAt >= deadLeaseGraceMs &&
      !isAlive(owner.pid);
  } catch {
    return false;
  }
}

export function withArtifactLock(paths, operation, options = {}) {
  const deadLeaseGraceMs = options.deadLeaseGraceMs ?? DEAD_LEASE_GRACE_MS;
  const isAlive = options.isAlive ?? processIsAlive;
  const now = options.now ?? Date.now;
  const deadline = now() + (options.lockTimeoutMs ?? LOCK_TIMEOUT_MS);
  const token = randomUUID();
  mkdirSync(paths.record, { recursive: true });

  while (true) {
    try {
      mkdirSync(paths.lock);
      writeJson(path.join(paths.lock, "owner.json"), {
        acquiredAt: new Date(now()).toISOString(),
        pid: process.pid,
        token,
      });
      break;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      if (staleLock(paths, { deadLeaseGraceMs, isAlive, now })) {
        rmSync(paths.lock, { force: true, recursive: true });
        continue;
      }
      if (now() >= deadline) throw new Error("test artifact lock timed out");
      Atomics.wait(waitBuffer, 0, 0, LOCK_WAIT_MS);
    }
  }

  try {
    return operation();
  } finally {
    try {
      const owner = readJson(path.join(paths.lock, "owner.json"));
      if (owner.token === token) rmSync(paths.lock, { force: true, recursive: true });
    } catch {
      // An unreadable lock is retained so another process cannot mistake it as safe.
    }
  }
}

export function removeStateMarkers(paths) {
  for (const marker of [paths.cleaned, paths.cleanupPending, paths.reclaimable]) {
    rmSync(marker, { force: true });
  }
}

export function marker(artifactId, state, now = Date.now) {
  return {
    artifactId,
    recordedAt: new Date(now()).toISOString(),
    state,
  };
}

export function pathExists(filePath) {
  return existsSync(filePath);
}
