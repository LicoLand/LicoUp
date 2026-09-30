import {
  BASELINE_RECORD_COMMAND,
  CENTRAL_DELIVERY_EVIDENCE,
  RATCHET_SCHEMA,
} from "../ratchet/definitions.mjs";
import {
  compareRatchetPayloads,
  formatRatchetComparison,
  loadRatchetBaseline,
  recordRatchetBaseline,
} from "../ratchet/baseline.mjs";
import { measureArchitectureRatchet } from "../ratchet/measure.mjs";

/**
 * Measure the static architecture ratchet, compare against the recorded
 * baseline, and fail only on regression or unjustified developer-tool
 * execution. The returned state carries the numeric record for milestone check
 * results and the full report for inspection.
 */
export async function checkArchitectureRatchet(context) {
  const measurement = await measureArchitectureRatchet({ repoRoot: context.repoRoot });
  const report = {
    schema: RATCHET_SCHEMA,
    record: measurement.record,
    metrics: measurement.metrics,
    centralEvidence: [...CENTRAL_DELIVERY_EVIDENCE],
    status: "unknown",
  };
  for (const problem of measurement.problems) {
    context.fail(`architecture ratchet measurement input: ${problem}`);
  }

  const developerTools = measurement.metrics.find(
    (metric) => metric.id === "developer_tool_sites",
  );
  for (const site of developerTools?.details.unallowlisted_sites ?? []) {
    const location = site.lines?.length ? `${site.file}:${site.lines[0]}` : site.file;
    context.fail(
      `architecture ratchet: developer-tool execution site ${location} executes ${site.tool} without a justified allowlist entry (classification rule ${site.rule})`,
    );
  }

  let baseline = null;
  try {
    baseline = await loadRatchetBaseline({ repoRoot: context.repoRoot });
  } catch (error) {
    context.fail(`architecture ratchet baseline: ${error.message}`);
  }

  const currentPayloads = Object.fromEntries(
    measurement.metrics.map((metric) => [metric.id, metric.ratchet]),
  );
  if (baseline === null) {
    report.status = "baseline-unrecorded";
    context.fail(
      `architecture ratchet baseline is not recorded; the initial comparable baseline is recorded on the integrated candidate with: ${BASELINE_RECORD_COMMAND}`,
    );
  } else {
    const comparison = formatRatchetComparison(
      compareRatchetPayloads(baseline.metrics, currentPayloads),
    );
    for (const message of comparison.regressions) {
      context.fail(message);
    }
    report.regressions = comparison.regressions;
    report.improvements = comparison.improvements;
    const staleAllowlist = developerTools?.details.stale_allowlist ?? [];
    if (staleAllowlist.length > 0) {
      report.allowlistUpdates = staleAllowlist.map(
        (entry) =>
          `architecture ratchet allowlist entry ${entry} no longer matches an execution site; prune it with the next baseline update`,
      );
    }
    report.status =
      comparison.regressions.length > 0
        ? "regression"
        : comparison.improvements.length > 0
          ? "improved"
          : "pass";
  }

  return {
    ratchetMetrics: measurement.record,
    ratchetReport: report,
  };
}

/**
 * Record the initial comparable baseline. Refuses while a measurement input is
 * missing or an unjustified developer-tool execution site exists, so a broken
 * state cannot become the recorded reference.
 */
export async function recordArchitectureRatchet({
  repoRoot,
  writeFile,
  now,
} = {}) {
  const measurement = await measureArchitectureRatchet({ repoRoot });
  if (measurement.problems.length > 0) {
    return {
      ok: false,
      message: `refusing to record: ${measurement.problems.join("; ")}`,
    };
  }
  const developerTools = measurement.metrics.find(
    (metric) => metric.id === "developer_tool_sites",
  );
  if ((developerTools?.ratchet.unallowlisted_sites ?? 0) > 0) {
    return {
      ok: false,
      message:
        "refusing to record: unjustified developer-tool execution sites exist; justify or remove them first",
      sites: developerTools.details.unallowlisted_sites,
    };
  }
  const outcome = await recordRatchetBaseline({
    repoRoot,
    metrics: measurement.metrics,
    writeFile,
    now,
  });
  return { ...outcome, record: measurement.record };
}
