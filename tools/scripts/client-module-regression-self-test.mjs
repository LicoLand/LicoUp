#!/usr/bin/env node
import { spawn } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const status = await new Promise((resolve) => {
  const child = spawn(process.execPath,
    ["--test", "tests/contract/client/client-module-regression.test.mjs"], {
    cwd: repoRoot,
    env: process.env,
    shell: false,
    stdio: "ignore",
    windowsHide: true,
  });
  child.once("error", () => resolve(null));
  child.once("close", (code) => resolve(code));
});

if (status !== 0) {
  process.stderr.write(`${JSON.stringify({
    ok: false,
    suite: "client-module-regression",
    reason: "contract_test_failed",
  })}\n`);
  process.exitCode = Number.isInteger(status) && status > 0
    ? status
    : 1;
} else {
  process.stdout.write(`${JSON.stringify({
    ok: true,
    suite: "client-module-regression",
  })}\n`);
}
