import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  acquireTestArtifactLease,
  NATIVE_CARGO_TEST_TARGET,
} from "./test-artifact-lifecycle.mjs";

const DEFAULT_MAX_BUFFER = 64 * 1024 * 1024;

export function cargoTestExecutionCount(output) {
  let executed = 0;
  const pattern = /test result: (?:ok|FAILED)\. (\d+) passed; (\d+) failed; \d+ ignored;/gu;
  for (const match of String(output || "").matchAll(pattern)) {
    executed += Number(match[1]) + Number(match[2]);
  }
  return executed;
}

export function cargoFailureDiagnostic(output, sanitizeError = () => "") {
  const sanitized = sanitizeError(String(output || "").slice(-8 * 1024))
    .replace(/\u001b\[[0-9;]*m/gu, "");
  const diagnosticLine = /^(?:error(?:\[[A-Z0-9]+\])?:|Caused by:|thread '.+' panicked at|Unable to find|No space left on device|warning: build failed)/u;
  return sanitized
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => diagnosticLine.test(line))
    .map((line) => line
      .replace(/\/(?:Users|home|private|var\/folders)\/\S*/gu, "<local-path>")
      .replace(/[A-Za-z]:\\\S*/gu, "<local-path>")
      .replace(/\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]+\b/gu, "[redacted]")
      .slice(0, 240))
    .slice(-6)
    .join("\n")
    .slice(0, 1200);
}

export function runCargoTestFilter({
  repoRoot,
  manifestPath,
  filter,
  env = process.env,
  sanitizeError = () => ""
}) {
  const started = Date.now();
  const command = "cargo";
  const commandArgs = ["test", "--manifest-path", manifestPath, filter];
  const lease = acquireTestArtifactLease({
    repoRoot,
    scope: "cargo-test-filter",
    targetPath: NATIVE_CARGO_TEST_TARGET,
  });
  let result;
  try {
    result = spawnSync(command, commandArgs, {
      cwd: repoRoot,
      env: { ...env, CARGO_TARGET_DIR: lease.targetPath },
      encoding: "utf8",
      maxBuffer: DEFAULT_MAX_BUFFER
    });
  } finally {
    lease.release();
  }
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  const executedTestCount = cargoTestExecutionCount(output);
  const matchedAtLeastOneTest = executedTestCount > 0;
  const ok = result.status === 0 && matchedAtLeastOneTest;
  const failureOutput = ok ? "" : String(result.stderr || result.stdout || "");
  const failureDiagnostic = ok || matchedAtLeastOneTest
    ? ""
    : cargoFailureDiagnostic(failureOutput, sanitizeError);
  return {
    id: filter,
    command: `${command} ${commandArgs.join(" ")}`,
    ok,
    exitCode: result.status ?? 1,
    durationMs: Date.now() - started,
    executedTestCount,
    matchedAtLeastOneTest,
    failureDigest: ok
      ? ""
      : createHash("sha256").update(failureOutput, "utf8").digest("hex"),
    failureDiagnostic,
    failureSummary: ok
      ? ""
      : result.status === 0
        ? "cargo test filter matched zero executable tests"
        : matchedAtLeastOneTest
          ? "cargo test filter failed"
          : "cargo test filter execution failed"
  };
}

// A crate-boundary move relocates a module's `#[cfg(test)]` items into the crate
// that now owns them. A dependency's test items are not compiled into the
// dependent's test binary, so a filter left on the donor manifest matches zero
// executable tests and the check reports green without running one. The caller
// states the manifests that can own the filter, donor first; the first manifest
// that executes at least one test is the answer, and a filter that executes none
// in any of them still fails with the last attempt's diagnostic. The returned
// record is the run that matched, so `command` names the manifest that ran.
export function runCargoTestFilterInOwningCrate({
  repoRoot,
  manifestPaths,
  filter,
  env = process.env,
  sanitizeError = () => ""
}) {
  if (!Array.isArray(manifestPaths) || manifestPaths.length === 0) {
    throw new Error("cargo test filter needs at least one owning manifest");
  }
  let attempt = null;
  for (const manifestPath of manifestPaths) {
    attempt = runCargoTestFilter({ repoRoot, manifestPath, filter, env, sanitizeError });
    if (attempt.matchedAtLeastOneTest) return attempt;
  }
  return attempt;
}
