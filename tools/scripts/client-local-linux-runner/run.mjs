import { spawn } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import {
  atomicReplaceContainedFileSnapshot,
  atomicWriteReportJson,
  DEFAULT_MAX_REPORT_JSON_BYTES,
} from "../lib/safe-report-io.mjs";
import { sanitizeError } from "../lib/sanitize-error.mjs";
import { parseArgs } from "./cli.mjs";
import {
  buildRoot,
  dockerfileRef,
  knownLanes,
  repoRoot,
  reportRoot,
  reportSchemaVersion,
  runnerPlatform,
  supportedLanes,
} from "./constants.mjs";
import {
  ensureRunnerImage,
  inspectLocalDocker,
  runnerCacheRoot,
  runnerDockerArgs,
  verifyRunnerArchitecture,
} from "./docker.mjs";
import { runSelfTest } from "./self-test.mjs";
import { materializeCandidate } from "./snapshot.mjs";

const privateDiagnosticMaxBytes = 2 * 1024 * 1024;
const diagnosticReferencePattern = /^build\/private\/client-regression\/(?<name>[a-z0-9][a-z0-9.-]*\.log)$/u;

function cargoAuditVersion() {
  const workflow = readFileSync(path.join(repoRoot, ".github/workflows/client-ci.yml"), "utf8");
  const match = workflow.match(/cargo install cargo-audit --version ([0-9]+\.[0-9]+\.[0-9]+) --locked/u);
  if (!match) throw new Error("client_ci_cargo_audit_version_missing");
  return match[1];
}

function baseReceipt({ lane = null, profile = null }, status, extra = {}) {
  return Object.freeze({
    ok: status === "passed",
    schemaVersion: reportSchemaVersion,
    lane,
    profile,
    status,
    platform: runnerPlatform,
    executionScope: "ubuntu-24.04-linux-amd64-container-user-space",
    targetDesktopRuntimeVerified: false,
    nativeServiceIntegrationVerified: false,
    dockerfile: dockerfileRef,
    sourceCandidate: "tracked-and-untracked-nonignored-working-tree",
    hostHomeMounted: false,
    dockerSocketMounted: false,
    sharedProjectToolCache: true,
    runtimeDataIncluded: false,
    rawLogsIncluded: false,
    ...extra,
  });
}

function writeReceipt(receipt) {
  mkdirSync(reportRoot, { recursive: true, mode: 0o700 });
  atomicWriteReportJson(
    buildRoot,
    `reports/client-local-linux-ci/${receipt.lane || receipt.profile || "inspect"}.json`,
    receipt,
  );
  process.stdout.write(`${JSON.stringify(receipt)}\n`);
}

function sanitizeLine(value) {
  return sanitizeError(value)
    .replaceAll(repoRoot, "<repo>")
    .replaceAll(os.homedir(), "<home>");
}

function streamingCommand(command, args) {
  return new Promise((resolve) => {
    const env = Object.fromEntries(Object.entries({
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      DOCKER_HOST: process.env.DOCKER_HOST,
      DOCKER_CONTEXT: process.env.DOCKER_CONTEXT,
      DOCKER_CONFIG: process.env.DOCKER_CONFIG,
    }).filter(([, value]) => typeof value === "string" && value.length > 0));
    const child = spawn(command, args, {
      cwd: repoRoot,
      env,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const forward = (stream, output) => {
      let pending = "";
      stream.setEncoding("utf8");
      stream.on("data", (chunk) => {
        pending += chunk;
        const lines = pending.split(/\r?\n/u);
        pending = lines.pop() || "";
        for (const line of lines) output.write(`${sanitizeLine(line)}\n`);
      });
      stream.on("end", () => {
        if (pending) output.write(`${sanitizeLine(pending)}\n`);
      });
    };
    forward(child.stdout, process.stdout);
    forward(child.stderr, process.stderr);
    child.on("error", () => resolve(1));
    child.on("close", (code) => resolve(code ?? 1));
  });
}

export function importEngineeringReport(outputRoot, destinationRoot = buildRoot) {
  const source = path.join(outputRoot, "client-module-regression.json");
  if (!existsSync(source)) return Object.freeze({ reportImported: false, diagnosticCount: 0 });
  const info = lstatSync(source);
  if (!info.isFile() || info.isSymbolicLink() || (info.mode & 0o077) !== 0) {
    throw new Error("client_module_regression_report_unsafe");
  }
  const value = readFileSync(source);
  if (value.length > DEFAULT_MAX_REPORT_JSON_BYTES) {
    throw new Error("client_module_regression_report_oversized");
  }
  const report = JSON.parse(value.toString("utf8"));
  const references = new Set();
  for (const result of Array.isArray(report?.results) ? report.results : []) {
    if (typeof result?.diagnosticLog !== "string") continue;
    const match = diagnosticReferencePattern.exec(result.diagnosticLog);
    if (!match) throw new Error("client_module_regression_diagnostic_reference_unsafe");
    references.add(match.groups.name);
  }
  for (const name of references) {
    const diagnosticSource = path.join(outputRoot, "private", "client-regression", name);
    if (!existsSync(diagnosticSource)) {
      throw new Error("client_module_regression_diagnostic_missing");
    }
    const diagnosticInfo = lstatSync(diagnosticSource);
    if (!diagnosticInfo.isFile() || diagnosticInfo.isSymbolicLink() || (diagnosticInfo.mode & 0o077) !== 0) {
      throw new Error("client_module_regression_diagnostic_unsafe");
    }
    atomicReplaceContainedFileSnapshot(
      destinationRoot,
      `private/client-regression/${name}`,
      diagnosticSource,
      { maxBytes: privateDiagnosticMaxBytes },
    );
  }
  atomicReplaceContainedFileSnapshot(
    destinationRoot,
    "reports/client-module-regression.json",
    source,
    { maxBytes: DEFAULT_MAX_REPORT_JSON_BYTES },
  );
  return Object.freeze({ reportImported: true, diagnosticCount: references.size });
}

async function runSelection(selection) {
  const { lane, profile, moduleIds = [] } = selection;
  if (!supportedLanes.includes(lane)) {
    if (profile === "engineering") {
      // The engineering profile is supplied by the integrated client gate.
    } else {
      const receipt = baseReceipt(selection, "blocked", {
        reasonCode: "lane_not_supported",
      });
      writeReceipt(receipt);
      process.exitCode = 2;
      return;
    }
  }
  let candidateRoot = "";
  let outputRoot = "";
  try {
    inspectLocalDocker();
    const image = await ensureRunnerImage(streamingCommand);
    verifyRunnerArchitecture(image);
    candidateRoot = mkdtempSync(path.join(os.tmpdir(), "licoup-linux-ci-candidate-"));
    mkdirSync(path.join(buildRoot, "local-linux-ci"), { recursive: true, mode: 0o700 });
    outputRoot = mkdtempSync(path.join(buildRoot, "local-linux-ci", "output-"));
    const candidate = materializeCandidate(repoRoot, candidateRoot);
    const args = runnerDockerArgs({
      image,
      lane,
      profile,
      candidateRoot,
      cacheRoot: runnerCacheRoot(),
      outputRoot,
      cargoAuditVersion: cargoAuditVersion(),
      moduleIds,
    });
    const exitCode = await streamingCommand("docker", args);
    const imported = profile === "engineering"
      ? importEngineeringReport(outputRoot)
      : Object.freeze({ reportImported: false, diagnosticCount: 0 });
    const status = exitCode === 0 ? "passed" : "failed";
    const receipt = baseReceipt(selection, status, {
      sourceFileCount: candidate.fileCount,
      sourceStateDigest: candidate.sourceStateDigest,
      localDockerVerified: true,
      containerArchitectureVerified: true,
      canonicalAuditorDelegated: lane === "source" || profile === "engineering",
      moduleRegressionReportImported: imported.reportImported,
      privateDiagnosticCount: imported.diagnosticCount,
      exitCode,
    });
    writeReceipt(receipt);
    if (exitCode !== 0) process.exitCode = 1;
  } catch (error) {
    const reasonCode = /^[a-z0-9_]+$/u.test(error?.code || error?.message || "")
      ? (error.code || error.message)
      : "local_linux_runner_unavailable";
    writeReceipt(baseReceipt(selection, "blocked", { reasonCode }));
    process.exitCode = 2;
  } finally {
    if (candidateRoot) rmSync(candidateRoot, { recursive: true, force: true });
    if (outputRoot) rmSync(outputRoot, { recursive: true, force: true });
  }
}

export async function main(argv = process.argv.slice(2)) {
  try {
    const options = parseArgs(argv);
    if (options.command === "self-test") {
      process.stdout.write(`${JSON.stringify(await runSelfTest())}\n`);
      return;
    }
    if (options.command === "inspect") {
      const docker = inspectLocalDocker();
      process.stdout.write(`${JSON.stringify({
        ok: true,
        schemaVersion: reportSchemaVersion,
        platform: runnerPlatform,
        lanes: Object.fromEntries(knownLanes.map((lane) => [lane, {
          status: supportedLanes.includes(lane) ? "available" : "blocked",
          reasonCode: null,
        }])),
        ...docker,
        privateEndpointIncluded: false,
      })}\n`);
      return;
    }
    await runSelection({
      lane: options.lane,
      profile: options.profile,
      moduleIds: options.moduleIds || [],
    });
  } catch (error) {
    process.stderr.write(`${sanitizeLine(error?.message || error)}\n`);
    process.exitCode = 1;
  }
}
