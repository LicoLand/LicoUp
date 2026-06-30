#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const args = process.argv.slice(2);
const targetDir = path.join(repoRoot, "build", "crates", "lico-client-native", "target");

for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "--output-path" && args[index + 1]) {
    mkdirSync(path.dirname(path.resolve(repoRoot, args[index + 1])), { recursive: true });
  }
}

if (args.includes("llvm-cov")) {
  mkdirSync(path.join(repoRoot, "build", "coverage", "crates", "lico-client-native"), { recursive: true });
}

const child = spawn("cargo", args, {
  cwd: repoRoot,
  env: {
    ...process.env,
    CARGO_TARGET_DIR: targetDir
  },
  stdio: "inherit",
  windowsHide: true
});

child.once("error", (error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});

child.once("exit", (code, signal) => {
  if (signal) {
    console.error(`cargo terminated by ${signal}`);
    process.exitCode = 1;
    return;
  }
  process.exitCode = code ?? 1;
});
