#!/usr/bin/env node

import process from "node:process";
import { spawnSync } from "node:child_process";

const maximumOutputBytes = 16 * 1024 * 1024;

function run(command, args, timeout) {
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    env: process.env,
    stdio: "inherit",
    maxBuffer: maximumOutputBytes,
    timeout,
  });
  if (result.status !== 0) {
    throw new Error("macos_install_command_failed");
  }
}

function main() {
  if (process.platform !== "darwin") {
    throw new Error("macos_install_requires_macos");
  }
  const explicitIdentity = String(
    process.env.LICO_MACOS_RELEASE_SIGNING_IDENTITY || "",
  ).trim();
  if (explicitIdentity) {
    run("npm", ["run", "client:build:macos"], 12 * 60_000);
    run(
      process.execPath,
      ["tools/scripts/client-macos-local-identity-install.mjs"],
      12 * 60_000,
    );
    return;
  }
  run(
    process.execPath,
    [
      "apps/desktop/scripts/package-client.mjs",
      "--platform",
      "macos",
      "--mode",
      "release",
      "--install",
    ],
    12 * 60_000,
  );
}

try {
  main();
} catch (error) {
  const stage = error instanceof Error && /^macos_[a-z0-9_]+$/u.test(error.message)
    ? error.message
    : "macos_install_failed";
  console.error(JSON.stringify({
    ok: false,
    reason: "macos_install_failed",
    stage,
    privatePathsIncluded: false,
  }));
  process.exitCode = 1;
}
