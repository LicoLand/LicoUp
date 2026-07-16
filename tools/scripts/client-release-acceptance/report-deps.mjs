import path from "node:path";
import { pairwiseAuditDependencyReceipts } from "../lib/client-release-dependency-receipts.mjs";
import { repoRoot, SHA256 } from "./constants.mjs";
import { requireValue, text } from "./util.mjs";

export function reportDependencyReceipts(id, payload, buildRoot) {
  if (id === "pairwise") {
    return pairwiseAuditDependencyReceipts(buildRoot, payload);
  }
  if (id === "redaction") {
    return Array.isArray(payload?.scannedRefDigests)
      ? payload.scannedRefDigests.map((entry) => ({
          id: `redaction-input:${text(entry?.ref)}`,
          ref: text(entry?.ref),
          digest: text(entry?.sha256),
        }))
      : [];
  }
  return [];
}

export function reportDependenciesReady(id, dependencies) {
  if (id !== "pairwise") return true;
  return dependencies.length === 3 &&
    JSON.stringify(dependencies.map((entry) => entry.id)) === JSON.stringify([
      "pairwise-vector-corpus",
      "pairwise-review-signoff",
      "pairwise-vector-corpus-snapshot",
    ]);
}
