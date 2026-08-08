import { spawn } from "node:child_process";
import { stopChildProcess } from "../lib/bounded-child-process.mjs";

const defaultTimeoutMs = 5_000;
export const defaultMaxStdoutBytes = 8 * 1024;

function skipped(agentId, reasonCode) {
  return Object.freeze({
    agentId,
    probeSupported: false,
    authenticationStatus: "skipped",
    reasonCode,
  });
}

function resolved(agentId, authenticationStatus, reasonCode) {
  return Object.freeze({
    agentId,
    probeSupported: true,
    authenticationStatus,
    reasonCode,
  });
}

export function resolveProbeExecutable(manifest, probe, environment = process.env) {
  for (const key of manifest.configuration.binaryEnvironmentKeys) {
    const value = environment[key];
    if (typeof value === "string" && value.trim().length > 0) return value;
  }
  return probe.executable;
}

export function executeExitStatusProbe(executable, args, options = {}) {
  const timeoutMs = options.timeoutMs || defaultTimeoutMs;
  const maxStdoutBytes = options.maxStdoutBytes || defaultMaxStdoutBytes;
  const spawnProcess = options.spawnProcess || spawn;
  return new Promise((resolve) => {
    let settled = false;
    let stopping = false;
    let timer;
    let stdout = Buffer.alloc(0);
    const finish = (outcome) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(outcome);
    };
    let child;
    try {
      child = spawnProcess(executable, args, {
        env: options.environment || process.env,
        stdio: ["ignore", "pipe", "ignore"],
      });
    } catch {
      resolve({ kind: "start-failed" });
      return;
    }
    const stopAndFinish = async (kind) => {
      if (settled || stopping) return;
      stopping = true;
      try {
        await stopChildProcess(child, { gracefulTimeoutMs: 250, forceTimeoutMs: 250 });
      } catch {
        // The public result remains a fixed inconclusive category.
      }
      finish({ kind });
    };
    timer = setTimeout(() => {
      void stopAndFinish("timeout");
    }, timeoutMs);
    child.stdout?.on("data", (chunk) => {
      if (settled) return;
      if (stdout.length + chunk.length > maxStdoutBytes) {
        void stopAndFinish("output-limit");
        return;
      }
      stdout = Buffer.concat([stdout, chunk]);
    });
    child.once("error", () => {
      if (!stopping) finish({ kind: "start-failed" });
    });
    child.once("close", (code, signal) => {
      // Once a bounded stop has started, its initiating reason owns the result.
      // A close/error caused by SIGTERM or SIGKILL must never be reclassified as
      // a successful exit-status probe.
      if (stopping) return;
      if (Number.isInteger(code)) finish({ kind: "exit", code, stdout: stdout.toString("utf8") });
      else finish({ kind: "signal", signal: Boolean(signal) });
    });
  });
}

function normalizedOutputLines(output) {
  return new Set(String(output || "")
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter(Boolean));
}

function outputMatchesDeclaredLine(output, declaredLines) {
  if (declaredLines.length === 0) return true;
  const outputLines = normalizedOutputLines(output);
  return declaredLines.some((declaredLine) => outputLines.has(declaredLine));
}

export async function probeAgentAuthentication(manifest, probe, options = {}) {
  const agentId = manifest.identity.agentId;
  if (!probe) return skipped(agentId, "probe_unavailable");
  if (probe.kind !== "exit-status") return skipped(agentId, "probe_unsupported");

  const executable = resolveProbeExecutable(
    manifest,
    probe,
    options.environment || process.env,
  );
  const execute = options.execute || executeExitStatusProbe;
  const outcome = await execute(executable, probe.arguments, {
    environment: options.environment || process.env,
    timeoutMs: options.timeoutMs || defaultTimeoutMs,
    maxStdoutBytes: options.maxStdoutBytes || defaultMaxStdoutBytes,
    spawnProcess: options.spawnProcess,
  });
  if (outcome.kind === "start-failed") return skipped(agentId, "executable_unavailable");
  if (outcome.kind === "timeout") return skipped(agentId, "probe_timeout");
  if (outcome.kind === "output-limit") return skipped(agentId, "probe_output_limit");
  if (outcome.kind !== "exit") return skipped(agentId, "probe_inconclusive");
  const authenticatedOutputMatches = outputMatchesDeclaredLine(
    outcome.stdout,
    probe.authenticatedStdoutPrefixes,
  );
  const unauthenticatedOutputMatches = outputMatchesDeclaredLine(
    outcome.stdout,
    probe.unauthenticatedStdoutPrefixes,
  );
  const contradictoryOutput = probe.authenticatedStdoutPrefixes.length > 0
    && probe.unauthenticatedStdoutPrefixes.length > 0
    && authenticatedOutputMatches
    && unauthenticatedOutputMatches;
  if (contradictoryOutput) return skipped(agentId, "probe_inconclusive");
  if (probe.authenticatedExitCodes.includes(outcome.code)
    && authenticatedOutputMatches) {
    return resolved(agentId, "authenticated", "probe_confirmed");
  }
  if (probe.unauthenticatedExitCodes.includes(outcome.code)
    && unauthenticatedOutputMatches) {
    return resolved(agentId, "unauthenticated", "probe_rejected");
  }
  return skipped(agentId, "probe_inconclusive");
}
