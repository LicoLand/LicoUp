#!/usr/bin/env node

import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const strategyPath = path.join(repoRoot, "tools/client-remote-release-strategies.json");

function fail(code) {
  throw Object.assign(new Error(code), { code });
}

export function validateRemoteReleaseStrategies(value) {
  if (value?.schemaVersion !== "licoup.client-remote-release-strategies.v1" ||
      value?.groupId !== "client-remote-release-validity" ||
      JSON.stringify(value?.activeStrategyIds) !== JSON.stringify(["build-success"]) ||
      !Array.isArray(value?.strategies) || value.strategies.length !== 1) {
    fail("remote_release_strategy_group_invalid");
  }
  const strategy = value.strategies[0];
  if (strategy?.id !== "build-success" ||
      strategy?.releaseValidWhen !== "selected-target-build-command-succeeded" ||
      !Array.isArray(strategy?.remoteValidationCommands) ||
      strategy.remoteValidationCommands.length !== 0) {
    fail("remote_release_build_success_strategy_invalid");
  }
  return strategy.id;
}

function expectedStrategy(argv) {
  if (argv.length !== 2 || argv[0] !== "--expect" ||
      !/^[a-z0-9-]{1,64}$/u.test(argv[1])) {
    fail("remote_release_strategy_argument_invalid");
  }
  return argv[1];
}

try {
  const expected = expectedStrategy(process.argv.slice(2));
  const configured = validateRemoteReleaseStrategies(
    JSON.parse(readFileSync(strategyPath, "utf8")),
  );
  if (configured !== expected) fail("remote_release_strategy_mismatch");
  process.stdout.write(`remote_release_strategy=${configured} result=accepted\n`);
} catch (error) {
  process.stderr.write(`LicoUp remote release strategy: ${error?.code || "remote_release_strategy_failed"}\n`);
  process.exitCode = 1;
}
