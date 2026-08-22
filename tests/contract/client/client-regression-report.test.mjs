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
    concurrency: { maximumWeight: 4, maximumProcesses: 2, poolPeaks: { rust: 4 } },
    results: [{
      id: "rust-target-1",
      stage: "backend",
      lane: "backend",
      toolchain: "rust",
      status: "passed",
      reason: canary,
      durationMs: 1_000,
      members: ["rust.domain.synthetic"],
      metrics: {
        wallTimeMs: { status: "measured", value: 1_000, rawOutput: canary },
        directCpuMs: { status: "unavailable", reason: "native_metric_unavailable", raw: canary },
        descendantCpuMs: { status: "unavailable", reason: "native_metric_unavailable" },
        peakResidentBytes: { status: "unavailable", reason: "native_metric_unavailable" },
        toolchainNative: {
          kind: "rust",
          cargoBuildTimingReport: {
            status: "measured",
            value: { generated: true, format: "html", machineReadable: false, path: canary },
          },
          libtestSuiteWallTime: {
            status: "measured",
            value: { count: 1, totalMs: 50, minimumMs: 50, maximumMs: 50, name: canary },
          },
          libtestCaseWallTime: { status: "unavailable", reason: "not_verified", output: canary },
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
  assert.equal(report.status, "failed");
  assert.equal(report.results[0].reason, "execution_failed");
  assert.equal(report.compatibility[0].reason, "compatibility_failed");
  assert.equal(report.results[0].metrics.wallTimeMs.value, 1_000);
  assert.equal(report.results[0].metrics.toolchainNative.libtestSuiteWallTime.value.count, 1);
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
        { stage: "backend", status: "failed", members: ["rust.domain.synthetic"] },
        { stage: "frontend", status: "passed", members: ["flutter.feature.synthetic"] },
        { stage: "compatibility", status: "failed", members: ["codex"] },
      ],
      compatibility: [
        { kind: "agent", id: "codex", status: "failed" },
        { kind: "platform", id: "linux", status: "unverified" },
      ],
    }));
    const retry = await retrySelectionFromReport(reportPath, {
      validModuleIds: ["rust.domain.synthetic", "flutter.feature.synthetic"],
      validCompatibilityIds: ["agent:codex", "platform:linux"],
    });
    assert.deepEqual(retry.moduleIds, ["rust.domain.synthetic"]);
    assert.deepEqual(retry.compatibilityIds, ["agent:codex"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
