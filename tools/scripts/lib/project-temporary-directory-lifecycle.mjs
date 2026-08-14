import {
  lstatSync,
  readdirSync,
  realpathSync,
  rmSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";

export class ProjectTemporaryDirectoryLifecycleError extends Error {
  constructor(reason) {
    super(reason);
    this.name = "ProjectTemporaryDirectoryLifecycleError";
    this.reason = reason;
  }
}

export function retireInactiveProjectTemporaryDirectories({
  root,
  parseOwnerPid,
  currentNames = [],
  isProcessAlive = processIsAlive,
  removeDirectory = removeTree,
}) {
  const boundary = validatedRoot(root);
  if (!boundary) return Object.freeze({ scanned: 0, removed: 0 });
  const current = new Set(currentNames);
  let entries;
  try {
    entries = readdirSync(boundary.path, { withFileTypes: true });
  } catch {
    lifecycleFailure("temporary_directory_scan_failed");
  }
  let scanned = 0;
  let removed = 0;
  for (const entry of entries) {
    const ownerPid = parseOwnerPid(entry.name);
    if (ownerPid === null) continue;
    scanned += 1;
    if (current.has(entry.name)) continue;
    const candidate = validatedManagedChild(boundary, entry.name);
    let alive;
    try {
      alive = isProcessAlive(ownerPid);
    } catch {
      lifecycleFailure("temporary_directory_liveness_unknown");
    }
    if (alive === true) continue;
    if (alive !== false) {
      lifecycleFailure("temporary_directory_liveness_unknown");
    }
    try {
      removeDirectory(candidate);
    } catch {
      lifecycleFailure("temporary_directory_removal_failed");
    }
    removed += 1;
  }
  return Object.freeze({ scanned, removed });
}

export function removeCurrentProjectTemporaryDirectory({
  root,
  name,
  parseOwnerPid,
  expectedPid = process.pid,
  removeDirectory = removeTree,
}) {
  const boundary = validatedRoot(root);
  if (!boundary) return false;
  if (parseOwnerPid(name) !== expectedPid) {
    lifecycleFailure("temporary_directory_name_invalid");
  }
  const candidatePath = path.join(boundary.path, name);
  let candidateInfo;
  try {
    candidateInfo = lstatSync(candidatePath, { throwIfNoEntry: false });
  } catch {
    lifecycleFailure("temporary_directory_entry_invalid");
  }
  if (!candidateInfo) return false;
  const candidate = validatedManagedChild(boundary, name);
  try {
    removeDirectory(candidate);
  } catch {
    lifecycleFailure("temporary_directory_removal_failed");
  }
  return true;
}

export function processIsAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) return null;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    if (error?.code === "EPERM") return true;
    return null;
  }
}

function validatedRoot(root) {
  const resolved = path.resolve(root);
  let info;
  try {
    info = lstatSync(resolved, { throwIfNoEntry: false });
  } catch {
    lifecycleFailure("temporary_directory_root_invalid");
  }
  if (!info) return null;
  if (!info.isDirectory() || info.isSymbolicLink()) {
    lifecycleFailure("temporary_directory_root_invalid");
  }
  try {
    return Object.freeze({ path: resolved, realPath: realpathSync(resolved) });
  } catch {
    lifecycleFailure("temporary_directory_root_invalid");
  }
}

function validatedManagedChild(boundary, name) {
  const candidate = path.join(boundary.path, name);
  if (path.dirname(candidate) !== boundary.path) {
    lifecycleFailure("temporary_directory_entry_invalid");
  }
  let info;
  let realCandidate;
  try {
    info = lstatSync(candidate, { throwIfNoEntry: false });
    if (!info?.isDirectory() || info.isSymbolicLink()) {
      lifecycleFailure("temporary_directory_entry_invalid");
    }
    realCandidate = realpathSync(candidate);
  } catch (error) {
    if (error instanceof ProjectTemporaryDirectoryLifecycleError) throw error;
    lifecycleFailure("temporary_directory_entry_invalid");
  }
  if (path.dirname(realCandidate) !== boundary.realPath) {
    lifecycleFailure("temporary_directory_entry_invalid");
  }
  return candidate;
}

function removeTree(candidate) {
  rmSync(candidate, { recursive: true, force: true });
}

function lifecycleFailure(reason) {
  throw new ProjectTemporaryDirectoryLifecycleError(reason);
}
