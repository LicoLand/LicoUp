#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  createReleaseClosureChallenge,
  createReleaseInvocationNonce,
  releaseClosureEnvironment,
  releaseInvocationEnvironment,
} from "../../../tools/scripts/lib/release-closure-challenge.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

function main() {
  if (process.argv.length !== 2) {
    throw new Error("canonical Android install wrapper does not accept artifact overrides");
  }
  const challenge = createReleaseClosureChallenge();
  const invocationNonce = createReleaseInvocationNonce();
  const result = spawnSync(process.execPath, [
    "tools/scripts/client-android-physical-install-launch.mjs",
    "--install",
    "--launch",
    "--apk",
    "build/apps/desktop/android/release/app-release.apk",
    "--package",
    "land.lico.licoup",
  ], {
    cwd: workspaceRoot,
    env: {
      ...process.env,
      ...releaseClosureEnvironment(challenge, new Date()),
      ...releaseInvocationEnvironment(invocationNonce),
    },
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 16 * 1024 * 1024,
    timeout: 600_000,
  });
  if (result.status !== 0) throw new Error("canonical Android install verifier failed");
  console.log(JSON.stringify({
    ok: true,
    targetId: "android-arm64",
    installReceiptReady: true,
    privatePathsIncluded: false,
  }));
}

try {
  main();
} catch {
  console.error(JSON.stringify({
    ok: false,
    reason: "android_install_failed",
    privatePathsIncluded: false,
  }));
  process.exitCode = 1;
}
