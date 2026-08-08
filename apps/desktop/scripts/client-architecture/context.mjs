import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import {
  collectEnumValues,
  collectRustPubMods,
  createFailureCollector,
  lineNumberForToken,
  moduleSupportsPlatform,
  sameSet,
} from "./assertions.mjs";
import { createArchitectureFilesystem } from "./filesystem.mjs";

export function createArchitectureContext({ repoRoot, spawn = spawnSync }) {
  const failureCollector = createFailureCollector();
  const filesystem = createArchitectureFilesystem({
    repoRoot,
    fail: failureCollector.fail,
  });

  function runJson(command, args) {
    const result = spawn(command, args, {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 20 * 1024 * 1024,
    });
    const commandLabel = path.basename(command);
    if (result.status !== 0) {
      failureCollector.fail(`${commandLabel} subprocess failed`);
      return null;
    }
    try {
      return JSON.parse(result.stdout);
    } catch {
      failureCollector.fail(`${commandLabel} subprocess did not return JSON`);
      return null;
    }
  }

  return {
    ...failureCollector,
    ...filesystem,
    collectEnumValues,
    collectRustPubMods,
    lineNumberForToken,
    moduleSupportsPlatform,
    repoRoot,
    runJson,
    sameSet,
  };
}

export function formatArchitectureResult({
  failures,
  futureModules,
  packagedTargets,
  packagePlanCheckedPlatforms,
}) {
  if (failures.length > 0) {
    return {
      ok: false,
      text: JSON.stringify({ ok: false, failures }, null, 2),
    };
  }
  return {
    ok: true,
    text: JSON.stringify({
      ok: true,
      futureModules,
      packagedTargets,
      packagePlanCheckedPlatforms,
    }, null, 2),
  };
}

export function emitArchitectureResult(result, {
  stdout = console.log,
  stderr = console.error,
  exit = (code) => process.exit(code),
} = {}) {
  if (!result.ok) {
    stderr(result.text);
    exit(1);
    return;
  }
  stdout(result.text);
}
