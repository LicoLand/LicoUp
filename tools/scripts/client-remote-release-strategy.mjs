#!/usr/bin/env node

import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

export function validateRemoteReleaseStrategies(value) {
  const strategy = value?.strategies?.[0];
  if (value?.schemaVersion !== "licoup.client-remote-release-strategies.v1" ||
    value?.groupId !== "client-remote-release-validity" ||
    JSON.stringify(value?.activeStrategyIds) !== JSON.stringify(["build-success"]) ||
    value?.strategies?.length !== 1 || strategy?.id !== "build-success" ||
    strategy?.releaseValidWhen !== "selected-target-build-command-succeeded" ||
    JSON.stringify(strategy?.remoteValidationCommands) !== "[]") {
    throw new Error("remote_release_strategy_group_invalid");
  }
  return strategy.id;
}

const argv = process.argv.slice(2);
try {
  if (argv.length !== 2 || argv[0] !== "--expect") {
    throw new Error("remote_release_strategy_argument_invalid");
  }
  const configured = validateRemoteReleaseStrategies(JSON.parse(readFileSync(
    path.join(repoRoot, "tools/client-remote-release-strategies.json"), "utf8")));
  if (configured !== argv[1]) throw new Error("remote_release_strategy_mismatch");
  process.stdout.write(`remote_release_strategy=${configured} result=accepted\n`);
} catch (error) {
  process.stderr.write(`LicoUp remote release strategy: ${error.message}\n`);
  process.exitCode = 1;
}
