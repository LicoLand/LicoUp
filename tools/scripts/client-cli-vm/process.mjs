import { execFileSync, spawnSync } from "node:child_process";
import process from "node:process";
import { repoRoot } from "./constants.mjs";

export function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || repoRoot,
    env: options.env || process.env,
    stdio: options.stdio || "inherit",
    encoding: options.encoding || "utf8",
  });
  if (result.status !== 0) {
    throw new Error(
      `${command} exited with code ${result.status ?? 1}; command arguments redacted`,
    );
  }
  return result;
}

export function commandOutput(command, args) {
  return execFileSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

export function requireTool(command) {
  try {
    commandOutput("which", [command]);
  } catch {
    throw new Error(`${command} is required for client CLI VM workflows.`);
  }
}
