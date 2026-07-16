import path from "node:path";
import { ROOT } from "./constants.mjs";

export function parseArgs(argv) {
  const checks = [];
  let cwd = ROOT;
  const separator = argv.indexOf("--");
  if (separator === -1 || separator === argv.length - 1) {
    throw new Error("Command must be provided after --");
  }
  const optionArgs = argv.slice(0, separator);
  const commandArgs = argv.slice(separator + 1);

  for (let index = 0; index < optionArgs.length; index += 1) {
    const arg = optionArgs[index];
    if (arg === "--check" && optionArgs[index + 1]) {
      checks.push(optionArgs[index + 1]);
      index += 1;
    } else if (arg === "--check-docker") {
      checks.push("docker");
    } else if (arg === "--cwd" && optionArgs[index + 1]) {
      cwd = resolveWorkspaceCwd(optionArgs[index + 1]);
      index += 1;
    } else {
      throw new Error(`Unknown client runner option: ${arg}`);
    }
  }

  return {
    checks,
    cwd,
    command: commandArgs[0],
    args: commandArgs.slice(1)
  };
}

export function resolveWorkspaceCwd(value) {
  const resolved = path.resolve(ROOT, value);
  if (resolved !== ROOT && !resolved.startsWith(`${ROOT}${path.sep}`)) {
    throw new Error(`Client runner cwd escapes workspace: ${value}`);
  }
  return resolved;
}
