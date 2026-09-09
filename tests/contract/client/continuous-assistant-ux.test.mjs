import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

function withLocalhostNoProxy(env) {
  const extra = "localhost,127.0.0.1,::1";
  const merged = {
    ...env,
  };
  for (const key of ["NO_PROXY", "no_proxy"]) {
    const current = (merged[key] ?? "").toString();
    merged[key] = current.includes("localhost")
      ? current
      : current
        ? `${current},${extra}`
        : extra;
  }
  return merged;
}

function runUxJourneys() {
  return spawnSync(
    process.execPath,
    [
      "tools/scripts/client-toolchain-runner.mjs",
      "--check",
      "flutter",
      "--cwd",
      "apps/desktop",
      "--",
      "flutter",
      "test",
      "test/continuous_assistant_journeys",
    ],
    {
      cwd: repoRoot,
      encoding: "utf8",
      env: withLocalhostNoProxy(process.env),
    },
  );
}

function executedCount(output) {
  const match = output.match(/Flutter tests passed: (\d+) executed/);
  return match ? Number(match[1]) : 0;
}

test("AC-04-004 mounted UX journeys run the Flutter target once", () => {
  const result = runUxJourneys();
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  assert.equal(result.status, 0, output);
  assert.doesNotMatch(output, /No tests ran|No tests found/i);
  const executed = executedCount(output);
  assert.ok(
    executed > 0,
    `zero Flutter tests executed by client-toolchain-runner\n${output}`,
  );
  assert.match(output, /client-toolchain-runner/);
  assert.match(output, /flutter test/);
  assert.match(output, /continuous_assistant_journeys/);
  assert.doesNotMatch(output, /cargo test|continuity_host|--test-threads=1/);
});
