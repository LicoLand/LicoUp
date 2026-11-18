#!/usr/bin/env node
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  captureReleaseDependencyReceipts,
  releaseDependencyReceiptsStable,
} from "./lib/client-release-dependency-receipts.mjs";

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

const root = mkdtempSync(path.join(os.tmpdir(), "lico-dependency-receipts-"));
try {
  const reports = path.join(root, "reports");
  mkdirSync(reports);
  const first = path.join(reports, "corpus.json");
  const second = path.join(reports, "signoff.json");
  writeFileSync(first, "{\"corpus\":true}\n", { mode: 0o600 });
  writeFileSync(second, "{\"signoff\":true}\n", { mode: 0o600 });
  const receipts = captureReleaseDependencyReceipts(root, [
    { id: "corpus", ref: "build/reports/corpus.json" },
    { id: "signoff", ref: "build/reports/signoff.json" },
  ]);
  requireValue(releaseDependencyReceiptsStable(root, receipts),
    "stable_dependency_receipts_rejected");
  writeFileSync(second, "{\"signoff\":false}\n", { mode: 0o600 });
  requireValue(!releaseDependencyReceiptsStable(root, receipts),
    "swapped_dependency_after_projection_accepted");
  console.log(JSON.stringify({
    ok: true,
    caseCount: 2,
    dependencySwapRejected: true,
    privatePathsIncluded: false,
  }));
} finally {
  rmSync(root, { recursive: true, force: true });
}
