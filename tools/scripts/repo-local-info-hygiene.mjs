#!/usr/bin/env node
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFile,
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
const reportRef = ".general-auditor/local/repo-local-info-hygiene.json";
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
const publicationCandidateListLimit = 16 * 1024 * 1024;

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

async function materializePublicationCandidateRoot(root = repoRoot) {
  const temporary = await mkdtemp(path.join(tmpdir(), "lico-up-source-candidate-"));
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
      {
        cwd: root,
        encoding: "utf8",
        maxBuffer: publicationCandidateListLimit,
      },
    );
    const candidates = [...new Set(String(stdout).split("\0").filter(Boolean))];
    for (const candidate of candidates) {
      const relative = safeRelativePath(root, candidate);
      if (relative === null || relative !== candidate.split(path.sep).join("/")) {
        throw new Error("publication candidate path is invalid");
      }
      const source = path.join(root, ...relative.split("/"));
      const metadata = await lstat(source).catch(() => null);
      if (!metadata || !metadata.isFile() || metadata.isSymbolicLink()) continue;
      const target = path.join(temporary, ...relative.split("/"));
      await mkdir(path.dirname(target), { recursive: true });
      await copyFile(source, target);
    }
    return temporary;
  } catch (error) {
    await rm(temporary, { recursive: true, force: true });
    throw error;
  }
}

function canonicalFailureReason(rule) {
  const suffix = String(rule)
    .toUpperCase()
    .replace(/[^A-Z0-9]+/gu, "_")
    .replace(/^_+|_+$/gu, "");
  return suffix ? `LICOMESH_DEV_${suffix}` : "LICOMESH_DEV_FINDING";
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
  if (!result || !Array.isArray(result.findings) ||
      !["completed", "completed_with_warnings", "policy_failure", "incomplete"].includes(result.status)) {
    return { ok: false, failures: [redactedFailure("LICOMESH_DEV_PROTOCOL_ERROR", ".")] };
  }
  const expectedExitCode = result.status === "policy_failure" ? 2 : result.status === "incomplete" ? 1 : 0;
  if (exitCode !== expectedExitCode) {
    return { ok: false, failures: [redactedFailure("LICOMESH_DEV_PROTOCOL_ERROR", ".")] };
  }
  const signals = [];
  for (const finding of result.findings) {
    if (!finding || typeof finding.file !== "string" ||
        safeRelativePath(scanRoot, finding.file) === null || typeof finding.rule !== "string") {
      return { ok: false, failures: [redactedFailure("LICOMESH_DEV_UNSAFE_OUTPUT", ".")] };
    }
    signals.push(redactedFailure(canonicalFailureReason(finding.rule), finding.file));
  }
  return {
    ok: exitCode === 0,
    scope: "tracked-and-untracked-nonignored-working-tree",
    signals,
    failures: exitCode === 0 ? [] : [redactedFailure("LICOMESH_DEV_AUDIT_INCOMPLETE_OR_POLICY_FAILURE", ".")]
  };
}

function isGeneralAuditorDelegationEnabled(environment = process.env) {
  return (
    environment.GENERAL_AUDITOR_GATE_DELEGATED === "1" &&
    environment.GITHUB_ACTIONS === "true" &&
    environment.GITHUB_WORKFLOW === "Client CI" &&
    environment.GITHUB_JOB === "engineering"
  );
}

function isCI(environment = process.env) {
  return [environment.CI, environment.GITHUB_ACTIONS].some((value) =>
    value && !["false", "0"].includes(String(value).toLowerCase()));
}

async function runCanonicalScan(scanRoot, options = {}) {
  if (
    options.allowAuditorDelegation === true &&
    isGeneralAuditorDelegationEnabled()
  ) {
    return {
      ok: true,
      scope: "ci-auditor-gate",
      failures: []
    };
  }
  const environment = options.environment || process.env;
  const ci = isCI(environment);
  const configuredRoot = environment.GENERAL_AUDITOR_ROOT;
  const unavailable = () => ({
    ok: false, scannedFiles: 0,
    failures: [redactedFailure("LICOMESH_DEV_UNAVAILABLE", ".")]
  });
  if (!configuredRoot || !path.isAbsolute(configuredRoot)) return unavailable();
  const auditorRoot = path.resolve(configuredRoot);
  for (const relative of ["action_entry.py", "profiles/LicoLand/LicoUp.json"]) {
    const metadata = await lstat(path.join(auditorRoot, relative)).catch(() => null);
    if (!metadata?.isFile()) return unavailable();
  }
  let stdout = "";
  let exitCode = 0;
  const output = path.join(scanRoot, ".general-auditor", "local", "scan.json");
  try {
    const result = await execFileAsync("python3", [
      "-I", path.join(auditorRoot, "action_entry.py"), ci ? "check" : "scan", "--repository", "LicoLand/LicoUp", "--directory", scanRoot, "--scope", "worktree", "--policy-root", auditorRoot,
    ], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024
    });
    stdout = result.stdout;
  } catch (error) {
    if (error?.code === "ENOENT") {
      return {
        ok: false,
        scannedFiles: 0,
        failures: [redactedFailure("LICOMESH_DEV_UNAVAILABLE", ".")]
      };
    }
    stdout = typeof error?.stdout === "string" ? error.stdout : "";
    exitCode = Number.isInteger(error?.code) ? error.code : -1;
  }
  // Only the fixed private file contains local findings. CI emits status/counts.
  let summary;
  try { summary = JSON.parse(stdout); } catch { summary = null; }
  if (!summary || typeof summary.status !== "string") {
    return { ok: false, failures: [redactedFailure("LICOMESH_DEV_PROTOCOL_ERROR", ".")] };
  }
  if (ci) return parseCanonicalResult(JSON.stringify({ status: summary.status, findings: [] }), exitCode, scanRoot);
  try { stdout = await readFile(output, "utf8"); } catch { stdout = ""; }
  let result;
  try { result = JSON.parse(stdout); } catch { result = null; }
  if (!result || result.status !== summary.status) {
    return { ok: false, failures: [redactedFailure("LICOMESH_DEV_PROTOCOL_ERROR", ".")] };
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

function buildReport(canonical, local, authoritativeScanner = "general-auditor") {
  const failures = [...canonical.failures, ...local.failures];
  return {
    schemaVersion,
    ok: failures.length === 0,
    authoritativeScanner,
    authoritativeScope: canonical.scope || "execution-error",
    localEvidenceScannedFiles: local.scannedFiles,
    advisorySignals: canonical.signals || [],
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
      '{"status":"completed","findings":[]}',
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

    const canonical = parseCanonicalResult(
      JSON.stringify({ status: "completed_with_warnings", findings: [
        { file: "build/reports/local-info-fixture.json", rule: "system-or-deployment-path" },
        { file: "build/reports/local-info-fixture.json", rule: "secret-assignment" }
      ] }),
      0,
      temporary
    );
    const local = await scanEvidenceFiles(temporary);
    const report = buildReport(canonical, local);
    const reasonCodes = new Set(report.failures.map((failure) => failure.reasonCode));
    requireSelfTest(report.ok === false, "SELF_TEST_DID_NOT_REJECT_FIXTURE");
    requireSelfTest(report.advisorySignals.length === 2, "SELF_TEST_SIGNALS_NOT_RETAINED");
    requireSelfTest(
      canonical.ok === true,
      "SELF_TEST_ADVISORY_SIGNAL_BLOCKED"
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

    const unavailable = await runCanonicalScan(temporary, { environment: {} });
    requireSelfTest(
      unavailable.ok === false &&
      unavailable.failures.length === 1 &&
      unavailable.failures[0].reasonCode === "LICOMESH_DEV_UNAVAILABLE",
      "SELF_TEST_MISSING_TOOL_NOT_FAIL_CLOSED"
    );
    const trustedRoot = path.join(temporary, "trusted-auditor");
    await mkdir(path.join(trustedRoot, "profiles", "LicoLand"), { recursive: true });
    await writeFile(path.join(trustedRoot, "profiles", "LicoLand", "LicoUp.json"), "{}");
    await writeFile(path.join(trustedRoot, "action_entry.py"), [
      "import json, pathlib, sys",
      "assert sys.flags.isolated == 1",
      "args = sys.argv[1:]",
      "assert args[0] in ('scan', 'check')",
      "assert '--output' not in args and '--html' not in args",
      "assert args[args.index('--repository') + 1] == 'LicoLand/LicoUp'",
      "assert args[args.index('--scope') + 1] == 'worktree'",
      "root = pathlib.Path(__file__).resolve().parent",
      "assert pathlib.Path(args[args.index('--policy-root') + 1]).resolve() == root",
      "assert pathlib.Path(args[args.index('--directory') + 1]).resolve() == root.parent",
      "output = root.parent / '.general-auditor' / 'local' / 'scan.json'",
      "if args[0] == 'scan':",
      "    output.parent.mkdir(parents=True, exist_ok=True)",
      "    output.write_text(json.dumps({'status': 'completed', 'findings': []}))",
      "else: assert not output.exists()",
      "print(json.dumps({'status': 'completed', 'findings': 0, 'agent_review': 'not_performed'}))",
    ].join("\n"));
    const trusted = await runCanonicalScan(temporary, {
      environment: { GENERAL_AUDITOR_ROOT: trustedRoot }
    });
    requireSelfTest(trusted.ok === true, "SELF_TEST_TRUSTED_ROOT_INVOCATION_INVALID");
    await rm(path.join(temporary, ".general-auditor"), { recursive: true, force: true });
    const ciChecked = await runCanonicalScan(temporary, {
      environment: { GENERAL_AUDITOR_ROOT: trustedRoot, CI: "true" }
    });
    requireSelfTest(ciChecked.ok === true, "SELF_TEST_CI_CHECK_CREATED_REPORT");
    await rm(path.join(trustedRoot, "profiles", "LicoLand", "LicoUp.json"));
    const missingProfile = await runCanonicalScan(temporary, {
      environment: { GENERAL_AUDITOR_ROOT: trustedRoot }
    });
    requireSelfTest(missingProfile.failures[0]?.reasonCode === "LICOMESH_DEV_UNAVAILABLE",
      "SELF_TEST_MISSING_PROFILE_NOT_REJECTED");
    requireSelfTest(
      isGeneralAuditorDelegationEnabled({
        GENERAL_AUDITOR_GATE_DELEGATED: "1",
        GITHUB_ACTIONS: "true",
        GITHUB_WORKFLOW: "Client CI",
        GITHUB_JOB: "engineering"
      }),
      "SELF_TEST_GITHUB_AUDITOR_DELEGATION_REJECTED"
    );
    for (const incompleteEnvironment of [
      {
        GITHUB_ACTIONS: "true",
        GITHUB_WORKFLOW: "Client CI",
        GITHUB_JOB: "engineering"
      },
      {
        GENERAL_AUDITOR_GATE_DELEGATED: "1",
        GITHUB_WORKFLOW: "Client CI",
        GITHUB_JOB: "engineering"
      },
      {
        GENERAL_AUDITOR_GATE_DELEGATED: "1",
        GITHUB_ACTIONS: "true",
        GITHUB_WORKFLOW: "Another workflow",
        GITHUB_JOB: "engineering"
      },
      {
        GENERAL_AUDITOR_GATE_DELEGATED: "1",
        GITHUB_ACTIONS: "true",
        GITHUB_WORKFLOW: "Client CI",
        GITHUB_JOB: "source"
      }
    ]) {
      requireSelfTest(
        !isGeneralAuditorDelegationEnabled(incompleteEnvironment),
        "SELF_TEST_AUDITOR_DELEGATION_SCOPE_TOO_BROAD"
      );
    }

    return {
      schemaVersion,
      ok: true,
      checks: {
        canonicalCleanProtocolResultAccepted: true,
        canonicalSensitiveFindingProtocolAccepted: true,
        localScannerRejectedDeviceAndRuntimeIdentity: true,
        reportDidNotRediscloseMatches: true,
        missingCanonicalScannerFailedClosed: true,
        trustedRootAndRepositoryProfileRequired: true,
        localReportsFixedAndCICheckOnly: true,
        auditorDelegationRestrictedToClientGitHubJob: true,
        exactAuditorProtocolAccepted: true
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
  let candidateRoot = "";
  let canonical;
  let local;
  try {
    candidateRoot = await materializePublicationCandidateRoot();
    canonical = await runCanonicalScan(repoRoot, {
      allowAuditorDelegation: true
    });
    local = await scanEvidenceFiles(candidateRoot);
  } catch {
    canonical = {
      ok: false,
      scannedFiles: 0,
      failures: [redactedFailure("LICOMESH_DEV_CANDIDATE_SCAN_FAILED", ".")]
    };
    local = { scannedFiles: 0, failures: [] };
  } finally {
    if (candidateRoot) {
      await rm(candidateRoot, { recursive: true, force: true });
    }
  }
  const report = buildReport(
    canonical,
    local,
    "general-auditor"
  );
  if (!isCI()) {
    await mkdir(path.dirname(reportPath), { recursive: true });
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
  }
  console.log(JSON.stringify({ ok: report.ok, findings: report.findingCount, advisorySignals: report.advisorySignals.length }));
  if (!report.ok) {
    process.exit(1);
  }
}
