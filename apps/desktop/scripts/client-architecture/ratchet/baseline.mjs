/**
 * Architecture ratchet baseline semantics.
 *
 * The baseline stores only the tracked `ratchet` payload of each metric
 * (numbers and ordered string sets). A regression is any number that grew or
 * any set member that appeared; an improvement is any number that fell or any
 * set member that disappeared. Recording refuses to raise a value, so the
 * baseline can only move in the improving direction. The initial baseline is
 * recorded on the integrated candidate; the operating procedure is documented
 * in the "Static architecture metrics" section of `docs/RUNBOOK.md`.
 */

import fs from "node:fs/promises";
import path from "node:path";
import { BASELINE_PATH, BASELINE_RECORD_COMMAND, BASELINE_SCHEMA } from "./definitions.mjs";

export async function loadRatchetBaseline({ repoRoot }) {
  let text;
  try {
    text = await fs.readFile(path.join(repoRoot, BASELINE_PATH), "utf8");
  } catch {
    return null;
  }
  let document;
  try {
    document = JSON.parse(text);
  } catch {
    throw new Error(`${BASELINE_PATH} is not valid JSON`);
  }
  if (document.schema !== BASELINE_SCHEMA) {
    throw new Error(
      `${BASELINE_PATH} has schema ${String(document.schema)}; expected ${BASELINE_SCHEMA}`,
    );
  }
  if (typeof document.metrics !== "object" || document.metrics === null) {
    throw new Error(`${BASELINE_PATH} does not contain a metrics object`);
  }
  return document;
}

function diffPayload(metricId, baseline, current, output) {
  for (const [field, currentValue] of Object.entries(current)) {
    if (!(field in baseline)) {
      output.regressions.push({ metricId, field, kind: "unrecorded-field" });
      continue;
    }
    const baselineValue = baseline[field];
    if (typeof currentValue === "number" && typeof baselineValue === "number") {
      if (currentValue > baselineValue) {
        output.regressions.push({
          metricId,
          field,
          kind: "increase",
          from: baselineValue,
          to: currentValue,
        });
      } else if (currentValue < baselineValue) {
        output.improvements.push({
          metricId,
          field,
          kind: "decrease",
          from: baselineValue,
          to: currentValue,
        });
      }
      continue;
    }
    if (Array.isArray(currentValue) && Array.isArray(baselineValue)) {
      const baselineSet = new Set(baselineValue);
      const currentSet = new Set(currentValue);
      const added = currentValue.filter((item) => !baselineSet.has(item));
      const removed = baselineValue.filter((item) => !currentSet.has(item));
      if (added.length > 0) {
        output.regressions.push({ metricId, field, kind: "added", items: added });
      }
      if (removed.length > 0) {
        output.improvements.push({ metricId, field, kind: "removed", items: removed });
      }
      continue;
    }
    if (JSON.stringify(currentValue) !== JSON.stringify(baselineValue)) {
      output.regressions.push({ metricId, field, kind: "changed" });
    }
  }
  for (const field of Object.keys(baseline)) {
    if (!(field in current)) {
      output.regressions.push({ metricId, field, kind: "missing" });
    }
  }
}

/** Compare baseline metrics (map by id) with current metric payloads. */
export function compareRatchetPayloads(baselineMetrics, currentMetrics) {
  const output = { regressions: [], improvements: [] };
  for (const [metricId, current] of Object.entries(currentMetrics)) {
    if (!(metricId in baselineMetrics)) {
      output.regressions.push({ metricId, field: "*", kind: "unrecorded-metric" });
      continue;
    }
    diffPayload(metricId, baselineMetrics[metricId] ?? {}, current, output);
  }
  for (const metricId of Object.keys(baselineMetrics)) {
    if (!(metricId in currentMetrics)) {
      output.regressions.push({ metricId, field: "*", kind: "missing-metric" });
    }
  }
  return output;
}

function regressionMessage(entry) {
  const prefix = `architecture ratchet regression: ${entry.metricId}.${entry.field}`;
  if (entry.kind === "increase") {
    const delta = entry.to - entry.from;
    return `${prefix} grew from ${entry.from} to ${entry.to} (+${delta}); remove the new dependency or split the change before re-recording.`;
  }
  if (entry.kind === "added") {
    return `${prefix} gained ${entry.items.join(", ")}; each new entry needs removal or an explicit reviewed decision.`;
  }
  if (entry.kind === "unrecorded-metric") {
    return `${prefix} is not present in the recorded baseline; re-record with ${BASELINE_RECORD_COMMAND} on the integrated candidate.`;
  }
  if (entry.kind === "missing-metric") {
    return `${prefix} is present in the baseline but no longer measured; restore the measurement or re-record.`;
  }
  if (entry.kind === "unrecorded-field") {
    return `${prefix} appeared without a baseline value; re-record with ${BASELINE_RECORD_COMMAND} on the integrated candidate.`;
  }
  if (entry.kind === "changed") {
    return `${prefix} changed shape; the recorded and measured definitions disagree.`;
  }
  return `${prefix} changed (${entry.kind}).`;
}

function improvementMessage(entry) {
  const prefix = `architecture ratchet improvement: ${entry.metricId}.${entry.field}`;
  if (entry.kind === "decrease") {
    return `${prefix} fell from ${entry.from} to ${entry.to}; keep the improvement and update the baseline with ${BASELINE_RECORD_COMMAND}.`;
  }
  if (entry.kind === "removed") {
    return `${prefix} removed ${entry.items.join(", ")}; keep the improvement and update the baseline with ${BASELINE_RECORD_COMMAND}.`;
  }
  return `${prefix} improved; update the baseline with ${BASELINE_RECORD_COMMAND}.`;
}

export function formatRatchetComparison(comparison) {
  return {
    regressions: comparison.regressions.map(regressionMessage),
    improvements: comparison.improvements.map(improvementMessage),
  };
}

/**
 * Record the current metric payloads as the baseline. Refuses to raise a
 * recorded value: a regression must be repaired or explicitly re-decided, not
 * silently absorbed.
 */
export async function recordRatchetBaseline({
  repoRoot,
  metrics,
  now = () => new Date().toISOString(),
  writeFile = fs.writeFile,
}) {
  const current = Object.fromEntries(metrics.map((metric) => [metric.id, metric.ratchet]));
  const existing = await loadRatchetBaseline({ repoRoot });
  if (existing) {
    const comparison = compareRatchetPayloads(existing.metrics, current);
    if (comparison.regressions.length > 0) {
      return {
        ok: false,
        message:
          "refusing to record: the measured values regress against the recorded baseline; repair the regression or revise the definition first",
        regressions: formatRatchetComparison(comparison).regressions,
      };
    }
  }
  const document = {
    schema: BASELINE_SCHEMA,
    recordedAt: now(),
    metrics: current,
  };
  const absolutePath = path.join(repoRoot, BASELINE_PATH);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await writeFile(
    absolutePath,
    `${JSON.stringify(document, null, 2)}\n`,
    "utf8",
  );
  return { ok: true, path: BASELINE_PATH, metrics: current, superseded: Boolean(existing) };
}
