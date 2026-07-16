import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import {
  selectedReleaseBlockingSupportReady,
  validateClientSupportMatrix,
} from "../client-support-matrix.mjs";
import {
  resolveContainedExistingPath,
  sha256Buffer,
  stableHashFileSnapshot,
} from "../lib/client-release-artifact-digest.mjs";
import { stableProducerSnapshotMatched } from "./artifacts/stability.mjs";
import { repoRoot } from "./constants.mjs";
import { requireValue, text } from "./util.mjs";

export function runSupportMatrixCheck(selectedTargetIds) {
  const matrixPath = resolveContainedExistingPath(
    path.join(repoRoot, "docs/releases"),
    path.join(repoRoot, "docs/releases/client-support-matrix.md"),
    { expectedKind: "file" },
  );
  const catalogPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools"),
    path.join(repoRoot, "tools/client-support-matrix.json"),
    { expectedKind: "file" },
  );
  const before = stableHashFileSnapshot(matrixPath, { maxBytes: 4 * 1024 * 1024 });
  const catalogBefore = stableReadFileSnapshot(catalogPath, {
    maxBytes: 4 * 1024 * 1024,
  });
  const validated = validateClientSupportMatrix(JSON.parse(
    catalogBefore.bytes.toString("utf8"),
  ));
  const selectedBlockingServicesSupported =
    selectedReleaseBlockingSupportReady(validated, selectedTargetIds);
  const command = spawnSync(process.execPath, ["tools/scripts/client-support-matrix.mjs", "check"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 4 * 1024 * 1024,
    timeout: 60_000,
  });
  const after = stableHashFileSnapshot(matrixPath, { maxBytes: 4 * 1024 * 1024 });
  const catalogAfter = stableHashFileSnapshot(catalogPath, {
    maxBytes: 4 * 1024 * 1024,
  });
  const catalogSnapshot = {
    digest: sha256Buffer(catalogBefore.bytes),
    device: catalogBefore.device,
    inode: catalogBefore.inode,
  };
  return {
    ready: command.status === 0 && selectedBlockingServicesSupported &&
      stableProducerSnapshotMatched(before, after) &&
      stableProducerSnapshotMatched(catalogSnapshot, catalogAfter),
    snapshot: catalogSnapshot,
    snapshots: [
      { path: matrixPath, snapshot: before },
      { path: catalogPath, snapshot: catalogSnapshot },
    ],
    selectedBlockingServicesSupported,
  };
}
