import {
  BASELINE_RECORD_COMMAND,
  CENTRAL_DELIVERY_EVIDENCE,
  RATCHET_SCHEMA,
} from "../ratchet/definitions.mjs";
import {
  compareRatchetPayloads,
  formatRatchetComparison,
  loadRatchetBaseline,
  ratchetPayloads,
  recordRatchetBaseline,
} from "../ratchet/baseline.mjs";
import { measureArchitectureRatchet } from "../ratchet/measure.mjs";

/**
 * Measure the static architecture ratchet, compare against the recorded
 * baseline, and fail on incomplete inputs, regression or unjustified developer-tool
 * execution. The returned state carries the numeric record for milestone check
 * results and the full report for inspection.
 */
export async function checkArchitectureRatchet(context) {
  const measurement = await measureArchitectureRatchet({ repoRoot: context.repoRoot, io: context.io, runtimeReviews: context.runtimeReviews, allowlist: context.allowlist });
  const report = {
    schema: RATCHET_SCHEMA,
    record: measurement.record,
    metrics: measurement.metrics,
    centralEvidence: [...CENTRAL_DELIVERY_EVIDENCE],
    status: "unknown",
    problems: measurement.problems,
  };
  for (const problem of measurement.problems) {
    context.fail(`architecture ratchet measurement input: ${problem}`);
  }

  const developerTools = measurement.metrics.find(
    (metric) => metric.id === "developer_tool_sites",
  );
  for (const site of developerTools?.details.unallowlisted_sites ?? []) {
    context.fail(
      `architecture ratchet: developer-tool execution sink ${site.id} (line ${site.line}, tools ${site.tools.join(", ")}) is not covered by a justified allowlist entry with this sink fingerprint`,
    );
  }
  if (measurement.problems.length > 0) {
    report.status = "measurement-refused";
    return { ratchetMetrics: null, ratchetReport: report };
  }

  let baseline = null;
  try {
    baseline = await loadRatchetBaseline({ repoRoot: context.repoRoot });
  } catch (error) {
    context.fail(`architecture ratchet baseline: ${error.message}`);
    report.status = "baseline-invalid";
    return { ratchetMetrics: measurement.record, ratchetReport: report };
  }

  const currentPayloads = ratchetPayloads(measurement.metrics);
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
      comparison.regressions.length > 0 || developerTools.ratchet.unallowlisted_sites > 0
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
  io,
  runtimeReviews,
  allowlist,
} = {}) {
  const measurement = await measureArchitectureRatchet({ repoRoot, io, runtimeReviews, allowlist });
  if (measurement.problems.length > 0) {
    return {
      ok: false,
      status: "measurement-refused",
      problems: measurement.problems,
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
  try {
    const outcome = await recordRatchetBaseline({ repoRoot, metrics: measurement.metrics, writeFile, now });
    return { ...outcome, record: measurement.record };
  } catch (error) {
    return { ok: false, status: "baseline-refused", message: `refusing to record: ${error.message}` };
  }
}
