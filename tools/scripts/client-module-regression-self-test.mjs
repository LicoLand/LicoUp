#!/usr/bin/env node
import { spawn } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const DIAGNOSTIC_LIMIT = 2 * 1024 * 1024;

function appendDiagnosticTail(current, chunk) {
  const next = `${current}${Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk ?? "")}`;
  return next.length > DIAGNOSTIC_LIMIT ? next.slice(-DIAGNOSTIC_LIMIT) : next;
}

export async function runClientModuleRegressionSelfTest({
  spawnImpl = spawn,
  output = process.stdout,
  errorOutput = process.stderr,
} = {}) {
  let childStdout = "";
  let childStderr = "";
  const status = await new Promise((resolve) => {
    let settled = false;
    const finish = (code) => {
      if (settled) return;
      settled = true;
      resolve(code);
    };
    const child = spawnImpl(process.execPath,
      ["--test", "tests/contract/client/client-module-regression.test.mjs"], {
        cwd: repoRoot,
        env: process.env,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
    child.stdout?.on?.("data", (chunk) => {
      childStdout = appendDiagnosticTail(childStdout, chunk);
    });
    child.stderr?.on?.("data", (chunk) => {
      childStderr = appendDiagnosticTail(childStderr, chunk);
    });
    child.once("error", () => finish(null));
    child.once("close", (code) => finish(code));
  });

  if (status !== 0) {
    errorOutput.write(`[contract stdout]\n${childStdout}\n[contract stderr]\n${childStderr}\n`);
    errorOutput.write(`${JSON.stringify({
      ok: false,
      suite: "client-module-regression",
      reason: "contract_test_failed",
    })}\n`);
    return Number.isInteger(status) && status > 0 ? status : 1;
  }

  output.write(`${JSON.stringify({
    ok: true,
    suite: "client-module-regression",
  })}\n`);
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.exitCode = await runClientModuleRegressionSelfTest();
}
