#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const result = spawnSync(
  process.execPath,
  ["--test", "tests/contract/client/client-module-regression.test.mjs"],
  {
    cwd: repoRoot,
    encoding: "utf8",
    env: process.env,
    maxBuffer: 16 * 1024 * 1024,
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 60_000,
  },
);

if (result.error || result.status !== 0) {
  process.stderr.write(`${JSON.stringify({
    ok: false,
    suite: "client-module-regression",
    reason: "contract_test_failed",
  })}\n`);
  process.exitCode = Number.isInteger(result.status) && result.status > 0
    ? result.status
    : 1;
} else {
  process.stdout.write(`${JSON.stringify({
    ok: true,
    suite: "client-module-regression",
  })}\n`);
}
