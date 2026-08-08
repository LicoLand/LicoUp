#!/usr/bin/env node
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  pruneReclaimableTestArtifacts,
  testArtifactStatus,
} from "./lib/test-artifact-lifecycle.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const [command, ...args] = process.argv.slice(2);

function usage() {
  process.stderr.write(
    "Usage: client-test-artifacts.mjs status | prune [--dry-run]\n",
  );
}

if (command === "status" && args.length === 0) {
  process.stdout.write(`${JSON.stringify({
    ok: true,
    operation: "status",
    ...testArtifactStatus({ repoRoot }),
  })}\n`);
} else if (
  command === "prune" &&
  (args.length === 0 || (args.length === 1 && args[0] === "--dry-run"))
) {
  const dryRun = args[0] === "--dry-run";
  const result = pruneReclaimableTestArtifacts({ repoRoot, dryRun });
  process.stdout.write(`${JSON.stringify({
    ok: result.failed === 0,
    operation: dryRun ? "prune-dry-run" : "prune",
    ...result,
  })}\n`);
  if (result.failed > 0) process.exitCode = 1;
} else {
  usage();
  process.exitCode = 2;
}
