import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import process from "node:process";
import { withClientToolchainEnv } from "../client-toolchain-env.mjs";
import { ROOT } from "./constants.mjs";
import { quoteWindowsCommandArg, resolveCommand } from "./windows.mjs";

export function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const resolvedCommand = resolveCommand(command);
    const env = options.env || process.env;
    const isWindowsScript = process.platform === "win32" && /\.(?:cmd|bat)$/i.test(resolvedCommand);
    const capturesOutput = typeof options.onStdout === "function" ||
      typeof options.onStderr === "function";
    const stdio = options.stdio || (capturesOutput
      ? ["ignore", "pipe", "pipe"]
      : "inherit");
    const child = isWindowsScript ? spawn(
      process.env.ComSpec || "cmd.exe",
      ["/d", "/s", "/c", ["call", resolvedCommand, ...args].map(quoteWindowsCommandArg).join(" ")],
      {
        cwd: options.cwd || ROOT,
        stdio,
        env,
        windowsHide: true
      }
    ) : spawn(resolvedCommand, args, {
      cwd: options.cwd || ROOT,
      stdio,
      shell: false,
      env,
      windowsHide: true
    });
    if (child.stdout) {
      if (typeof options.onStdout === "function") child.stdout.on("data", options.onStdout);
      else child.stdout.resume();
    }
    if (child.stderr) {
      if (typeof options.onStderr === "function") child.stderr.on("data", options.onStderr);
      else child.stderr.resume();
    }
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${command} ${args.join(" ")} exited with code ${code}`));
      }
    });
    child.on("error", reject);
  });
}

export async function toolExists(command) {
  try {
    if (process.platform === "win32") {
      const resolvedCommand = resolveCommand(command);
      return resolvedCommand !== command || existsSync(resolvedCommand);
    }
    await run("which", [command], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

export async function dockerAvailable() {
  try {
    await run("docker", ["info"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

export async function verifyToolchain(checks) {
  for (const check of checks) {
    if (check === "cargo" && !(await toolExists("cargo"))) {
      throw new Error("Cargo not found");
    }
    if (check === "flutter" && !(await toolExists("flutter"))) {
      throw new Error("Flutter not found");
    }
    if (check === "docker" && !(await dockerAvailable())) {
      throw new Error("Docker not available");
    }
    if (!["cargo", "flutter", "docker"].includes(check)) {
      throw new Error(`Unknown toolchain check: ${check}`);
    }
  }
}
