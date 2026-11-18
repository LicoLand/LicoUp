import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createClientRegressionReport,
  LEGACY_INCOMPLETE_BASELINE_MS,
  retrySelectionFromReport,
} from "../../../tools/regression/client-regression-report.mjs";

test("regression report allowlists numeric metrics and never retains command output", () => {
  const canary = "PRIVATE_COMMAND_OUTPUT_CANARY";
  const report = createClientRegressionReport({
    runKind: "complete",
    startedAt: "2026-01-01T00:00:00.000Z",
    completedAt: "2026-01-01T00:00:01.000Z",
    durationMs: 1_000,
    candidateHead: "a".repeat(40),
    sourceStateDigest: `sha256:${"b".repeat(64)}`,
    concurrency: { maximumWeight: 4, maximumProcesses: 2, poolPeaks: { flutter: 4 } },
    results: [{
      id: "node-test-1",
      stage: "foundation",
      lane: "foundation",
      toolchain: "node-test",
      status: "passed",
      reason: canary,
      durationMs: 1_000,
      members: ["regression.synthetic"],
      evidenceHead: "a".repeat(40),
      metrics: {
        wallTimeMs: { status: "measured", value: 1_000, rawOutput: canary },
        directCpuMs: { status: "unavailable", reason: "native_metric_unavailable", raw: canary },
        descendantCpuMs: { status: "unavailable", reason: "native_metric_unavailable" },
        peakResidentBytes: { status: "unavailable", reason: "native_metric_unavailable" },
        toolchainNative: {
          kind: "flutter",
          suiteCount: { status: "measured", value: 2 },
          testCount: { status: "measured", value: 12 },
          passedCount: { status: "measured", value: 12 },
          failedCount: { status: "measured", value: 0 },
          skippedCount: { status: "measured", value: 0 },
          totalTestDurationMs: { status: "measured", value: 800 },
          longestTestDurationMs: { status: "measured", value: 300 },
          privateOutput: canary,
        },
      },
    }],
    compatibility: [{
      id: "synthetic",
      kind: "platform",
      status: "failed",
      reason: `unsafe reason ${canary}`,
      staticStatus: "passed",
      liveStatus: "failed",
      durationMs: 1,
    }],
  });

  assert.equal(JSON.stringify(report).includes(canary), false);
  assert.equal(report.complete, true);
  assert.equal(report.candidateHead, "a".repeat(40));
  assert.equal(report.results[0].evidenceHead, "a".repeat(40));
  assert.equal(report.status, "failed");
  assert.equal(report.results[0].reason, "execution_failed");
  assert.equal(report.compatibility[0].reason, "compatibility_failed");
  assert.equal(report.results[0].metrics.wallTimeMs.value, 1_000);
  assert.equal(report.results[0].metrics.toolchainNative.testCount.value, 12);
  assert.equal(report.legacyBaseline.lowerBoundDurationMs, LEGACY_INCOMPLETE_BASELINE_MS);
  assert.equal(report.legacyBaseline.speedupPercent, null);
});

test("retry reports redispatch failed modules and compatibility targets only", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "lico-regression-retry-"));
  const reportPath = path.join(directory, "report.json");
  try {
    await writeFile(reportPath, JSON.stringify({
      schemaVersion: "licoup.client-regression-report.v1",
      results: [
        { stage: "foundation", status: "failed", members: ["regression.synthetic"] },
        { stage: "frontend", status: "passed", members: ["flutter.feature.synthetic"] },
        { stage: "compatibility", status: "failed", members: ["macos"] },
      ],
      compatibility: [
        { kind: "platform", id: "macos", status: "failed" },
        { kind: "platform", id: "linux", status: "unverified" },
      ],
    }));
    const retry = await retrySelectionFromReport(reportPath, {
      validModuleIds: ["regression.synthetic", "flutter.feature.synthetic"],
      validCompatibilityIds: ["platform:macos", "platform:linux"],
    });
    assert.deepEqual(retry.moduleIds, ["regression.synthetic"]);
    assert.deepEqual(retry.compatibilityIds, ["platform:macos"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
