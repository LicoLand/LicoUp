#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { resolve } from "node:path";

const repositoryRoot = resolve(import.meta.dirname, "../../..");
const corpusRoot = resolve(repositoryRoot, "tests/replay-corpus");
const syntheticRoot = resolve(repositoryRoot, "tests/fixtures/adapter-replay");
const directoryExists = (path) => existsSync(path) && statSync(path).isDirectory();

let activeFixtureRoot = null;
let source = null;
if (directoryExists(corpusRoot)) {
  activeFixtureRoot = corpusRoot;
  source = "developer-corpus";
} else if (directoryExists(syntheticRoot)) {
  activeFixtureRoot = syntheticRoot;
  source = "synthetic-fixtures";
}

if (!activeFixtureRoot) {
  process.stderr.write(
    `${JSON.stringify({
      ok: false,
      executed: false,
      status: "not_executed",
      reason: "neither replay corpus nor synthetic fixtures available; missing replay transcript cannot be reported as passed",
    })}\n`,
  );
  process.exit(1);
}

const commands = [
  [process.execPath, [resolve(import.meta.dirname, "verify-redaction.mjs"), activeFixtureRoot]],
  [process.execPath, [resolve(import.meta.dirname, "self-test.mjs")]],
  [process.execPath, [resolve(repositoryRoot, "tools/scripts/cargo-client.mjs"), "test", "--manifest-path", "crates/licoup-native/Cargo.toml", "--test", "adapter_replay"]],
];
for (const [command, args] of commands) {
  const result = spawnSync(command, args, { cwd: repositoryRoot, stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status || 1);
}

process.stdout.write(
  `${JSON.stringify({ ok: true, executed: true, status: "passed", source })}\n`,
);
