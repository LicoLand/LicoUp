#!/usr/bin/env node

import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  accessSync,
  chmodSync,
  constants as fsConstants,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
} from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import {
  sha256Buffer,
  stableHashFileSnapshot,
  stableReadFile,
  stableReadFileSnapshot,
  stableSnapshotFile,
} from "./lib/client-release-artifact-digest.mjs";
import {
  licoArcBadTowerAcceptanceReady,
  validateLicoArcBadTowerAcceptanceReport,
} from "./lib/licoarc-badtower-acceptance-report.mjs";
import {
  createBadTowerStationEnvironment,
  runBadTowerStationEnvironmentSelfTest,
  runLicoArcBadTowerCandidatePathSelfTest,
} from "./lib/licoarc-badtower-candidate-binding.mjs";
import {
  runLicoArcV1BundleValidatorSelfTest,
  validateLicoArcV1BundleBytes,
} from "./lib/licoarc-v1-bundle-validator.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";
import { loadSecureMeshPhysicalEvidenceConfig } from "./lib/secure-mesh-physical-evidence-config.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const physicalEvidence = await loadSecureMeshPhysicalEvidenceConfig();
const cliArgs = process.argv.slice(2);
let runtimeRoot = "";
let failureStage = "candidate-input";

if (cliArgs.length === 1 && cliArgs[0] === "--bundle-validation-self-test") {
  runBundleAndEnvironmentSelfTest();
} else if (cliArgs.length === 0) {
  await runAcceptance();
} else {
  process.stderr.write(`${JSON.stringify({
    ok: false,
    stage: "arguments",
    diagnosticsRedacted: true,
  })}\n`);
  process.exitCode = 1;
}

async function runAcceptance() {
  const reportRef = physicalEvidence.linkedReports.stationAcceptance;
  let station;
  try {
    runtimeRoot = mkdtempSync(path.join(
      os.tmpdir(),
      "licoup-badtower-acceptance-",
    ));
    chmodSync(runtimeRoot, 0o700);
    const databasePath = path.join(runtimeRoot, "badtower.db");
    const receiptPath = path.join(runtimeRoot, "runtime-receipt.json");
    const privateCanary = randomBytes(32).toString("hex");
    const binaryPath = requiredCandidatePath(
      "LICOUP_ACCEPTANCE_BADTOWER_BINARY",
      { executable: true },
    );
    const protocolBundlePath =
      requiredCandidatePath("LICOUP_ACCEPTANCE_LICOARC_BUNDLE");
    failureStage = "candidate-validation";
    const stationBefore = stableHashFileSnapshot(binaryPath, {
      maxBytes: 512 * 1024 * 1024,
    });
    const stationExecutable = stableSnapshotFile(
      binaryPath,
      runtimeRoot,
      process.platform === "win32"
        ? "badtower-candidate.exe"
        : "badtower-candidate",
      { maxBytes: 512 * 1024 * 1024 },
    );
    if (process.platform !== "win32") chmodSync(stationExecutable, 0o700);
    const stationExecutableSnapshot =
      stableHashFileSnapshot(stationExecutable, {
        maxBytes: 512 * 1024 * 1024,
      });
    requireValue(
      stationExecutableSnapshot.digest === stationBefore.digest &&
        stationExecutableSnapshot.size === stationBefore.size,
      "BadTower execution snapshot does not match the candidate",
    );
    const protocolBefore = validateProtocolBundle(protocolBundlePath);
    const clientBefore = clientSourceStateDigest(
      repoRoot,
      CANONICAL_CLIENT_SOURCE_ROOTS,
    );
    const port = await reserveLoopbackPort();
    const origin = `http://127.0.0.1:${port}`;
    failureStage = "station-startup";
    station = spawnStation(stationExecutable, port, databasePath);
    await waitForHealth(origin, station);
    failureStage = "endpoint-round-trip";
    await runRustAcceptance({
      origin,
      runtimeRoot,
      receiptPath,
      privateCanary,
    });
    await terminateStation(station);
    station = undefined;

    failureStage = "runtime-receipt";
    const receipt = readRuntimeReceipt(receiptPath);
    const database = stableReadFile(databasePath, {
      maxBytes: 64 * 1024 * 1024,
    });
    const stationPlaintextAbsent =
      receipt.scenario.wirePlaintextAbsent === true &&
      !database.includes(Buffer.from(privateCanary, "utf8"));
    const stationAfter = stableHashFileSnapshot(binaryPath, {
      maxBytes: 512 * 1024 * 1024,
    });
    const protocolAfter = validateProtocolBundle(protocolBundlePath);
    const clientAfter = clientSourceStateDigest(
      repoRoot,
      CANONICAL_CLIENT_SOURCE_ROOTS,
    );
    requireStableCandidate(stationBefore, stationAfter, "station");
    requireStableCandidate(protocolBefore, protocolAfter, "protocol");
    requireValue(
      clientBefore === clientAfter,
      "client candidate changed during acceptance",
    );

    failureStage = "report-validation";
    const expectedCandidateDigests = {
      protocolCandidateDigest: protocolBefore.digest,
      stationCandidateDigest: stationBefore.digest,
      clientCandidateDigest: clientBefore,
    };
    const report = validateLicoArcBadTowerAcceptanceReport({
      schemaVersion: "licoup.licoarc-badtower.acceptance.v1",
      ok: true,
      protocolCandidateDigest: protocolBefore.digest,
      stationCandidateDigest: stationBefore.digest,
      clientCandidateDigest: clientBefore,
      scenario: {
        freshEndpointCount: receipt.scenario.freshEndpointCount,
        positiveExchange: receipt.scenario.positiveExchange,
        roundTrip: receipt.scenario.roundTrip,
        stationPlaintextAbsent,
        nonConformantEnvelopeRejected:
          receipt.scenario.nonConformantEnvelopeRejected,
        transportHintsNonAuthoritative:
          receipt.scenario.transportHintsNonAuthoritative,
        exactFiveOuterFields: receipt.scenario.exactFiveOuterFields,
        mobileFfiDispatch: receipt.scenario.mobileFfiDispatch,
        typedPendingObserved: receipt.scenario.typedPendingObserved,
        durableResultReceiptAcknowledged:
          receipt.scenario.durableResultReceiptAcknowledged,
      },
      privacy: {
        redacted: true,
        endpointContentIncluded: false,
        ciphertextIncluded: false,
        keyMaterialIncluded: false,
        machineIdentityIncluded: false,
        rawRuntimeDataIncluded: false,
      },
      claims: {
        clientRelease: false,
        protocolPublication: false,
        stationRelease: false,
        hostedOperation: false,
      },
    }, expectedCandidateDigests);
    requireValue(
      licoArcBadTowerAcceptanceReady(report, expectedCandidateDigests),
      "acceptance report is not bound to the current candidates",
    );
    failureStage = "report-write";
    atomicWriteReportJson(repoRoot, reportRef, report);
    process.stdout.write(`${JSON.stringify({
      ok: true,
      report: reportRef,
      candidateDigestsBound: true,
      releaseClaimed: false,
    })}\n`);
  } catch {
    process.stderr.write(`${JSON.stringify({
      ok: false,
      stage: failureStage,
      diagnosticsRedacted: true,
    })}\n`);
    process.exitCode = 1;
  } finally {
    if (station) {
      await terminateStation(station).catch(() => undefined);
    }
    if (runtimeRoot) {
      rmSync(runtimeRoot, { recursive: true, force: true });
    }
    runtimeRoot = "";
  }
}

function runBundleAndEnvironmentSelfTest() {
  try {
    const protocolBundlePath =
      requiredCandidatePath("LICOUP_ACCEPTANCE_LICOARC_BUNDLE");
    const bundleSelfTest = runLicoArcV1BundleValidatorSelfTest(
      stableReadFile(protocolBundlePath, { maxBytes: 128 * 1024 * 1024 }),
    );
    const environmentSelfTest = runBadTowerStationEnvironmentSelfTest();
    const candidatePathSelfTest =
      runLicoArcBadTowerCandidatePathSelfTest();
    const ok = bundleSelfTest.ok === true &&
      environmentSelfTest.ok === true &&
      candidatePathSelfTest.ok === true;
    process.stdout.write(`${JSON.stringify({
      ok,
      canonicalBundleAccepted: bundleSelfTest.canonicalBundleAccepted,
      emptyBundleRejected: bundleSelfTest.emptyBundleRejected,
      unknownFieldRejected: bundleSelfTest.unknownFieldRejected,
      tamperedSourceRejected: bundleSelfTest.tamperedSourceRejected,
      staleRecomputedBundleRejected:
        bundleSelfTest.staleRecomputedBundleRejected,
      stationEnvironmentMinimal: environmentSelfTest.ok,
      ambientSecretsRejected: environmentSelfTest.ambientSecretsRejected,
      candidatePathValidationReady: candidatePathSelfTest.ok,
      regularFileRequired: candidatePathSelfTest.directoryRejected,
      executableRequired: candidatePathSelfTest.nonExecutableRejected,
      crossPlatformAccessModes:
        candidatePathSelfTest.crossPlatformAccessModes,
    })}\n`);
    if (!ok) process.exitCode = 1;
  } catch {
    process.stderr.write(`${JSON.stringify({
      ok: false,
      stage: "bundle-validation-self-test",
      diagnosticsRedacted: true,
    })}\n`);
    process.exitCode = 1;
  }
}

function requiredCandidatePath(name, { executable = false } = {}) {
  const value = String(process.env[name] || "").trim();
  requireValue(value && path.isAbsolute(value), `${name} must be an absolute path`);
  const resolved = path.resolve(value);
  requireValue(statSync(resolved).isFile(), `${name} must be a regular file`);
  accessSync(
    resolved,
    executable && process.platform !== "win32"
      ? fsConstants.X_OK
      : fsConstants.F_OK,
  );
  return resolved;
}

function validateProtocolBundle(bundlePath) {
  const snapshot = stableReadFileSnapshot(bundlePath, {
    maxBytes: 128 * 1024 * 1024,
  });
  validateLicoArcV1BundleBytes(snapshot.bytes);
  return Object.freeze({
    digest: sha256Buffer(snapshot.bytes),
    size: snapshot.size,
    mtimeMs: snapshot.mtimeMs,
    device: snapshot.device,
    inode: snapshot.inode,
  });
}

async function reserveLoopbackPort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port: 0, exclusive: true }, () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => {
        if (error || !Number.isSafeInteger(port) || port <= 0) {
          reject(error || new Error("loopback port reservation failed"));
        } else {
          resolve(port);
        }
      });
    });
  });
}

function spawnStation(executable, port, dataPath) {
  const env = createBadTowerStationEnvironment();
  const child = spawn(executable, [
    "-listen",
    `127.0.0.1:${port}`,
    "-data",
    dataPath,
  ], {
    cwd: runtimeRoot,
    env,
    stdio: "ignore",
    windowsHide: true,
  });
  child.on("error", () => undefined);
  return child;
}

async function waitForHealth(origin, child) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    requireValue(child.exitCode === null && child.signalCode === null,
      "BadTower candidate exited before health");
    try {
      if (await healthReady(origin)) return;
    } catch {
      // A bounded retry is expected while the process opens its database and listener.
    }
    await boundedDelay(50);
  }
  throw new Error("BadTower candidate health timeout");
}

function healthReady(origin) {
  return new Promise((resolve, reject) => {
    const request = http.get(`${origin}/healthz`, {
      headers: { accept: "application/json" },
      timeout: 500,
    }, (response) => {
      let size = 0;
      const chunks = [];
      response.on("data", (chunk) => {
        size += chunk.length;
        if (size > 1024) {
          request.destroy(new Error("health response is oversized"));
          return;
        }
        chunks.push(chunk);
      });
      response.once("end", () => {
        try {
          const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
          resolve(
            response.statusCode === 200 &&
              Object.keys(payload).length === 1 &&
              payload.status === "ok",
          );
        } catch (error) {
          reject(error);
        }
      });
    });
    request.once("timeout", () => request.destroy(new Error("health timeout")));
    request.once("error", reject);
  });
}

async function runRustAcceptance({
  origin,
  runtimeRoot: acceptanceRoot,
  receiptPath: acceptanceReceipt,
  privateCanary: canary,
}) {
  const env = filteredEnvironment((name) =>
    !name.startsWith("LICOUP_ACCEPTANCE_") &&
    name !== "LICOUP_PORTABLE_DIR" &&
    name !== "LICO_MOBILE_RELAY_STATION_BASE_URL" &&
    name !== "LICO_MOBILE_RELAY_NATIVE_SECRET_STORE");
  Object.assign(env, {
    LICOUP_ACCEPTANCE_BADTOWER_ORIGIN: origin,
    LICOUP_ACCEPTANCE_RUNTIME_ROOT: acceptanceRoot,
    LICOUP_ACCEPTANCE_RUNTIME_RECEIPT_PATH: acceptanceReceipt,
    LICOUP_ACCEPTANCE_PRIVATE_CANARY: canary,
  });
  const args = [
    path.join(repoRoot, "tools/scripts/cargo-client.mjs"),
    "test",
    "--manifest-path",
    "crates/licoup-native/Cargo.toml",
    "domain::mobile_relay::tests::badtower_acceptance::two_fresh_licoup_endpoints_round_trip_through_real_badtower",
    "--",
    "--exact",
    "--ignored",
    "--test-threads=1",
  ];
  const result = await spawnAndWait(process.execPath, args, {
    cwd: repoRoot,
    env,
    stdio: "ignore",
    windowsHide: true,
  });
  if (result.code !== 0 || result.signal) {
    const stage = readAcceptanceStage(acceptanceRoot);
    if (stage) failureStage = `endpoint-round-trip:${stage}`;
  }
  requireValue(result.code === 0 && !result.signal, "LicoUp acceptance test failed");
}

function readAcceptanceStage(acceptanceRoot) {
  try {
    const value = readFileSync(
      path.join(acceptanceRoot, "acceptance-stage"),
      "utf8",
    ).trim();
    return /^[a-z]+(?:-[a-z]+)*$/u.test(value) ? value : "";
  } catch {
    return "";
  }
}

function readRuntimeReceipt(receipt) {
  const bytes = readFileSync(receipt);
  requireValue(bytes.length > 0 && bytes.length <= 4 * 1024,
    "runtime receipt size is invalid");
  const value = JSON.parse(bytes.toString("utf8"));
  const scenarioFields = [
    "freshEndpointCount",
    "positiveExchange",
    "roundTrip",
    "wirePlaintextAbsent",
    "nonConformantEnvelopeRejected",
    "transportHintsNonAuthoritative",
    "exactFiveOuterFields",
    "mobileFfiDispatch",
    "typedPendingObserved",
    "durableResultReceiptAcknowledged",
  ];
  requireValue(
    exactKeys(value, ["schemaVersion", "scenario"]) &&
      value.schemaVersion === "licoup.licoarc-badtower.runtime-receipt.v1" &&
      exactKeys(value.scenario, scenarioFields) &&
      value.scenario.freshEndpointCount === 2 &&
      scenarioFields
        .filter((field) => field !== "freshEndpointCount")
        .every((field) => value.scenario[field] === true),
    "runtime receipt is incomplete",
  );
  return value;
}

async function terminateStation(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.kill("SIGTERM");
  const graceful = await Promise.race([
    exited.then(() => true),
    boundedDelay(3_000).then(() => false),
  ]);
  if (!graceful && child.exitCode === null && child.signalCode === null) {
    child.kill("SIGKILL");
    await Promise.race([exited, boundedDelay(2_000)]);
  }
}

function spawnAndWait(command, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, options);
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
}

function filteredEnvironment(predicate) {
  return Object.fromEntries(
    Object.entries(process.env).filter(([name]) => predicate(name)),
  );
}

function boundedDelay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function exactKeys(value, expected) {
  return value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) ===
      JSON.stringify([...expected].sort());
}

function requireStableCandidate(before, after, label) {
  requireValue(
    before.digest === after.digest &&
      before.size === after.size &&
      before.device === after.device &&
      before.inode === after.inode,
    `${label} candidate changed during acceptance`,
  );
}

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}
