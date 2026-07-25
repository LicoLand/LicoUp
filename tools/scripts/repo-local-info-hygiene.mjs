#!/usr/bin/env node
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const reportRef = "build/reports/repo-local-info-hygiene.json";
const reportPath = path.join(repoRoot, reportRef);
const schemaVersion = "licomesh.repo-local-info-hygiene.v1";
const evidenceDirectoryNames = new Set(["evidence", "reports", "receipts"]);
const inspectedEvidenceExtensions = new Set([".json", ".jsonl", ".log", ".md", ".txt", ".yaml", ".yml"]);
const identityFieldName = /^(?:adbSerial|deviceId|deviceIdentifier|deviceName|ecid|hostName|hostname|machineId|runtimeId|runtimeIdentifier|serial|serialNumber|udid)$/iu;
const unsafeEvidenceTextPatterns = Object.freeze([
  [
    "LOCAL_LABELED_DEVICE_IDENTIFIER",
    /\b(?:UDID|ECID|Serial(?:Number)?|DeviceIdentifier)\s*[:=]\s*[A-Za-z0-9-]{8,}\b/u
  ],
  [
    "LOCAL_ADB_DEVICE_LISTING",
    /\b[A-Za-z0-9_-]{8,}\s+device\b[^\n"]*\b(?:usb:|product:|model:|transport_id:)/u
  ],
  [
    "LOCAL_LITERAL_DEVICE_SELECTION",
    /(?:\badb\b[^\r\n]*\s-s\s+(?!\$)[^\s]+|\bANDROID_SERIAL\s*=\s*(?!\$)[^\s]+)/u
  ]
]);

function sha256(value) {
  return createHash("sha256").update(String(value), "utf8").digest("hex");
}

function safeRelativePath(root, candidate) {
  const relative = path.isAbsolute(candidate) ? path.relative(root, candidate) : candidate;
  const normalized = relative.split(path.sep).join("/");
  if (
    normalized === "." ||
    (
      normalized.length > 0 &&
      !normalized.startsWith("/") &&
      !normalized.startsWith("../") &&
      normalized !== ".." &&
      !/^[A-Za-z]:/u.test(normalized) &&
      !normalized.includes("\0") &&
      path.posix.normalize(normalized) === normalized
    )
  ) {
    return normalized;
  }
  return null;
}

function redactedFailure(reasonCode, relativePath, privateDetail = "") {
  return {
    reasonCode,
    path: relativePath,
    digest: sha256(`${reasonCode}\0${relativePath}\0${String(privateDetail)}`)
  };
}

function canonicalFailureReason(rule) {
  const suffix = String(rule)
    .toUpperCase()
    .replace(/[^A-Z0-9]+/gu, "_")
    .replace(/^_+|_+$/gu, "");
  return suffix ? `LICOMESH_DEV_${suffix}` : "LICOMESH_DEV_FINDING";
}

function validateCanonicalFinding(finding) {
  if (!finding || typeof finding !== "object" || Array.isArray(finding)) {
    return null;
  }
  const relativePath = safeRelativePath(repoRoot, finding.file);
  if (
    !relativePath ||
    typeof finding.rule !== "string" ||
    !/^[a-z0-9-]+$/u.test(finding.rule) ||
    !Number.isInteger(finding.line) ||
    finding.line < 1 ||
    typeof finding.digest !== "string" ||
    !/^[a-f0-9]{16,64}$/u.test(finding.digest)
  ) {
    return null;
  }
  return {
    reasonCode: canonicalFailureReason(finding.rule),
    path: relativePath,
    digest: finding.digest
  };
}

function parseCanonicalResult(stdout, exitCode, scanRoot) {
  let result;
  try {
    result = JSON.parse(stdout);
  } catch {
    return {
      ok: false,
      scannedFiles: 0,
      failures: [redactedFailure("LICOMESH_DEV_PROTOCOL_ERROR", ".", `${exitCode}\0${sha256(stdout)}`)]
    };
  }
  const validShape =
    result &&
    typeof result === "object" &&
    !Array.isArray(result) &&
    typeof result.ok === "boolean" &&
    Number.isInteger(result.scannedFiles) &&
    result.scannedFiles >= 0 &&
    Number.isInteger(result.findingCount) &&
    result.findingCount >= 0 &&
    Array.isArray(result.findings) &&
    result.findingCount === result.findings.length;
  if (!validShape || (result.ok ? exitCode !== 0 : exitCode !== 1)) {
    return {
      ok: false,
      scannedFiles: 0,
      failures: [redactedFailure("LICOMESH_DEV_PROTOCOL_ERROR", ".", `${exitCode}\0${sha256(stdout)}`)]
    };
  }
  const failures = [];
  for (const finding of result.findings) {
    const validated = validateCanonicalFindingForRoot(finding, scanRoot);
    if (!validated) {
      return {
        ok: false,
        scannedFiles: result.scannedFiles,
        failures: [redactedFailure("LICOMESH_DEV_UNSAFE_OUTPUT", ".", sha256(stdout))]
      };
    }
    failures.push(validated);
  }
  if (!result.ok && failures.length === 0) {
    failures.push(redactedFailure("LICOMESH_DEV_SCAN_FAILED", ".", result.error || sha256(stdout)));
  }
  return {
    ok: result.ok && failures.length === 0,
    scannedFiles: result.scannedFiles,
    failures
  };
}

function validateCanonicalFindingForRoot(finding, scanRoot) {
  if (scanRoot === repoRoot) {
    return validateCanonicalFinding(finding);
  }
  if (!finding || typeof finding !== "object" || Array.isArray(finding)) {
    return null;
  }
  const relativePath = safeRelativePath(scanRoot, finding.file);
  if (
    !relativePath ||
    typeof finding.rule !== "string" ||
    !/^[a-z0-9-]+$/u.test(finding.rule) ||
    !Number.isInteger(finding.line) ||
    finding.line < 1 ||
    typeof finding.digest !== "string" ||
    !/^[a-f0-9]{16,64}$/u.test(finding.digest)
  ) {
    return null;
  }
  return {
    reasonCode: canonicalFailureReason(finding.rule),
    path: relativePath,
    digest: finding.digest
  };
}

async function runCanonicalScan(scanRoot, command = "lico-dev") {
  let stdout = "";
  let exitCode = 0;
  try {
    const result = await execFileAsync(command, ["privacy", "scan", ".", "--format", "json"], {
      cwd: scanRoot,
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024
    });
    stdout = result.stdout;
  } catch (error) {
    if (error?.code === "ENOENT") {
      return {
        ok: false,
        scannedFiles: 0,
        failures: [redactedFailure("LICOMESH_DEV_UNAVAILABLE", ".", command)]
      };
    }
    stdout = typeof error?.stdout === "string" ? error.stdout : "";
    exitCode = Number.isInteger(error?.code) ? error.code : -1;
  }
  return parseCanonicalResult(stdout, exitCode, scanRoot);
}

function isRedacted(value) {
  return value === "redacted" || value === "[redacted]" || value === "<redacted>";
}

function inspectJsonValue(value, relativePath, fieldPath, failures) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => inspectJsonValue(entry, relativePath, [...fieldPath, `[${index}]`], failures));
    return;
  }
  if (!value || typeof value !== "object") {
    return;
  }
  for (const [key, entry] of Object.entries(value)) {
    const nextFieldPath = [...fieldPath, key];
    if (
      identityFieldName.test(key) &&
      typeof entry === "string" &&
      entry.length > 0 &&
      !isRedacted(entry)
    ) {
      failures.push(
        redactedFailure(
          "LOCAL_IDENTITY_FIELD",
          relativePath,
          `${nextFieldPath.join(".")}\0${entry}`
        )
      );
    }
    inspectJsonValue(entry, relativePath, nextFieldPath, failures);
  }
}

function inspectEvidenceText(text, relativePath, failures) {
  for (const [reasonCode, pattern] of unsafeEvidenceTextPatterns) {
    const match = pattern.exec(text);
    if (match) {
      failures.push(redactedFailure(reasonCode, relativePath, match[0]));
    }
  }
}

async function scanEvidenceFiles(root) {
  const failures = [];
  let scannedFiles = 0;

  async function walk(directory, insideEvidenceDirectory) {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name === ".git" || entry.name === "node_modules" || entry.name === "target") {
        continue;
      }
      const absolutePath = path.join(directory, entry.name);
      const currentInsideEvidence = insideEvidenceDirectory || evidenceDirectoryNames.has(entry.name.toLowerCase());
      if (entry.isSymbolicLink()) {
        continue;
      }
      if (entry.isDirectory()) {
        await walk(absolutePath, currentInsideEvidence);
        continue;
      }
      if (!entry.isFile() || !currentInsideEvidence || !inspectedEvidenceExtensions.has(path.extname(entry.name).toLowerCase())) {
        continue;
      }
      const fileStat = await lstat(absolutePath);
      if (fileStat.size > 2_000_000) {
        continue;
      }
      const buffer = await readFile(absolutePath);
      if (buffer.includes(0)) {
        continue;
      }
      scannedFiles += 1;
      const text = buffer.toString("utf8");
      const relativePath = safeRelativePath(root, absolutePath);
      if (!relativePath) {
        failures.push(redactedFailure("LOCAL_PATH_NORMALIZATION_FAILED", ".", absolutePath));
        continue;
      }
      inspectEvidenceText(text, relativePath, failures);
      if (path.extname(entry.name).toLowerCase() === ".json") {
        try {
          inspectJsonValue(JSON.parse(text), relativePath, [], failures);
        } catch {
          failures.push(redactedFailure("LOCAL_EVIDENCE_JSON_INVALID", relativePath, sha256(text)));
        }
      }
    }
  }

  await walk(root, false);
  const unique = [...new Map(
    failures.map((failure) => [`${failure.reasonCode}\0${failure.path}\0${failure.digest}`, failure])
  ).values()].sort((left, right) =>
    left.path.localeCompare(right.path) ||
    left.reasonCode.localeCompare(right.reasonCode) ||
    left.digest.localeCompare(right.digest)
  );
  return { scannedFiles, failures: unique };
}

function buildReport(canonical, local) {
  const failures = [...canonical.failures, ...local.failures];
  return {
    schemaVersion,
    ok: failures.length === 0,
    authoritativeScanner: "lico-dev",
    authoritativeScannedFiles: canonical.scannedFiles,
    localEvidenceScannedFiles: local.scannedFiles,
    findingCount: failures.length,
    failures
  };
}

function requireSelfTest(condition, reasonCode) {
  if (!condition) {
    const error = new Error(reasonCode);
    error.code = reasonCode;
    throw error;
  }
}

async function runSelfTest() {
  const temporary = await mkdtemp(path.join(tmpdir(), "lico-up-hygiene-"));
  try {
    const cleanProtocolResult = parseCanonicalResult(
      JSON.stringify({
        ok: true,
        scannedFiles: 3,
        findingCount: 0,
        findings: []
      }),
      0,
      temporary
    );
    requireSelfTest(cleanProtocolResult.ok === true, "SELF_TEST_CLEAN_PROTOCOL_RESULT_REJECTED");

    const fixtureDirectory = path.join(temporary, "build", "reports");
    await mkdir(fixtureDirectory, { recursive: true });
    const homePath = path.join(homedir(), ...["lico", "self", "test"].join("-").split("-"));
    const inlineSecret = ["self", "test", "private", "credential"].join("-");
    const credentialToken = ["sk", "selftestcredential000000000000"].join("-");
    const deviceIdentifier = ["SELF", "TEST", "DEVICE", "0001"].join("");
    const runtimeIdentifier = ["SELF", "TEST", "RUNTIME", "0001"].join("");
    const fixture = {
      localPath: homePath,
      api_key: inlineSecret,
      tokenText: credentialToken,
      deviceIdentifier,
      runtimeId: runtimeIdentifier
    };
    await writeFile(
      path.join(fixtureDirectory, "local-info-fixture.json"),
      `${JSON.stringify(fixture, null, 2)}\n`,
      "utf8"
    );

    const canonical = await runCanonicalScan(temporary);
    const local = await scanEvidenceFiles(temporary);
    const report = buildReport(canonical, local);
    const reasonCodes = new Set(report.failures.map((failure) => failure.reasonCode));
    requireSelfTest(report.ok === false, "SELF_TEST_DID_NOT_REJECT_FIXTURE");
    requireSelfTest(reasonCodes.has("LICOMESH_DEV_MACHINE_PATH"), "SELF_TEST_HOME_PATH_NOT_REJECTED");
    requireSelfTest(
      reasonCodes.has("LICOMESH_DEV_INLINE_SECRET") || reasonCodes.has("LICOMESH_DEV_CREDENTIAL_TOKEN"),
      "SELF_TEST_SECRET_NOT_REJECTED"
    );
    requireSelfTest(reasonCodes.has("LOCAL_IDENTITY_FIELD"), "SELF_TEST_IDENTITY_NOT_REJECTED");
    requireSelfTest(
      report.failures.every((failure) =>
        Object.keys(failure).sort().join(",") === "digest,path,reasonCode" &&
        /^[A-Z0-9_]+$/u.test(failure.reasonCode) &&
        safeRelativePath(temporary, failure.path) !== null &&
        /^[a-f0-9]{16,64}$/u.test(failure.digest)
      ),
      "SELF_TEST_FAILURE_SHAPE_UNSAFE"
    );
    const serialized = JSON.stringify(report);
    for (const privateValue of [homePath, inlineSecret, credentialToken, deviceIdentifier, runtimeIdentifier, temporary]) {
      requireSelfTest(!serialized.includes(privateValue), "SELF_TEST_REPORT_REDISCLOSED_VALUE");
    }

    const unavailableCommand = ["lico", "dev", "unavailable", "self", "test"].join("-");
    const unavailable = await runCanonicalScan(temporary, unavailableCommand);
    requireSelfTest(
      unavailable.ok === false &&
      unavailable.failures.length === 1 &&
      unavailable.failures[0].reasonCode === "LICOMESH_DEV_UNAVAILABLE",
      "SELF_TEST_MISSING_TOOL_NOT_FAIL_CLOSED"
    );

    return {
      schemaVersion,
      ok: true,
      checks: {
        canonicalCleanProtocolResultAccepted: true,
        canonicalScannerRejectedHomeAndCredential: true,
        localScannerRejectedDeviceAndRuntimeIdentity: true,
        reportDidNotRediscloseMatches: true,
        missingCanonicalScannerFailedClosed: true
      }
    };
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

const selfTestOnly = process.argv.slice(2).includes("--self-test");
if (selfTestOnly) {
  try {
    console.log(JSON.stringify(await runSelfTest(), null, 2));
  } catch (error) {
    console.error(JSON.stringify({
      schemaVersion,
      ok: false,
      reasonCode: /^[A-Z0-9_]+$/u.test(error?.code || "") ? error.code : "SELF_TEST_FAILED"
    }, null, 2));
    process.exit(1);
  }
} else {
  const canonical = await runCanonicalScan(repoRoot);
  const local = await scanEvidenceFiles(repoRoot);
  const report = buildReport(canonical, local);
  await mkdir(path.dirname(reportPath), { recursive: true });
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(JSON.stringify(report, null, 2));
  if (!report.ok) {
    process.exit(1);
  }
}
