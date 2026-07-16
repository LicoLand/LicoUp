import { spawnSync } from "node:child_process";
import process from "node:process";
import { repoRoot } from "./constants.mjs";

export function command(file, args, options = {}) {
  return spawnSync(file, args, {
    cwd: options.cwd || repoRoot,
    env: options.env || process.env,
    encoding: "utf8",
    stdio: "pipe",
    timeout: options.timeoutMs || 30_000,
    maxBuffer: options.maxBuffer || 32 * 1024 * 1024,
  });
}

export function commandReady(result) {
  return result.status === 0 && result.error === undefined;
}

export function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
