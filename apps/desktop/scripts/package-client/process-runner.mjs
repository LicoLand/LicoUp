import { execFileSync } from "node:child_process";
import process from "node:process";

import {
  packageClientRuntime,
  packageFailure,
} from "./cli-policy.mjs";

export function runPackageProcess(command, args, options = {}) {
  const {
    failureCode = "package_subprocess_failed",
    stage = "subprocess",
    ...executionOptions
  } = options;
  try {
    invoke(command, args, executionOptions);
  } catch {
    packageFailure(failureCode, { stage: publicProcessStage(stage) });
  }
}

export function capturePackageProcess(command, args, options = {}) {
  const {
    failureCode = "package_subprocess_failed",
    stage = "subprocess",
    ...executionOptions
  } = options;
  try {
    return String(
      invoke(command, args, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        ...executionOptions,
      }) || "",
    );
  } catch {
    packageFailure(failureCode, { stage: publicProcessStage(stage) });
  }
}

export function bestEffortPackageProcess(command, args, options = {}) {
  try {
    invoke(command, args, options);
    return true;
  } catch {
    return false;
  }
}

export function bestEffortPackageCapture(command, args, options = {}) {
  try {
    return String(
      invoke(command, args, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        ...options,
      }) || "",
    );
  } catch {
    return "";
  }
}

export function runFlutterProcess(args, options = {}) {
  runPackageProcess(flutterCommand(), args, options);
}

export function flutterCommand() {
  return process.platform === "win32" ? "flutter.bat" : "flutter";
}

function invoke(command, args, executionOptions) {
  if (process.platform === "win32" && /\.(?:bat|cmd)$/iu.test(command)) {
    const commandLine = ["call", command, ...args]
      .map(quoteWindowsCommandArg)
      .join(" ");
    return execFileSync(
      process.env.ComSpec || "cmd.exe",
      ["/d", "/s", "/c", commandLine],
      {
        cwd: packageClientRuntime.workspaceRoot,
        stdio: "pipe",
        windowsHide: true,
        ...executionOptions,
      },
    );
  }
  return execFileSync(command, args, {
    cwd: packageClientRuntime.workspaceRoot,
    stdio: "pipe",
    ...executionOptions,
  });
}

function quoteWindowsCommandArg(value) {
  const text = String(value);
  if (text.length === 0) return '""';
  if (!/[\s"&()^|<>]/u.test(text)) return text;
  return `"${text.replaceAll('"', '""')}"`;
}

function publicProcessStage(value) {
  const normalized = String(value || "subprocess")
    .trim()
    .toLowerCase();
  return /^[a-z0-9]+(?:[._-][a-z0-9]+)*$/u.test(normalized)
    ? normalized
    : "subprocess";
}
