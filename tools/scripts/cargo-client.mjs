#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { sanitizeError } from "./lib/sanitize-error.mjs";
import {
  acquireTestArtifactLease,
  NATIVE_CARGO_TEST_TARGET,
} from "./lib/test-artifact-lifecycle.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const args = process.argv.slice(2);

for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "--output-path" && args[index + 1]) {
    mkdirSync(path.dirname(path.resolve(repoRoot, args[index + 1])), { recursive: true });
  }
}

if (args.includes("llvm-cov")) {
  mkdirSync(path.join(repoRoot, "build", "coverage", "crates", "lico-client-native"), { recursive: true });
}

const lease = acquireTestArtifactLease({
  repoRoot,
  scope: "cargo-client",
  targetPath: NATIVE_CARGO_TEST_TARGET,
});
const targetDir = lease.targetPath;
let leaseReleased = false;

function releaseLease() {
  if (leaseReleased) return;
  lease.release();
  leaseReleased = true;
}

let child;
try {
  child = spawn("cargo", args, {
    cwd: repoRoot,
    env: {
      ...process.env,
      CARGO_TARGET_DIR: targetDir,
    },
    stdio: "inherit",
    windowsHide: true,
  });
} catch (error) {
  releaseLease();
  throw error;
}

child.once("error", (error) => {
  releaseLease();
  process.stderr.write(`${sanitizeError(error)}\n`);
  process.exitCode = 1;
});

child.once("exit", (code, signal) => {
  releaseLease();
  if (signal) {
    console.error(`cargo terminated by ${signal}`);
    process.exitCode = 1;
    return;
  }
  process.exitCode = code ?? 1;
});
