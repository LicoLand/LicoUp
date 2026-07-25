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

export function runCargoTestFilter({
  repoRoot,
  manifestPath,
  filter,
  env = process.env,
  sanitizeError = (value) => String(value || "")
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
    failureSummary: ok
      ? ""
      : result.status === 0
        ? "cargo test filter matched zero executable tests"
        : matchedAtLeastOneTest
          ? "cargo test filter failed"
          : "cargo test filter execution failed"
  };
}
