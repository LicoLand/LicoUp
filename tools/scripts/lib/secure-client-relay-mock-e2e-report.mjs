import { spawnSync } from "node:child_process";
import path from "node:path";

export const secureClientRelayMockE2eProducer =
  "tools/scripts/client-secure-client-relay-mock-e2e.mjs";
export const secureClientRelayMockE2eSchemaVersion =
  "licomesh.secure-client-relay.mock-e2e-report.v1";

const digestPattern = /^sha256:[a-f0-9]{64}$/u;
const exactReportFields = Object.freeze([
  "ok",
  "schemaVersion",
  "protocolVersion",
  "coreContractDigest",
  "coreConformanceDigest",
  "operationCount",
  "outerEnvelopeFieldCount",
  "exactFiveOperationsObserved",
  "exactSixOuterFieldsObserved",
  "exactConformanceCorpusVerified",
  "replayRejected",
  "staleLeaseRejected",
  "activeLeaseSuppressed",
  "ackIdempotencyVerified",
  "duplicateAckFenceBound",
  "mailboxBackpressureCatalogBound",
  "plaintextAbsentFromServerVisibleWire",
  "wireBytesMeasured",
  "acknowledgedEnvelopeCount"
]);

function exactKeys(value, expected) {
  return value && typeof value === "object" && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

export function secureClientRelayMockE2eReady(report) {
  return exactKeys(report, exactReportFields) &&
    report.ok === true &&
    report.schemaVersion === secureClientRelayMockE2eSchemaVersion &&
    typeof report.protocolVersion === "string" && report.protocolVersion.length > 0 &&
    digestPattern.test(String(report.coreContractDigest || "")) &&
    digestPattern.test(String(report.coreConformanceDigest || "")) &&
    report.operationCount === 5 &&
    report.outerEnvelopeFieldCount === 6 &&
    report.exactFiveOperationsObserved === true &&
    report.exactSixOuterFieldsObserved === true &&
    report.exactConformanceCorpusVerified === true &&
    report.replayRejected === true &&
    report.staleLeaseRejected === true &&
    report.activeLeaseSuppressed === true &&
    report.ackIdempotencyVerified === true &&
    report.duplicateAckFenceBound === true &&
    report.mailboxBackpressureCatalogBound === true &&
    report.plaintextAbsentFromServerVisibleWire === true &&
    report.wireBytesMeasured === true &&
    Number.isSafeInteger(report.acknowledgedEnvelopeCount) &&
    report.acknowledgedEnvelopeCount > 0;
}

export function runSecureClientRelayMockE2e({ repoRoot, env = process.env, timeoutMs = 30_000 }) {
  const producerPath = path.join(repoRoot, secureClientRelayMockE2eProducer);
  const result = spawnSync(process.execPath, [producerPath], {
    cwd: repoRoot,
    env,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 1024 * 1024,
    timeout: timeoutMs
  });
  let report = {};
  try {
    report = JSON.parse(String(result.stdout || ""));
  } catch {
    report = {};
  }
  return Object.freeze({
    ok: result.status === 0 && secureClientRelayMockE2eReady(report),
    exitCode: Number.isInteger(result.status) ? result.status : -1,
    producer: secureClientRelayMockE2eProducer,
    report: secureClientRelayMockE2eReady(report) ? Object.freeze(report) : Object.freeze({})
  });
}
