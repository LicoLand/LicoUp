#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const supportedPlatforms = new Set(["android", "linux", "macos", "windows"]);
const supportedModes = new Set(["debug", "profile", "release"]);

export class ClientBuildError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function fail(code) {
  throw new ClientBuildError(code);
}

export function parseClientBuildArgs(argv = process.argv.slice(2)) {
  const options = {
    mode: "release",
    passthrough: [],
    platform: "",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--platform") {
      if (!next || next.startsWith("--") || options.platform) {
        fail("client_build_platform_invalid");
      }
      options.platform = String(next).toLowerCase();
      index += 1;
    } else if (arg === "--mode") {
      if (!next || next.startsWith("--")) fail("client_build_mode_invalid");
      options.mode = String(next).toLowerCase();
      index += 1;
    } else {
      options.passthrough.push(arg);
    }
  }
  if (!supportedPlatforms.has(options.platform)) {
    fail("client_build_platform_invalid");
  }
  if (!supportedModes.has(options.mode)) fail("client_build_mode_invalid");
  return Object.freeze({
    ...options,
    passthrough: Object.freeze([...options.passthrough]),
  });
}

export function clientBuildInvocation(options) {
  if (options.platform === "android") {
    return Object.freeze({
      args: Object.freeze([
        path.join("apps", "desktop", "scripts", "build-android-apk.mjs"),
        `--${options.mode}`,
        ...options.passthrough,
      ]),
      command: process.execPath,
    });
  }
  return Object.freeze({
    args: Object.freeze([
      path.join("apps", "desktop", "scripts", "package-client.mjs"),
      "--platform",
      options.platform,
      "--mode",
      options.mode,
      ...options.passthrough,
    ]),
    command: process.execPath,
  });
}

export function runClientBuild(
  options,
  {
    root = repoRoot,
    spawnBuild = spawnSync,
  } = {},
) {
  const invocation = clientBuildInvocation(options);
  let execution = null;
  try {
    execution = spawnBuild(invocation.command, invocation.args, {
      cwd: root,
      env: process.env,
      stdio: "inherit",
      windowsHide: true,
    });
  } catch {
    execution = { error: true, status: null };
  }

  const buildSucceeded =
    execution?.status === 0 && !execution?.error && !execution?.signal;
  return Object.freeze({
    ok: buildSucceeded,
    platform: options.platform,
    mode: options.mode,
    buildSucceeded,
    privatePathsIncluded: false,
  });
}

export function publicClientBuildFailure(error) {
  return Object.freeze({
    ok: false,
    reason:
      error instanceof ClientBuildError
        ? error.code
        : "client_build_entry_failed",
    privatePathsIncluded: false,
  });
}

function main() {
  const result = runClientBuild(parseClientBuildArgs());
  const output = `${JSON.stringify(result)}\n`;
  if (result.ok) process.stdout.write(output);
  else {
    process.stderr.write(output);
    process.exitCode = 1;
  }
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || "")) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${JSON.stringify(publicClientBuildFailure(error))}\n`);
    process.exitCode = 1;
  }
}
