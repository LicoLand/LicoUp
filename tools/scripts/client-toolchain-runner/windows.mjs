import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";

import { ROOT } from "./constants.mjs";

export function quoteWindowsCommandArg(value) {
  const text = String(value);
  if (text.length === 0) {
    return '""';
  }
  if (!/[\s"&()^|<>]/.test(text)) {
    return text;
  }
  return `"${text.replaceAll('"', '""')}"`;
}

export function commandHasPathSeparator(command, platform = process.platform) {
  return command.includes(path.sep) || (platform === "win32" && command.includes("/"));
}

export function windowsCommandCandidateRank(candidate) {
  const extension = path.extname(candidate).toLowerCase();
  if (extension === ".exe" || extension === ".com") return 0;
  if (extension === ".cmd" || extension === ".bat") return 1;
  if (extension) return 20;
  return 100;
}

export function resolveWindowsPathCommand(command, fileExists = existsSync) {
  const extension = path.extname(command);
  const candidates = extension
    ? [command]
    : [
        `${command}.exe`,
        `${command}.com`,
        `${command}.cmd`,
        `${command}.bat`,
        command
      ];
  return candidates.find((candidate) => fileExists(candidate)) || command;
}

export function resolveCommand(command, {
  platform = process.platform,
  fileExists = existsSync,
  locate = spawnSync,
} = {}) {
  if (platform !== "win32") {
    return command;
  }
  if (commandHasPathSeparator(command, platform)) {
    return resolveWindowsPathCommand(command, fileExists);
  }
  const result = locate("where.exe", [command], {
    cwd: ROOT,
    encoding: "utf8",
    windowsHide: true
  });
  if (result.status !== 0) {
    return command;
  }
  const candidates = String(result.stdout || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  return candidates.sort((a, b) => windowsCommandCandidateRank(a) - windowsCommandCandidateRank(b))[0] || command;
}
