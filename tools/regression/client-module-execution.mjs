import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import {
  acquireTestArtifactLease,
  NATIVE_CARGO_TEST_TARGET,
} from "../scripts/lib/test-artifact-lifecycle.mjs";

function containedWorkingDirectory(repoRoot, relativeCwd) {
  const root = path.resolve(repoRoot);
  const candidate = path.resolve(root, relativeCwd);
  const relative = path.relative(root, candidate);
  if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error("module working directory escapes the repository");
  }
  return candidate;
}

export function executeClientModules(modules, {
  repoRoot,
  leaseFactory = acquireTestArtifactLease,
  spawnSyncImpl = spawnSync,
  output = process.stdout,
} = {}) {
  if (!Array.isArray(modules)) throw new Error("client modules must be an array");
  const completed = [];
  for (const module of modules) {
    output.write(`[client-regression] ${module.id}\n`);
    const { program, args, cwd, timeoutMs } = module.command;
    const executable = program === "node" ? process.execPath : program;
    const lease = program === "cargo"
      ? leaseFactory({
        repoRoot,
        scope: module.id,
        targetPath: NATIVE_CARGO_TEST_TARGET,
      })
      : null;
    let result;
    try {
      result = spawnSyncImpl(executable, [...args], {
        cwd: containedWorkingDirectory(repoRoot, cwd),
        encoding: "utf8",
        env: lease
          ? { ...process.env, CARGO_TARGET_DIR: lease.targetPath }
          : process.env,
        maxBuffer: 64 * 1024 * 1024,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
        timeout: timeoutMs,
      });
    } finally {
      lease?.release();
    }
    if (result.error || result.status !== 0) {
      output.write(`[client-regression] ${module.id} failed\n`);
      return Object.freeze({
        ok: false,
        completed: Object.freeze(completed),
        failedModuleId: module.id,
        exitCode: Number.isInteger(result.status) && result.status > 0 ? result.status : 1,
      });
    }
    completed.push(module.id);
    output.write(`[client-regression] ${module.id} ok\n`);
  }
  return Object.freeze({
    ok: true,
    completed: Object.freeze(completed),
    failedModuleId: null,
    exitCode: 0,
  });
}
