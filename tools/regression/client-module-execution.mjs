import { spawn } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { planClientRegressionBatches } from "./client-regression-batching.mjs";
import {
  CLIENT_REGRESSION_STAGES,
  defaultRegressionCapacities,
} from "./client-regression-metadata.mjs";
import { defaultProcessTreeMetricsAdapter } from "./client-regression-metrics.mjs";
import {
  createFlutterJsonStatsCollector,
  decorateFlutterTestCommand,
} from "./client-regression-toolchain-stats/flutter.mjs";
import {
  collectRustToolchainNativeMetrics,
  decorateRustToolchainCommand,
  isRustToolchainCommand,
} from "./client-regression-toolchain-stats/rust.mjs";
import {
  createClientRegressionReport,
  writeClientRegressionReport,
} from "./client-regression-report.mjs";
import {
  acquireTestArtifactLease,
  NATIVE_CARGO_TEST_TARGET,
} from "../scripts/lib/test-artifact-lifecycle.mjs";

const NODE_TEST_ATTRIBUTION_REPORTER = "tools/regression/client-node-test-attribution-reporter.mjs";
const NODE_TEST_INPUTS_ENV = "LICO_CLIENT_NODE_TEST_INPUTS";
const NODE_TEST_ATTRIBUTION_SCHEMA = "licoup.node-test-attribution.v1";

function containedWorkingDirectory(repoRoot, relativeCwd) {
  const root = path.resolve(repoRoot);
  const candidate = path.resolve(root, relativeCwd);
  const relative = path.relative(root, candidate);
  if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error("module working directory escapes the repository");
  }
  return candidate;
}

function monotonicMilliseconds(started) {
  return Number(process.hrtime.bigint() - started) / 1_000_000;
}

function measured(value, source) {
  return Object.freeze({ status: "measured", value, source });
}

function createTailCollector(limit = 4 * 1024 * 1024) {
  let tail = "";
  return Object.freeze({
    push(chunk) {
      tail = `${tail}${Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk ?? "")}`;
      if (tail.length > limit) tail = tail.slice(-limit);
    },
    finish() {
      const output = tail;
      tail = "";
      return output;
    },
  });
}

function createSafeReceiptCollector(limit = 1024 * 1024) {
  const output = createTailCollector(limit);
  return Object.freeze({
    push: output.push,
    finish() {
      const lines = output.finish().split(/\r?\n/u).reverse();
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) continue;
        try {
          const receipt = JSON.parse(trimmed);
          for (const key of ["reasonCode", "errorCode", "reason"]) {
            const value = receipt?.[key];
            if (/^[a-z0-9_.:+-]{1,160}$/u.test(value || "")) return value;
          }
        } catch {
          // Compatibility commands may emit private diagnostic text before
          // their bounded receipt. Only the final allowlisted code is kept.
        }
      }
      return null;
    },
  });
}

function createNodeTestAttributionCollector(batch, inputCount) {
  const output = createTailCollector(1024 * 1024);
  return Object.freeze({
    push: output.push,
    finish() {
      for (const line of output.finish().split(/\r?\n/u).reverse()) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) continue;
        try {
          const receipt = JSON.parse(trimmed);
          const indexes = receipt?.failedInputIndexes;
          if (receipt?.schemaVersion !== NODE_TEST_ATTRIBUTION_SCHEMA ||
              receipt?.complete !== true || receipt?.inputCount !== inputCount ||
              !Array.isArray(indexes) || !indexes.every((index) =>
                Number.isInteger(index) && index >= 0 && index < inputCount)) {
            continue;
          }
          const failedIndexes = new Set(indexes);
          const failedMembers = batch.inputOwners
            .filter((owner) => owner.indexes.some((index) => failedIndexes.has(index)))
            .map((owner) => owner.member);
          return Object.freeze({
            attributionComplete: true,
            failedMembers: Object.freeze([...new Set(failedMembers)]),
          });
        } catch {
          // Only the numeric reporter receipt is accepted as attribution.
        }
      }
      return Object.freeze({
        attributionComplete: false,
        failedMembers: Object.freeze([]),
      });
    },
  });
}

function nodeTestInputs(command) {
  if (command.program !== "node" || command.args[0] !== "--test") return [];
  return command.args.slice(1).filter((argument) => !argument.startsWith("-"));
}

function relativeReporterPath(repoRoot, commandCwd) {
  const workingDirectory = path.resolve(repoRoot, commandCwd);
  const reporter = path.relative(
    workingDirectory,
    path.resolve(repoRoot, NODE_TEST_ATTRIBUTION_REPORTER),
  );
  const normalized = reporter.replaceAll("\\", "/");
  return normalized.startsWith(".") ? normalized : `./${normalized}`;
}

function prepareToolchainCommand(batch, { repoRoot }) {
  if (isRustToolchainCommand(batch.command)) {
    const stdout = createTailCollector(2 * 1024 * 1024);
    const stderr = createTailCollector(2 * 1024 * 1024);
    const decorated = decorateRustToolchainCommand(batch.command, {
      cargoJobs: batch.internalConcurrency,
      libtestThreads: batch.internalConcurrency,
    });
    return Object.freeze({
      command: decorated.command,
      pushStdout: stdout.push,
      pushStderr: stderr.push,
      finish(exitCode) {
        return Object.freeze({
          kind: "rust",
          metrics: collectRustToolchainNativeMetrics({
            output: `${stdout.finish()}\n${stderr.finish()}`,
            exitCode,
            instrumentation: decorated.instrumentation,
          }),
        });
      },
    });
  }
  const decorated = decorateFlutterTestCommand(batch.command, {
    concurrency: batch.internalConcurrency || batch.weight,
  });
  if (decorated.supported) {
    const collector = createFlutterJsonStatsCollector();
    return Object.freeze({
      command: decorated.command,
      pushStdout: collector.push,
      // The JSON reporter is a stdout protocol. Keeping stderr separate
      // prevents wrapper chatter from corrupting a partial JSON line.
      pushStderr() {},
      finish() {
        return Object.freeze({ kind: "flutter", metrics: collector.finish() });
      },
    });
  }
  if (batch.toolchain === "node-test" && batch.members.length > 1 && batch.inputOwners) {
    const inputs = nodeTestInputs(batch.command);
    const collector = createNodeTestAttributionCollector(batch, inputs.length);
    const reporter = relativeReporterPath(repoRoot, batch.command.cwd);
    return Object.freeze({
      command: Object.freeze({
        ...batch.command,
        args: Object.freeze([
          "--test",
          `--test-reporter=${reporter}`,
          ...batch.command.args.slice(1),
        ]),
      }),
      environment: Object.freeze({
        [NODE_TEST_INPUTS_ENV]: JSON.stringify(inputs),
      }),
      pushStdout: collector.push,
      pushStderr() {},
      finish() {
        return Object.freeze({
          kind: "node-test",
          metrics: null,
          ...collector.finish(),
        });
      },
    });
  }
  if (batch.toolchain === "compatibility") {
    const receipt = createSafeReceiptCollector();
    return Object.freeze({
      command: batch.command,
      pushStdout: receipt.push,
      pushStderr() {},
      finish() {
        return Object.freeze({
          kind: "compatibility",
          metrics: null,
          failureReason: receipt.finish(),
        });
      },
    });
  }
  return Object.freeze({
    command: batch.command,
    pushStdout() {},
    pushStderr() {},
    finish() { return null; },
  });
}

function metricFrom(processTree, toolchain, key) {
  const processMetric = processTree?.[key];
  if (processMetric?.status === "measured") return processMetric;
  return toolchain?.metrics?.[key] || processMetric;
}

function commandMetrics({ durationMs, processTree, toolchain, toolchainId }) {
  const nativeMetrics = toolchain?.metrics || null;
  const nativeSummary = nativeMetrics
    ? Object.freeze(Object.fromEntries(Object.entries(nativeMetrics)
      .filter(([key]) => !["directCpuMs", "descendantCpuMs", "peakResidentBytes"].includes(key))))
    : Object.freeze({
      status: "unavailable",
      reason: "toolchain_native_metrics_unavailable",
    });
  return Object.freeze({
    wallTimeMs: measured(durationMs, "monotonic_clock"),
    directCpuMs: metricFrom(processTree, toolchain, "directCpuMs"),
    descendantCpuMs: metricFrom(processTree, toolchain, "descendantCpuMs"),
    peakResidentBytes: metricFrom(processTree, toolchain, "peakResidentBytes"),
    toolchainNative: Object.freeze({
      kind: toolchain?.kind || toolchainId,
      ...nativeSummary,
    }),
  });
}

export async function runClientRegressionCommand(batch, {
  repoRoot,
  leaseFactory = acquireTestArtifactLease,
  spawnImpl = spawn,
  metricsAdapter = defaultProcessTreeMetricsAdapter(),
} = {}) {
  const prepared = prepareToolchainCommand(batch, { repoRoot });
  const { program, args, cwd, timeoutMs } = prepared.command;
  const executable = program === "node" ? process.execPath : program;
  const lease = program === "cargo"
    ? leaseFactory({ repoRoot, scope: batch.id, targetPath: NATIVE_CARGO_TEST_TARGET })
    : null;
  const started = process.hrtime.bigint();
  let reason = null;
  let status = "passed";
  let exitCode = null;
  let childPid = null;
  try {
    await new Promise((resolve) => {
      let settled = false;
      let timer = null;
      const finish = (nextStatus, nextReason) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        status = nextStatus;
        reason = nextReason;
        resolve();
      };
      let child;
      try {
        child = spawnImpl(executable, [...args], {
          cwd: containedWorkingDirectory(repoRoot, cwd),
          env: {
            ...process.env,
            ...prepared.environment,
            ...(lease ? { CARGO_TARGET_DIR: lease.targetPath } : {}),
          },
          shell: false,
          stdio: ["ignore", "pipe", "pipe"],
          windowsHide: true,
        });
        childPid = Number.isInteger(child.pid) ? child.pid : null;
      } catch {
        finish("failed", "process_start_failed");
        return;
      }
      child.stdout?.on?.("data", prepared.pushStdout);
      child.stderr?.on?.("data", prepared.pushStderr);
      child.once?.("error", () => finish("failed", "process_start_failed"));
      child.once?.("close", (code, signal) => {
        exitCode = Number.isInteger(code) ? code : null;
        if (code === 0) finish("passed", null);
        else finish("failed", signal ? "command_signaled" : "command_failed");
      });
      timer = setTimeout(() => {
        child.kill?.("SIGTERM");
        finish("failed", "command_timeout");
      }, timeoutMs);
      timer.unref?.();
    });
    const durationMs = Math.round(monotonicMilliseconds(started));
    const processTree = await metricsAdapter.measure({
      batchId: batch.id,
      childPid,
      exitCode,
    });
    const toolchain = prepared.finish(exitCode);
    if (status === "failed" && toolchain?.failureReason) {
      reason = toolchain.failureReason;
    }
    const metrics = commandMetrics({
      durationMs,
      processTree,
      toolchain,
      toolchainId: batch.toolchain,
    });
    const attributedMembers = status === "failed" &&
      toolchain?.attributionComplete === true &&
      toolchain.failedMembers.length > 0
      ? toolchain.failedMembers
      : null;
    return Object.freeze({
      id: batch.id,
      stage: batch.stage,
      lane: batch.lane,
      toolchain: batch.toolchain,
      status: status === "failed" && batch.members.length > 1 && !attributedMembers
        ? "attribution-pending"
        : status,
      reason,
      durationMs,
      members: attributedMembers || batch.members,
      metrics,
    });
  } finally {
    lease?.release();
  }
}

function fits(batch, usage, capacities) {
  if (usage.global + batch.weight > capacities.global) return false;
  if ((usage.pools[batch.toolchain] || 0) + batch.weight > capacities.pools[batch.toolchain]) {
    return false;
  }
  return batch.resources.every((resource) =>
    (usage.resources[resource] || 0) + 1 <= (capacities.resources[resource] || 1));
}

function adjustUsage(batch, usage, direction) {
  usage.global += direction * batch.weight;
  usage.pools[batch.toolchain] = (usage.pools[batch.toolchain] || 0) + direction * batch.weight;
  for (const resource of batch.resources) {
    usage.resources[resource] = (usage.resources[resource] || 0) + direction;
  }
}

export async function executeClientRegressionBatches(batches, {
  capacities = defaultRegressionCapacities(),
  commandRunner,
} = {}) {
  const pending = [...batches];
  const running = new Map();
  const results = [];
  const usage = { global: 0, pools: {}, resources: {} };
  const peaks = { global: 0, processes: 0 };
  const poolPeaks = {};
  const start = (batch) => {
    adjustUsage(batch, usage, 1);
    peaks.global = Math.max(peaks.global, usage.global);
    peaks.processes = Math.max(peaks.processes, running.size + 1);
    poolPeaks[batch.toolchain] = Math.max(
      poolPeaks[batch.toolchain] || 0,
      usage.pools[batch.toolchain],
    );
    const promise = Promise.resolve(commandRunner(batch))
      .catch(async () => {
        const processTree = await defaultProcessTreeMetricsAdapter().measure();
        return Object.freeze({
          id: batch.id,
          stage: batch.stage,
          lane: batch.lane,
          toolchain: batch.toolchain,
          status: batch.members.length > 1 ? "attribution-pending" : "failed",
          reason: "command_runner_failed",
          durationMs: 0,
          members: batch.members,
          metrics: commandMetrics({
            durationMs: 0,
            processTree,
            toolchain: null,
            toolchainId: batch.toolchain,
          }),
        });
      })
      .then((result) => ({ batch, result }));
    running.set(batch.id, promise);
  };

  while (pending.length > 0 || running.size > 0) {
    for (let index = 0; index < pending.length;) {
      const batch = pending[index];
      if (!fits(batch, usage, capacities)) {
        index += 1;
        continue;
      }
      pending.splice(index, 1);
      start(batch);
    }
    if (running.size === 0) {
      if (pending.length > 0) throw new Error("client regression resource claim exceeds capacity");
      break;
    }
    const settled = await Promise.race(running.values());
    running.delete(settled.batch.id);
    adjustUsage(settled.batch, usage, -1);
    results.push(settled.result);
  }
  const order = new Map(batches.map((batch, index) => [batch.id, index]));
  results.sort((left, right) => order.get(left.id) - order.get(right.id));
  return Object.freeze({
    results: Object.freeze(results),
    concurrency: Object.freeze({
      maximumWeight: peaks.global,
      maximumProcesses: peaks.processes,
      poolPeaks: Object.freeze(poolPeaks),
    }),
  });
}

function resultsPassed(results) {
  return results.every((result) => result.status === "passed");
}

function blockedResults(batches, reason) {
  return batches.map((batch) => Object.freeze({
    id: batch.id,
    stage: batch.stage,
    lane: batch.lane,
    toolchain: batch.toolchain,
    status: "blocked",
    reason,
    durationMs: 0,
    members: batch.members,
    metrics: Object.freeze({}),
  }));
}

export async function executeClientModules(modules, {
  repoRoot,
  catalog = modules,
  capacities = defaultRegressionCapacities(),
  commandRunner,
  output = process.stdout,
  reportPath = null,
  runKind = "complete",
  compatibilityRunner = async () => [],
} = {}) {
  if (!Array.isArray(modules)) throw new Error("client modules must be an array");
  const batches = planClientRegressionBatches(modules, {
    catalog,
    narrow: runKind === "retry",
  });
  const byStage = new Map(CLIENT_REGRESSION_STAGES.map((stage) => [stage, []]));
  for (const batch of batches) byStage.get(batch.stage).push(batch);
  const runner = commandRunner || ((batch) => runClientRegressionCommand(batch, { repoRoot }));
  const startedWall = new Date();
  const startedMono = process.hrtime.bigint();
  const results = [];
  const concurrency = { maximumWeight: 0, maximumProcesses: 0, poolPeaks: {} };
  const merge = (execution) => {
    results.push(...execution.results);
    concurrency.maximumWeight = Math.max(concurrency.maximumWeight, execution.concurrency.maximumWeight);
    concurrency.maximumProcesses = Math.max(concurrency.maximumProcesses, execution.concurrency.maximumProcesses);
    for (const [pool, peak] of Object.entries(execution.concurrency.poolPeaks)) {
      concurrency.poolPeaks[pool] = Math.max(concurrency.poolPeaks[pool] || 0, peak);
    }
  };
  const run = async (stageBatches) => {
    if (stageBatches.length === 0) {
      return { results: [], concurrency: { maximumWeight: 0, maximumProcesses: 0, poolPeaks: {} } };
    }
    const stages = [...new Set(stageBatches.map((batch) => batch.stage))].join(",");
    output.write(`[client-regression] starting ${stages}: ${stageBatches.length} planned invocation(s)\n`);
    return executeClientRegressionBatches(stageBatches, { capacities, commandRunner: runner });
  };

  const foundation = await run(byStage.get("foundation"));
  merge(foundation);
  let branchesPassed = false;
  if (resultsPassed(foundation.results)) {
    const branches = await run([...byStage.get("frontend"), ...byStage.get("backend")]);
    merge(branches);
    branchesPassed = resultsPassed(branches.results);
  } else {
    results.push(...blockedResults(
      [...byStage.get("frontend"), ...byStage.get("backend")],
      "foundation_failed",
    ));
  }

  let integrationPassed = false;
  if (branchesPassed) {
    const integration = await run(byStage.get("integration"));
    merge(integration);
    integrationPassed = resultsPassed(integration.results);
  } else {
    results.push(...blockedResults(byStage.get("integration"), "core_branch_failed"));
  }
  if (integrationPassed) {
    merge(await run(byStage.get("scenarios")));
  } else {
    results.push(...blockedResults(byStage.get("scenarios"), "integration_failed"));
  }

  const compatibilityExecution = await compatibilityRunner({ capacities, output });
  const compatibility = Array.isArray(compatibilityExecution)
    ? compatibilityExecution
    : compatibilityExecution.rows;
  if (!Array.isArray(compatibilityExecution)) {
    merge({
      results: compatibilityExecution.results,
      concurrency: compatibilityExecution.concurrency,
    });
  }
  const completedWall = new Date();
  const report = createClientRegressionReport({
    runKind,
    startedAt: startedWall.toISOString(),
    completedAt: completedWall.toISOString(),
    durationMs: Math.round(monotonicMilliseconds(startedMono)),
    results,
    concurrency,
    compatibility,
  });
  if (reportPath) await writeClientRegressionReport(report, reportPath);
  const compatibilityFailed = compatibility.some((row) => row.status === "failed");
  const ok = resultsPassed(results) && !compatibilityFailed;
  output.write(`[client-regression] ${ok ? "passed" : "failed"}: ${results.length} invocation(s) settled\n`);
  return Object.freeze({
    ok,
    completed: Object.freeze(results.flatMap((result) =>
      result.status === "passed" ? result.members : [])),
    failures: report.failures,
    exitCode: ok ? 0 : 1,
    report,
  });
}
