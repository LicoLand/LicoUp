import path from "node:path";
import {
  resolveContainedExistingPath,
  sha256Buffer,
  stableHashFileSnapshot,
  stableReadFileSnapshot,
} from "./client-release-artifact-digest.mjs";

export function captureSourceBoundJsonPolicy({
  allowedRoot,
  filePath,
  id,
  ref,
  maxBytes = 4 * 1024 * 1024,
}) {
  const safePath = resolveContainedExistingPath(allowedRoot, filePath, {
    expectedKind: "file",
  });
  const snapshot = stableReadFileSnapshot(safePath, { maxBytes });
  const payload = JSON.parse(snapshot.bytes.toString("utf8"));
  return Object.freeze({
    id: String(id),
    ref: String(ref),
    path: safePath,
    maxBytes,
    digest: sha256Buffer(snapshot.bytes),
    device: snapshot.device,
    inode: snapshot.inode,
    payload,
  });
}

export function sourceBoundPolicySnapshotStable(snapshot) {
  try {
    const after = stableHashFileSnapshot(snapshot.path, {
      maxBytes: snapshot.maxBytes,
    });
    return after.digest === snapshot.digest &&
      after.device === snapshot.device && after.inode === snapshot.inode;
  } catch {
    return false;
  }
}

export function sourceBoundPolicySnapshotsStable(snapshots) {
  return Array.isArray(snapshots) && snapshots.length > 0 &&
    snapshots.every(sourceBoundPolicySnapshotStable);
}

export function publicPolicyBindings(snapshots) {
  return snapshots.map((snapshot) => ({
    id: snapshot.id,
    ref: snapshot.ref.split(path.sep).join("/"),
    digest: snapshot.digest,
  }));
}
