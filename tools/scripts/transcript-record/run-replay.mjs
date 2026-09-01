#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

const repositoryRoot = resolve(import.meta.dirname, "../../..");
const corpusRoot = resolve(repositoryRoot, "tests/replay-corpus");

// The replay corpus is developer-local (ingested from local machine history
// and never committed to the remote repository). When it is absent — fresh
// clones, CI — report a local-only skip instead of failing.
if (!existsSync(corpusRoot)) {
  process.stdout.write(
    `${JSON.stringify({ ok: true, skipped: true, reason: "replay corpus is developer-local and absent on this machine" })}\n`,
  );
  process.exit(0);
}

const commands = [
  [process.execPath, [resolve(import.meta.dirname, "verify-redaction.mjs")]],
  [process.execPath, [resolve(import.meta.dirname, "self-test.mjs")]],
  [process.execPath, [resolve(repositoryRoot, "tools/scripts/cargo-client.mjs"), "test", "--manifest-path", "crates/licoup-native/Cargo.toml", "adapter_replay"]],
];
for (const [command, args] of commands) {
  const result = spawnSync(command, args, { cwd: repositoryRoot, stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status || 1);
}
