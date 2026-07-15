#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { loadSecureClientContract } from "./lib/secure-client-contract.mjs";
import { createSecureClientMeshE2eeRefReportScope } from "./lib/secure-client-mesh-e2ee-ref-report.mjs";
import { secureClientRelayMockE2eReady } from "./lib/secure-client-relay-mock-e2e-report.mjs";
import { loadSecureMeshReleaseProofConfig } from "./lib/secure-mesh-release-proof-config.mjs";
import { atomicWriteReportJson, resolveSafeReportPath } from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const releaseProofConfig = await loadSecureMeshReleaseProofConfig();
const reportPath = releaseProofConfig.reportOutput;
const {
  updateRelease: updateReleaseReportPath,
  physicalMatrix: physicalMatrixReportPath,
  androidPhysicalInstallLaunch: androidPhysicalInstallLaunchReportPath,
  physicalEvidenceManifest: physicalEvidenceManifestReportPath,
  windowsImplementation: windowsImplementationReportPath,
  reportRedaction: reportRedactionReportPath,
  relayMock: relayMockReportPath,
  rustCrypto: rustCryptoReportPath,
  platformCrypto: platformCryptoReportPath,
  androidPlatformCrypto: androidPlatformCryptoReportPath
} = releaseProofConfig.inputReports;
const {
  updateRelease: updateReleaseVerifierCommand,
  physicalEvidenceManifest: physicalEvidenceManifestVerifierCommand,
  reportRedaction: reportRedactionVerifierCommand
} = releaseProofConfig.verifierCommands;
const args = new Set(process.argv.slice(2));
const strict = args.has("--strict");

const leakPatterns = Object.freeze([
  ["local_path", /\/Users\/|\/private\/|\/var\/folders\/|[A-Za-z]:\\/u],
  ["bearer", /Bearer\s+(?!\[redacted\])\S+/u],
  ["token", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u],
  ["pem_material", /-----BEGIN|-----END/u],
  ["adb_public_key", /AAAA[0-9A-Za-z+/]{40,}={0,2}/u],
  ["labeled_device_identifier", /\b(?:UDID|ECID|Serial(?:Number)?|DeviceIdentifier)\s*[:=]\s*[A-Za-z0-9-]{8,}\b/u],
  ["raw_secret_value", /"(?:privateKeyBase64url|signingKeyBase64url|signedPrekeyPrivateKeyBase64url|oneTimePrekeyPrivateKeyBase64url|pairingSecretBase64url|sessionKey|rootKey|chainKey|messageKey)"\s*:\s*"[^"]{8,}"/u],
  ["file_url", /file:\/\/\//u]
]);

const sourceChecks = Object.freeze(releaseProofConfig.sourceChecks);
const freshnessWindows = Object.freeze(releaseProofConfig.freshnessWindows);
const maxReportFutureSkewSeconds = 5 * 60;

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function readJson(relativePath) {
  return JSON.parse(await readText(relativePath));
}

async function readJsonIfPresent(relativePath) {
  try {
    return await readJson(relativePath);
  } catch {
    return null;
  }
}

function dedupeRemainingGates(gates) {
  const seen = new Set();
  return (Array.isArray(gates) ? gates : [])
    .map((gate) => String(gate || "").trim())
    .filter((gate) => {
      if (!gate || seen.has(gate)) {
        return false;
      }
      seen.add(gate);
      return true;
    });
}

function stableStringList(value) {
  return Array.from(
    new Set(
      (Array.isArray(value) ? value : [])
        .map((item) => String(item || "").trim())
        .filter(Boolean)
    )
  ).sort();
}

function consumerVerifiedReleaseArtifacts(updateReport = {}) {
  if (updateReport?.dryRun === true || !Array.isArray(updateReport?.productionArtifacts)) {
    return [];
  }
  return updateReport.productionArtifacts
    .map((artifact) => ({
      targetId: String(artifact?.targetId || "").trim(),
      artifactDigest: String(artifact?.artifactDigest || artifact?.sha256 || "").trim()
    }))
    .filter((artifact) => artifact.targetId);
}

function contractReadinessGates(readiness = {}, label = "evidence report") {
  const gates = [
    ...dedupeRemainingGates(readiness.remainingGates),
    ...stableStringList(readiness.missingRequiredReadyFields)
      .map((field) => `required ready field missing: ${field}`),
    ...stableStringList(readiness.explicitNotReadyFields)
      .map((field) => `ready field explicitly false: ${field}`),
    ...stableStringList(readiness.missingRequiredScopeClaims)
      .map((claim) => `required scope claim missing: ${claim}`),
    ...stableStringList(readiness.missingRequiredScopeEvidenceClaims)
      .map((claim) => `required scope evidence receipt missing: ${claim}`),
    ...stableStringList(readiness.missingRequiredScopeEvidenceAuthorityClaims)
      .map((claim) => `required scope evidence authority missing: ${claim}`),
    ...stableStringList(readiness.missingRequiredScopeEvidenceCheckedAtClaims)
      .map((claim) => `required scope evidence checkedAt missing: ${claim}`),
    ...(readiness.okAccepted === true ? [] : ["ok/verificationOk not accepted"]),
    ...(readiness.schemaMatches === true ? [] : ["evidence-ref schema mismatch"]),
    ...(readiness.sourceOfTruthAccepted === true ? [] : ["sourceOfTruth not accepted"]),
    ...(readiness.blockerMatches === true ? [] : ["blocker mismatch"]),
    ...(readiness.redactionAccepted === true ? [] : ["redaction or raw-material flags not accepted"]),
    ...(readiness.provenanceAccepted === true ? [] : ["provenance/authority proof not accepted"]),
    ...(readiness.freshnessAccepted === true ? [] : ["freshness not accepted"]),
    ...(readiness.blockerSemanticsAccepted === true ? [] : ["blocker semantics not accepted"]),
    ...stableStringList(readiness.freshnessReasons),
    ...stableStringList(readiness.blockerSemanticsReasons)
  ];
  return dedupeRemainingGates(gates).map((gate) => `${label}: ${gate}`);
}

function summarizeContractReadiness(readiness = {}, label = "evidence report") {
  const remainingGates = contractReadinessGates(readiness, label);
  return {
    ready: readiness.ready === true,
    reason: readiness.ready === true ? "evidence-report-ready" : "evidence-report-not-ready",
    okAccepted: readiness.okAccepted === true,
    schemaMatches: readiness.schemaMatches === true,
    sourceOfTruthAccepted: readiness.sourceOfTruthAccepted === true,
    redactionAccepted: readiness.redactionAccepted === true,
    provenanceAccepted: readiness.provenanceAccepted === true,
    freshnessAccepted: readiness.freshnessAccepted === true,
    blockerSemanticsAccepted: readiness.blockerSemanticsAccepted === true,
    evidenceAuthorityAccepted: readiness.evidenceAuthorityAccepted === true,
    authorityProofRequired: readiness.authorityProofRequired === true,
    authorityProofAccepted: readiness.authorityProofAccepted === true,
    remainingGates,
    remainingGateCount: remainingGates.length,
    missingRequiredReadyFields: stableStringList(readiness.missingRequiredReadyFields),
    explicitNotReadyFields: stableStringList(readiness.explicitNotReadyFields),
    missingRequiredScopeClaims: stableStringList(readiness.missingRequiredScopeClaims),
    missingRequiredScopeEvidenceClaims:
      stableStringList(readiness.missingRequiredScopeEvidenceClaims)
  };
}

async function sha256FileIfPresent(relativePath) {
  try {
    const text = await fs.readFile(path.join(repoRoot, relativePath), "utf8");
    return `sha256:${createHash("sha256").update(text, "utf8").digest("hex")}`;
  } catch (error) {
    if (error?.code === "ENOENT") {
      return "";
    }
    throw error;
  }
}

async function evaluateSourceCheck(check) {
  const source = await readText(check.file);
  const missingTokens = check.tokens.filter((token) => !source.includes(token));
  return {
    id: check.id,
    file: check.file,
    ok: missingTokens.length === 0,
    missingTokens
  };
}

function runConfiguredVerifier(verifierCommand, { env = {} } = {}) {
  const started = Date.now();
  const commandArgs = [verifierCommand.script, ...verifierCommand.args];
  const result = spawnSync(process.execPath, commandArgs, {
    cwd: repoRoot,
    env: {
      ...process.env,
      ...env
    },
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024
  });
  return {
    id: verifierCommand.id,
    command: verifierCommand.command,
    ok: result.status === 0,
    exitCode: result.status ?? 1,
    durationMs: Date.now() - started,
    outputSummary: result.status === 0 ? summarizeOutput(result.stdout) : sanitizeError(result.stderr || result.stdout)
  };
}

function runUpdateReleaseVerifier() {
  return runConfiguredVerifier(updateReleaseVerifierCommand);
}

function runPhysicalEvidenceManifestVerifier() {
  return runConfiguredVerifier(physicalEvidenceManifestVerifierCommand);
}

function runReportRedactionVerifier(redactionRunId) {
  const result = runConfiguredVerifier(reportRedactionVerifierCommand, {
    env: {
      [reportRedactionVerifierCommand.runIdEnv]: redactionRunId
    }
  });
  return {
    ...result,
    redactionRunId
  };
}

function summarizeOutput(value = "") {
  return String(value || "")
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .slice(0, 4)
    .join("\n");
}

function summarizeProductionClosureStatus(status = {}) {
  const installerExecutionStatus = status.installerExecutionStatus || {};
  const androidProductionUpdateStatus = status.androidProductionUpdateStatus || {};
  return {
    present: Boolean(status && Object.keys(status).length > 0),
    rawProductionKeyMaterialIncluded: status.rawProductionKeyMaterialIncluded === true,
    productionInstallerExecutionReady: status.productionInstallerExecutionReady === true,
    dryRunPlansCoverTargetLabels: installerExecutionStatus.dryRunPlansCoverTargetLabels === true,
    productionHostExecutionReady: installerExecutionStatus.productionHostExecutionReady === true,
    dryRunPlanCount: Number(installerExecutionStatus.dryRunPlanCount || 0),
    productionTargetCount: Number(installerExecutionStatus.productionTargetCount || 0),
    androidPhysicalInstallLaunchReady: androidProductionUpdateStatus.physicalInstallLaunchReady === true
  };
}

function reportRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function summarizeUpdateReport(report = {}) {
  report = reportRecord(report);
  const positiveChecks = Array.isArray(report.positiveChecks) ? report.positiveChecks : [];
  const negativeChecks = Array.isArray(report.negativeChecks) ? report.negativeChecks : [];
  const macosReleaseBundleEvidence = summarizeMacosReleaseBundleEvidence(report.macosReleaseBundleEvidence);
  const productionClosureStatus = summarizeProductionClosureStatus(report.productionClosureStatus);
  return {
    ok: report.ok === true,
    productionReady: report.productionReady === true,
    dryRun: report.dryRun === true,
    targetCount: Array.isArray(report.productionTargetLabels) ? report.productionTargetLabels.length : 0,
    productionTargetLabels: (Array.isArray(report.productionTargetLabels) ? report.productionTargetLabels : [])
      .map((item) => String(item || "").trim())
      .filter(Boolean),
    productionArtifacts: report.dryRun === true
      ? []
      : consumerVerifiedReleaseArtifacts(report),
    productionInstallerExecutionReady: productionClosureStatus.productionInstallerExecutionReady === true,
    signedRevocationVerified: positiveChecks.some((item) => item?.name === "signed revocation list verifies" && item.ok === true),
    macosActualReleaseBundleVerified: macosReleaseBundleEvidence.localBundleShapeVerified === true,
    macosReleaseBundleEvidence,
    productionClosureStatus,
    downgradeRejected: negativeChecks.some((item) => item?.name === "downgrade is rejected without signed policy allowance" && item.ok === true),
    tamperRejected: negativeChecks.some((item) => item?.name === "tampered manifest signature is rejected" && item.ok === true),
    unsupportedPlatformRejected: negativeChecks.some((item) => item?.name === "unsupported platform is rejected" && item.ok === true)
  };
}

function summarizeMacosReleaseBundleEvidence(evidence = {}) {
  evidence = reportRecord(evidence);
  const artifacts = Array.isArray(evidence.artifacts) ? evidence.artifacts : [];
  return {
    present: Boolean(evidence && Object.keys(evidence).length > 0),
    attempted: evidence.attempted === true,
    ok: evidence.ok === true,
    localBundleShapeVerified: evidence.ok === true &&
      evidence.dryRun === false &&
      evidence.artifactKind === "actual-release-bundle" &&
      evidence.signingKind === "local-ad-hoc-codesign" &&
      evidence.verificationExitCode === 0 &&
      evidence.codesignVerifyExitCode === 0 &&
      artifacts.length >= 2 &&
      artifacts.every((artifact) =>
        artifact?.platform === "macos" &&
        artifact?.mode === "release" &&
        artifact?.signingKind === "local-ad-hoc-codesign" &&
        artifact?.productionEntitlementsRequested === true &&
        artifact?.entitlementProfile === "production-release" &&
        artifact?.entitlementsFile === "apps/desktop/macos/Runner/ProductionRelease.entitlements" &&
        Number(artifact?.flutterExecutableBytes || 0) > 0 &&
        Number(artifact?.licoClientBytes || 0) > 0
      ),
    status: String(evidence.status || ""),
    artifactKind: String(evidence.artifactKind || ""),
    signingKind: String(evidence.signingKind || ""),
    gatekeeperVerified: evidence.gatekeeperVerified === true,
    productionEntitlementsRequested:
      artifacts.every((artifact) => artifact?.productionEntitlementsRequested === true),
    productionEntitlementProfileReady:
      artifacts.every((artifact) => artifact?.entitlementProfile === "production-release"),
    productionEntitlementsFileReady:
      artifacts.every((artifact) => artifact?.entitlementsFile === "apps/desktop/macos/Runner/ProductionRelease.entitlements"),
    artifactCount: artifacts.length,
    artifactKinds: artifacts.map((artifact) => String(artifact?.kind || "")).filter(Boolean),
    remainingProductionProofCount: Array.isArray(evidence.remainingProductionProofs)
      ? evidence.remainingProductionProofs.length
      : 0
  };
}

function releaseInputIntegrity(report = {}, {
  schemaVersion,
  verifier,
  generatedBy = verifier,
  blocker: expectedBlocker = "physical device matrix"
} = {}) {
  report = reportRecord(report);
  const present = Boolean(report && Object.keys(report).length > 0);
  const failures = [];
  if (!present) {
    failures.push("report_present");
  }
  if (schemaVersion && report?.schemaVersion !== schemaVersion) {
    failures.push("schemaVersion");
  }
  if (report?.evidenceRefSchemaVersion !== SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION) {
    failures.push("evidenceRefSchemaVersion");
  }
  if (report?.sourceOfTruth !== SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH) {
    failures.push("sourceOfTruth");
  }
  if (verifier && report?.verifier !== verifier) {
    failures.push("verifier");
  }
  if (generatedBy && report?.generatedBy !== generatedBy) {
    failures.push("generatedBy");
  }
  if (expectedBlocker && report?.blocker !== expectedBlocker) {
    failures.push("blocker");
  }
  if (report?.redacted !== true || report?.reportLeakScan !== true) {
    failures.push("redaction");
  }
  if (
    report?.rawPrivateMaterialIncluded === true ||
    report?.rawPlaintextIncluded === true ||
    report?.rawPublicWireBytesIncluded === true
  ) {
    failures.push("rawMaterialFlags");
  }
  return {
    ok: failures.length === 0,
    present,
    failures,
    failureCount: failures.length,
    status: failures.length === 0 ? "current" : "schema_or_source_mismatch"
  };
}

function evaluateReportFreshness(report = {}, {
  label,
  maxAgeSeconds,
  checkedAt
} = {}) {
  report = reportRecord(report);
  const present = Boolean(report && Object.keys(report).length > 0);
  const timestampField = Object.prototype.hasOwnProperty.call(report, "generatedAt")
    ? "generatedAt"
    : Object.prototype.hasOwnProperty.call(report, "checkedAt")
      ? "checkedAt"
      : "";
  const timestamp = timestampField ? String(report[timestampField] || "") : "";
  const timestampMs = Date.parse(timestamp);
  const checkedAtMs = Date.parse(checkedAt);
  const nowMs = Number.isFinite(checkedAtMs) ? checkedAtMs : Date.now();
  const ageSeconds = Number.isFinite(timestampMs)
    ? Math.floor((nowMs - timestampMs) / 1000)
    : null;
  const freshUntilMs = Number.isFinite(timestampMs)
    ? timestampMs + (Number(maxAgeSeconds || 0) * 1000)
    : NaN;
  const failures = [];
  if (!present) {
    failures.push("report_present");
  }
  if (!timestampField) {
    failures.push("timestamp_present");
  }
  if (timestampField && !Number.isFinite(timestampMs)) {
    failures.push("timestamp_parseable");
  }
  if (Number.isFinite(timestampMs) && timestampMs - nowMs > maxReportFutureSkewSeconds * 1000) {
    failures.push("timestamp_not_future");
  }
  if (Number.isFinite(timestampMs) && nowMs - timestampMs > Number(maxAgeSeconds || 0) * 1000) {
    failures.push("timestamp_not_stale");
  }
  const ready = failures.length === 0;
  return {
    label,
    ready,
    status: ready
      ? "current"
      : failures.includes("report_present")
        ? "missing_report"
        : failures.includes("timestamp_not_stale")
        ? "stale"
        : failures.includes("timestamp_not_future")
          ? "future"
          : failures.includes("timestamp_parseable")
            ? "invalid_timestamp"
            : failures.includes("timestamp_present")
              ? "missing_timestamp"
              : "unknown",
    timestampField,
    generatedAt: timestamp,
    checkedAt,
    maxAgeSeconds: Number(maxAgeSeconds || 0),
    maxFutureSkewSeconds: maxReportFutureSkewSeconds,
    ageSeconds,
    freshUntil: Number.isFinite(freshUntilMs) ? new Date(freshUntilMs).toISOString() : "",
    failures,
    failureCount: failures.length
  };
}

function summarizeReleaseInputFreshness({
  updateRelease = {},
  physicalMatrix = {},
  androidPhysicalInstallLaunch = {},
  physicalEvidenceManifest = {}
} = {}, checkedAt) {
  const checks = [
    evaluateReportFreshness(updateRelease, {
      label: "update release report",
      maxAgeSeconds: freshnessWindows.updateReleaseSeconds,
      checkedAt
    }),
    evaluateReportFreshness(physicalMatrix, {
      label: "physical device matrix report",
      maxAgeSeconds: freshnessWindows.physicalMatrixSeconds,
      checkedAt
    }),
    evaluateReportFreshness(androidPhysicalInstallLaunch, {
      label: "Android physical install/launch report",
      maxAgeSeconds: freshnessWindows.androidPhysicalInstallLaunchSeconds,
      checkedAt
    }),
    evaluateReportFreshness(physicalEvidenceManifest, {
      label: "physical evidence manifest report",
      maxAgeSeconds: freshnessWindows.physicalEvidenceManifestSeconds,
      checkedAt
    })
  ];
  const failed = checks.filter((check) => check.ready !== true);
  return {
    ready: failed.length === 0,
    checkedAt,
    checkCount: checks.length,
    currentCount: checks.length - failed.length,
    staleOrInvalidCount: failed.length,
    failedLabels: failed.map((check) => check.label),
    checks,
    remainingGates: failed.map((check) => `fresh release input required: ${check.label}`)
  };
}

function runReleaseInputFreshnessSelfTest() {
  const checkedAt = "2026-07-07T12:00:00.000Z";
  const current = evaluateReportFreshness({ generatedAt: "2026-07-07T11:59:00.000Z" }, {
    label: "self-test current",
    maxAgeSeconds: 300,
    checkedAt
  });
  const stale = evaluateReportFreshness({ generatedAt: "2026-07-07T11:00:00.000Z" }, {
    label: "self-test stale",
    maxAgeSeconds: 300,
    checkedAt
  });
  const future = evaluateReportFreshness({ generatedAt: "2026-07-07T12:10:01.000Z" }, {
    label: "self-test future",
    maxAgeSeconds: 300,
    checkedAt
  });
  const missing = evaluateReportFreshness({}, {
    label: "self-test missing",
    maxAgeSeconds: 300,
    checkedAt
  });
  const nullMissing = evaluateReportFreshness(null, {
    label: "self-test null missing",
    maxAgeSeconds: 300,
    checkedAt
  });
  const invalid = evaluateReportFreshness({ generatedAt: "not-a-date" }, {
    label: "self-test invalid",
    maxAgeSeconds: 300,
    checkedAt
  });
  const ok = current.ready === true &&
    stale.ready === false &&
    stale.status === "stale" &&
    future.ready === false &&
    future.status === "future" &&
    missing.ready === false &&
    missing.status === "missing_report" &&
    nullMissing.ready === false &&
    nullMissing.status === "missing_report" &&
    invalid.ready === false &&
    invalid.status === "invalid_timestamp";
  return {
    ok,
    currentAccepted: current.ready === true,
    staleRejected: stale.ready === false,
    futureRejected: future.ready === false,
    missingRejected: missing.ready === false,
    nullMissingRejected: nullMissing.ready === false,
    invalidTimestampRejected: invalid.ready === false
  };
}

function summarizePhysicalMatrixReport(report = {}) {
  report = reportRecord(report);
  const inputIntegrity = releaseInputIntegrity(report, {
    schemaVersion: "licolite.secure-mesh.physical-device-matrix-report.v2",
    verifier: "tools/scripts/client-secure-mesh-physical-device-matrix.mjs"
  });
  const summary = inputIntegrity.ok ? (report.summary || {}) : {};
  return {
    inputIntegrityReady: inputIntegrity.ok,
    inputSchemaStatus: inputIntegrity.status,
    inputSchemaFailureCount: inputIntegrity.failureCount,
    inputSchemaFailures: inputIntegrity.failures,
    ok: inputIntegrity.ok && report.ok === true,
    diagnosticOk: inputIntegrity.ok &&
      (report.diagnosticOk === true || summary.diagnosticOk === true || report.ok === true),
    productionReady: inputIntegrity.ok && report.productionReady === true,
    releaseReady: inputIntegrity.ok && report.releaseReady === true,
    allPhysicalScenariosReady:
      inputIntegrity.ok &&
      (report.allPhysicalScenariosReady === true ||
        summary.allPhysicalScenariosReady === true),
	    physicalEvidenceChainReady:
	      inputIntegrity.ok &&
	      (report.physicalEvidenceChainReady === true ||
	        summary.physicalEvidenceChainReady === true),
	    localPhysicalEvidenceChainReadyDiagnostic:
	      inputIntegrity.ok &&
	      (report.physicalEvidenceChainReady === true ||
	        summary.physicalEvidenceChainReady === true),
	    evidenceChainComplete:
	      inputIntegrity.ok &&
	      (report.evidenceChainComplete === true ||
	        summary.evidenceChainComplete === true),
	    localEvidenceChainCompleteDiagnostic:
	      inputIntegrity.ok &&
	      (report.evidenceChainComplete === true ||
	        summary.evidenceChainComplete === true),
	    releaseEvidenceReady:
	      inputIntegrity.ok &&
	      (report.releaseEvidenceReady === true ||
	        summary.releaseEvidenceReady === true),
	    localReleaseEvidenceReadyDiagnostic:
	      inputIntegrity.ok &&
	      (report.releaseEvidenceReady === true ||
	        summary.releaseEvidenceReady === true),
    diagnosticStatus: String(report.diagnosticStatus || ""),
    physicalScenarioCount: Number(summary.physicalScenarioCount || 0),
    partialScenarioCount: Number(summary.partialScenarioCount || 0),
    missingScenarioCount: Number(summary.missingScenarioCount || 0),
    evidenceReportCount: Number(summary.evidenceReportCount || 0),
    androidPlatformSecretStoreReady: summary.androidPlatformSecretStoreReady === true,
    androidPhysicalSecretStoreBindingReady:
      summary.androidPhysicalSecretStoreBindingReady === true,
	    androidPhysicalSystemCredentialAuthReady:
	      summary.androidPhysicalSystemCredentialAuthReady === true,
    androidPhysicalKeyStoreHardwareAuthReady:
      summary.androidPhysicalKeyStoreHardwareAuthReady === true,
    androidPhysicalKeyStoreSecurityLevelName:
      String(summary.androidPhysicalKeyStoreSecurityLevelName || ""),
    androidPhysicalKeyStoreInsideSecureHardware:
      summary.androidPhysicalKeyStoreInsideSecureHardware === true,
    androidPhysicalKeyStoreUserAuthenticationHardwareEnforced:
      summary.androidPhysicalKeyStoreUserAuthenticationHardwareEnforced === true,
    androidPhysicalKeyStoreUnlockedDeviceRequired:
      summary.androidPhysicalKeyStoreUnlockedDeviceRequired === true,
	    androidPhysicalCallbackContractReady:
	      summary.androidPhysicalCallbackContractReady === true,
    androidPhysicalRawJsonSecretOverridesProvenAbsent:
      summary.androidPhysicalRawJsonSecretOverridesProvenAbsent === true,
    androidPhysicalRawJsonSecretOverridesUsed:
      summary.androidPhysicalRawJsonSecretOverridesUsed === true,
    androidPhysicalRawJsonSecretOverridesUnknown:
      summary.androidPhysicalRawJsonSecretOverridesUnknown === true,
    androidPhysicalInstallLaunchSchemaDrift:
      summary.androidPhysicalInstallLaunchSchemaDrift === true,
    androidPhysicalInstallLaunchSchemaDriftFieldCount:
      Number(summary.androidPhysicalInstallLaunchSchemaDriftFieldCount || 0),
    androidPhysicalInstallLaunchSchemaStatus:
      String(summary.androidPhysicalInstallLaunchSchemaStatus || "unknown"),
    androidPhysicalAppPasswordPromptUsed:
      summary.androidPhysicalAppPasswordPromptUsed === true,
	    androidPhysicalMissingFieldsAbsent:
	      summary.androidPhysicalMissingFieldsAbsent === true,
	    androidPhysicalMissingFieldAuditPresent:
	      summary.androidPhysicalMissingFieldAuditPresent === true,
	    androidPhysicalMissingFields:
	      stableStringList(summary.androidPhysicalMissingFields),
	    androidPhysicalMissingFieldCount:
	      Number(summary.androidPhysicalMissingFieldCount || 0),
	    androidPhysicalWeakProofFieldsAbsent:
	      summary.androidPhysicalWeakProofFieldsAbsent === true,
	    androidPhysicalWeakProofFieldAuditPresent:
	      summary.androidPhysicalWeakProofFieldAuditPresent === true,
	    androidPhysicalWeakProofFields:
	      stableStringList(summary.androidPhysicalWeakProofFields),
	    androidPhysicalWeakProofFieldCount:
	      Number(summary.androidPhysicalWeakProofFieldCount || 0),
    iosPlatformSecretStoreReady: summary.iosPlatformSecretStoreReady === true,
    iosPhysicalSecretStoreBindingReady:
      summary.iosPhysicalSecretStoreBindingReady === true,
	    iosUserPresencePolicyReady:
	      summary.iosUserPresencePolicyReady === true,
	    iosProductionCallbackAuthReady:
	      summary.iosProductionCallbackAuthReady === true,
	    iosCallbackReadsUseSharedLAContext:
	      summary.iosCallbackReadsUseSharedLAContext === true,
	    iosSingleSystemAuthorizationContextVerified:
	      summary.iosSingleSystemAuthorizationContextVerified === true,
	    iosCallbackAuthContextAttachedToAllReads:
	      summary.iosCallbackAuthContextAttachedToAllReads === true,
	    appPasswordPromptUsedPresent:
	      summary.appPasswordPromptUsedPresent === true,
	    appCredentialPromptUsedPresent:
	      summary.appCredentialPromptUsedPresent === true,
	    keyMaterialExportedPresent:
	      summary.keyMaterialExportedPresent === true,
	    iosSystemLocalAuthPromptReady:
	      summary.iosSystemLocalAuthPromptReady === true,
    iosKeychainAccessControlNotDowngraded:
      summary.iosKeychainAccessControlNotDowngraded === true,
    iosNonInteractiveFailClosedReady:
      summary.iosNonInteractiveFailClosedReady === true,
    iosCancelLockFailClosedReady:
      summary.iosCancelLockFailClosedReady === true,
    iosAppPasswordPromptUsed:
      summary.iosAppPasswordPromptUsed === true,
    iosAppCredentialPromptUsed:
      summary.iosAppCredentialPromptUsed === true,
    iosKeyMaterialExported:
      summary.iosKeyMaterialExported === true,
	    iosPhysicalCallbackContractReady:
	      summary.iosPhysicalCallbackContractReady === true,
	    iosPhysicalRawJsonSecretOverridesProvenAbsent:
	      summary.iosPhysicalRawJsonSecretOverridesProvenAbsent === true,
	    macosProductionEntitlementFailClosedReady:
	      summary.macosProductionEntitlementFailClosedReady === true,
	    macosProductionEntitlementGateAccepted:
	      summary.macosProductionEntitlementGateAccepted === true,
	    macosProductionEntitlementMissingFailClosed:
	      summary.macosProductionEntitlementMissingFailClosed === true,
	    macosStandardKeychainRejectedForProduction:
	      summary.macosStandardKeychainRejectedForProduction === true,
	    macosStandardKeychainUserPresenceAcceptedForProduction:
	      summary.macosStandardKeychainUserPresenceAcceptedForProduction === true,
	    macosStandardKeychainFallbackFailClosedReady:
	      summary.macosStandardKeychainFallbackFailClosedReady === true,
	    macosUserPresencePolicyReady: summary.macosUserPresencePolicyReady === true,
    macosSingleSystemAuthorizationContextVerified:
      summary.macosSingleSystemAuthorizationContextVerified === true,
    macosInteractiveAuthorizationPromptBudgetReady:
      summary.macosInteractiveAuthorizationPromptBudgetReady === true,
    macosInteractiveAuthorizationAttemptCount:
      Number(summary.macosInteractiveAuthorizationAttemptCount || 0),
    macosMaximumInteractiveAuthorizationAttemptsPerProof:
      Number(summary.macosMaximumInteractiveAuthorizationAttemptsPerProof || 1),
    macosAppCredentialPromptUsed: summary.macosAppCredentialPromptUsed === true,
    macosAppPasswordPromptUsed: summary.macosAppPasswordPromptUsed === true,
    macosSystemCredentialEntrySurface:
      String(summary.macosSystemCredentialEntrySurface || ""),
    remainingGates: Array.isArray(summary.remainingGates)
      ? dedupeRemainingGates(summary.remainingGates)
      : [],
    remainingGateCount: Array.isArray(summary.remainingGates)
      ? dedupeRemainingGates(summary.remainingGates).length
      : 0
  };
}

function summarizeAndroidPhysicalInstallLaunchReport(report = {}) {
  report = reportRecord(report);
  const summary = report?.summary || {};
  const runtimeStatus = report?.runtimeStatus || {};
  const mobileRelaySecretStore = runtimeStatus.mobileRelaySecretStore || {};
  const present = Boolean(report && Object.keys(report).length > 0);
  const mobileRelaySecretStoreContractReady =
    mobileRelaySecretStore.provider === "AndroidKeyStore" &&
    mobileRelaySecretStore.ffiBoundary === "jni" &&
    mobileRelaySecretStore.secretTransport === "platform_keyring_to_rust_ffi_memory_override" &&
    mobileRelaySecretStore.secretStoreBackend === "android-keystore" &&
    mobileRelaySecretStore.secretStoreContract === "rust_secure_mesh_secret_store_handle_v1" &&
    mobileRelaySecretStore.secretStoreAccountPrefix === "mobileRelayE2ee" &&
    mobileRelaySecretStore.secretStoreNamespace === "mobileRelayRuntime" &&
    mobileRelaySecretStore.sharedRustSecretStoreHandleContract === true;
  const rawJsonSecretOverridesUsedPresent =
    Object.prototype.hasOwnProperty.call(mobileRelaySecretStore, "rawJsonSecretOverridesUsed");
  const rawJsonSecretOverridesUnknown = rawJsonSecretOverridesUsedPresent !== true;
  const rawJsonSecretOverridesProvenAbsent =
    rawJsonSecretOverridesUnknown !== true &&
    mobileRelaySecretStore.rawJsonSecretOverridesProvenAbsent === true &&
    mobileRelaySecretStore.rawJsonSecretOverridesUsed === false;
  const keyMaterialExportedPresent =
    Object.prototype.hasOwnProperty.call(mobileRelaySecretStore, "keyMaterialExported");
  const appCredentialPromptUsedPresent =
    Object.prototype.hasOwnProperty.call(mobileRelaySecretStore, "appCredentialPromptUsed");
	  const appPasswordPromptUsedPresent =
	    Object.prototype.hasOwnProperty.call(mobileRelaySecretStore, "appPasswordPromptUsed");
  const androidSystemCredentialAuthReady =
    mobileRelaySecretStore.userAuthenticationRequired === true &&
    mobileRelaySecretStore.credentialEntrySurface === "android_system_credential_prompt" &&
	    appCredentialPromptUsedPresent &&
	    mobileRelaySecretStore.appCredentialPromptUsed === false &&
	    appPasswordPromptUsedPresent &&
	    mobileRelaySecretStore.appPasswordPromptUsed === false &&
		    keyMaterialExportedPresent &&
	    mobileRelaySecretStore.keyMaterialExported === false;
  const localReadyDiagnostic = report?.ok === true &&
    report?.physicalDevice === true &&
    summary.apkReady === true &&
    summary.installReady === true &&
    summary.launchReady === true &&
    summary.runtimeStatusReady === true &&
    summary.nativeRuntimeReady === true &&
    summary.androidKeyStoreReady === true &&
    summary.keyStoreUserAuthReady === true &&
    mobileRelaySecretStoreContractReady &&
    rawJsonSecretOverridesProvenAbsent &&
    androidSystemCredentialAuthReady;
  return {
    report: androidPhysicalInstallLaunchReportPath,
    present,
    ok: report?.ok === true,
    physicalDevice: report?.physicalDevice === true,
    packageName: String(report?.packageName || ""),
    apkReady: summary.apkReady === true,
    installReady: summary.installReady === true,
    launchReady: summary.launchReady === true,
    runtimeStatusReady: summary.runtimeStatusReady === true,
    nativeRuntimeReady: summary.nativeRuntimeReady === true,
    androidKeyStoreReady: summary.androidKeyStoreReady === true,
    keyStoreUserAuthReady: summary.keyStoreUserAuthReady === true,
    mobileRelaySecretStoreContractReady,
    rawJsonSecretOverridesUnknown,
    rawJsonSecretOverridesProvenAbsent,
    keyMaterialExportedPresent,
    keyMaterialExported: mobileRelaySecretStore.keyMaterialExported === true,
    appCredentialPromptUsed:
      mobileRelaySecretStore.appCredentialPromptUsed === true,
    appCredentialPromptUsedPresent,
	    appPasswordPromptUsed:
	      mobileRelaySecretStore.appPasswordPromptUsed === true,
	    appPasswordPromptUsedPresent,
	    androidSystemCredentialAuthReady,
	    localReadyDiagnostic
	  };
	}

function summarizePhysicalEvidenceManifest(report = {}) {
  report = reportRecord(report);
  const inputIntegrity = releaseInputIntegrity(report, {
    schemaVersion: "licolite.secure-mesh.physical-evidence-manifest-report.v2",
    verifier: "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs"
  });
  const summary = inputIntegrity.ok ? (report?.summary || {}) : {};
  const present = Boolean(report && Object.keys(report).length > 0);
	  const artifactDigests = inputIntegrity.ok && Array.isArray(report?.artifactDigests) ? report.artifactDigests : [];
	  const platformCoverage = inputIntegrity.ok && Array.isArray(report?.platformCoverage) ? report.platformCoverage : [];
	  const androidCoverage = platformCoverage.find((item) => item?.platform === "android") || {};
	  const macosCoverage = platformCoverage.find((item) => item?.platform === "macos") || {};
  const ubuntuCoverage = platformCoverage.find((item) => item?.platform === "ubuntu-linux") || {};
  const iosCoverage = platformCoverage.find((item) => item?.platform === "ios") || {};
  const redactionReady = inputIntegrity.ok &&
    (report?.redactionReady === true || summary.redactionReady === true);
  const manifestIntegrityReady =
    inputIntegrity.ok &&
    (report?.manifestIntegrityReady === true || summary.manifestIntegrityReady === true);
  const physicalEvidenceChainReady =
    inputIntegrity.ok &&
    (report?.physicalEvidenceChainReady === true || summary.physicalEvidenceChainReady === true);
  const evidenceChainComplete =
    inputIntegrity.ok &&
    (report?.evidenceChainComplete === true || summary.evidenceChainComplete === true);
  const releaseEvidenceReady =
    inputIntegrity.ok &&
    (report?.releaseEvidenceReady === true ||
      summary.releaseEvidenceReady === true);
  const diagnosticIntegrityReady = present &&
    inputIntegrity.ok &&
    (report?.ok === true || report?.diagnosticOk === true || summary.diagnosticOk === true) &&
    redactionReady &&
    manifestIntegrityReady &&
    summary.allConfiguredReportsPresent === true;
	  const androidSystemCredentialNoAppCredentialCollection =
	    Object.prototype.hasOwnProperty.call(summary, "androidUserAuthenticationAppLockScreenCredentialCollection") &&
	    summary.androidUserAuthenticationAppLockScreenCredentialCollection === false &&
	    Object.prototype.hasOwnProperty.call(summary, "androidUserAuthenticationAppCredentialPromptUsed") &&
	    summary.androidUserAuthenticationAppCredentialPromptUsed === false &&
	    Object.prototype.hasOwnProperty.call(summary, "androidUserAuthenticationAppPasswordPromptUsed") &&
	    summary.androidUserAuthenticationAppPasswordPromptUsed === false &&
	    Object.prototype.hasOwnProperty.call(summary, "androidUserAuthenticationKeyMaterialExported") &&
	    summary.androidUserAuthenticationKeyMaterialExported === false;
	  const androidSystemCredentialReleaseReady = inputIntegrity.ok &&
	    summary.androidPhysicalSystemCredentialAuthReady === true &&
    summary.androidPhysicalKeyStoreHardwareAuthReady === true &&
	    summary.androidUserAuthenticationSystemAuthenticationOnly === true &&
	    String(summary.androidUserAuthenticationCredentialEntrySurface || "") === "android_system_credential_prompt" &&
	    androidSystemCredentialNoAppCredentialCollection &&
	    summary.androidPhysicalRawJsonSecretOverridesProvenAbsent === true &&
    summary.androidPhysicalMissingFieldAuditPresent === true &&
    summary.androidPhysicalMissingFieldsAbsent === true &&
    summary.androidPhysicalWeakProofFieldAuditPresent === true &&
    summary.androidPhysicalWeakProofFieldsAbsent === true;
	  const macosSingleSystemAuthorizationReleaseReady = inputIntegrity.ok &&
	    (macosCoverage.userPresencePolicyReady === true || summary.macosUserPresencePolicyReady === true) &&
	    (macosCoverage.productionEntitlementGateAccepted === true ||
	      summary.macosProductionEntitlementGateAccepted === true) &&
	    (macosCoverage.standardKeychainFallbackFailClosedReady === true ||
	      summary.macosStandardKeychainFallbackFailClosedReady === true) &&
	    macosCoverage.standardKeychainUserPresenceAcceptedForProduction !== true &&
	    summary.macosStandardKeychainUserPresenceAcceptedForProduction !== true &&
	    (macosCoverage.singleSystemAuthorizationContextVerified === true ||
	      summary.macosSingleSystemAuthorizationContextVerified === true) &&
    (macosCoverage.interactiveAuthorizationPromptBudgetReady === true ||
      summary.macosInteractiveAuthorizationPromptBudgetReady === true) &&
    (macosCoverage.interactiveAuthorizationCompletedWithinBudget === true ||
      summary.macosInteractiveAuthorizationCompletedWithinBudget === true) &&
    macosCoverage.dataProtectionSecretReadBlockedOrUnavailable !== true &&
    summary.macosDataProtectionSecretReadBlockedOrUnavailable !== true &&
    Number(macosCoverage.interactiveAuthorizationAttemptCount ||
      summary.macosInteractiveAuthorizationAttemptCount ||
      0) === 1 &&
    Number(macosCoverage.maximumInteractiveAuthorizationAttemptsPerProof ||
      summary.macosMaximumInteractiveAuthorizationAttemptsPerProof ||
      1) <= 1 &&
    macosCoverage.appPasswordPromptUsed !== true &&
    summary.macosAppPasswordPromptUsed !== true &&
    macosCoverage.appCredentialPromptUsed !== true &&
    summary.macosAppCredentialPromptUsed !== true &&
    macosCoverage.keyMaterialExported !== true &&
    summary.macosKeyMaterialExported !== true &&
    String(macosCoverage.systemCredentialEntrySurface ||
      summary.macosSystemCredentialEntrySurface ||
      "") === "macos_local_authentication_system_prompt";
  const iosSystemLocalAuthReleaseReady = inputIntegrity.ok &&
    (summary.iosUserPresencePolicyReady === true ||
      iosCoverage.platformUserPresencePolicyReady === true) &&
    (summary.iosProductionCallbackAuthReady === true ||
      iosCoverage.platformProductionCallbackAuthReady === true) &&
    (summary.iosCallbackReadsUseSharedLAContext === true ||
      iosCoverage.platformCallbackReadsUseSharedLAContext === true) &&
    (summary.iosSingleSystemAuthorizationContextVerified === true ||
      iosCoverage.platformSingleSystemAuthorizationContextVerified === true) &&
    (summary.iosCallbackAuthContextAttachedToAllReads === true ||
      iosCoverage.platformCallbackAuthContextAttachedToAllReads === true) &&
    (summary.appPasswordPromptUsedPresent === true ||
      iosCoverage.appPasswordPromptUsedPresent === true) &&
    (summary.appCredentialPromptUsedPresent === true ||
      iosCoverage.appCredentialPromptUsedPresent === true) &&
    (summary.keyMaterialExportedPresent === true ||
      iosCoverage.keyMaterialExportedPresent === true) &&
    (summary.iosSystemLocalAuthPromptReady === true ||
      iosCoverage.platformSystemLocalAuthPromptReady === true) &&
    (summary.iosKeychainAccessControlNotDowngraded === true ||
      iosCoverage.platformKeychainAccessControlNotDowngraded === true) &&
    (summary.iosNonInteractiveFailClosedReady === true ||
      iosCoverage.platformNonInteractiveFailClosedReady === true) &&
    (summary.iosCancelLockFailClosedReady === true ||
      iosCoverage.platformCancelLockFailClosedReady === true) &&
    summary.iosAppPasswordPromptUsed !== true &&
    iosCoverage.appPasswordPromptUsed !== true &&
    summary.iosAppCredentialPromptUsed !== true &&
    iosCoverage.appCredentialPromptUsed !== true &&
    summary.iosKeyMaterialExported !== true &&
    iosCoverage.keyMaterialExported !== true;
  const platformSystemAuthorizationReleaseReady =
    androidSystemCredentialReleaseReady &&
    macosSingleSystemAuthorizationReleaseReady &&
    iosSystemLocalAuthReleaseReady;
  const ready = diagnosticIntegrityReady &&
    releaseEvidenceReady &&
    evidenceChainComplete &&
    platformSystemAuthorizationReleaseReady;
  return {
    report: physicalEvidenceManifestReportPath,
    present,
    inputIntegrityReady: inputIntegrity.ok,
    inputSchemaStatus: inputIntegrity.status,
    inputSchemaFailureCount: inputIntegrity.failureCount,
    inputSchemaFailures: inputIntegrity.failures,
	    ok: inputIntegrity.ok && report?.ok === true,
	    ready,
	    localReadyDiagnostic: ready,
	    diagnosticIntegrityReady,
    platformSystemAuthorizationReleaseReady,
    androidSystemCredentialReleaseReady,
    macosSingleSystemAuthorizationReleaseReady,
    iosSystemLocalAuthReleaseReady,
    diagnosticOk: inputIntegrity.ok &&
      (report?.diagnosticOk === true || summary.diagnosticOk === true || report?.ok === true),
    okMeaning: String(report?.okMeaning || summary.okMeaning || ""),
    redacted: inputIntegrity.ok && report?.redacted === true,
    redactionReady,
    manifestIntegrityReady,
    physicalEvidenceChainReady,
    evidenceChainComplete,
	    releaseEvidenceReady,
	    localReleaseEvidenceReadyDiagnostic: releaseEvidenceReady,
    productionReady: inputIntegrity.ok && report?.productionReady === true,
    releaseReady: inputIntegrity.ok && report?.releaseReady === true,
    configuredReportCount: Number(summary.configuredReportCount || 0),
    missingConfiguredReportCount: Number(summary.missingConfiguredReportCount || 0),
    allConfiguredReportsPresent: summary.allConfiguredReportsPresent === true,
    linkedReportCount: Number(summary.linkedReportCount || 0),
	    platformCoverageCount: platformCoverage.length,
	    platformCoverage: platformCoverage.map((item) => ({
	      targetId: String(item?.targetId || ""),
	      platform: String(item?.platform || ""),
	      osFamily: String(item?.osFamily || ""),
	      arch: String(item?.arch || ""),
	      status: String(item?.status || "missing"),
	      remainingGates: stableStringList(item?.remainingGates),
	      hostSecretStoreReady: item?.hostSecretStoreReady === true,
	      platformSecretStoreReady: item?.platformSecretStoreReady === true,
	      physicalDeviceProofPresent: item?.physicalDeviceProofPresent === true,
	      releaseBundleShapeReady: item?.releaseBundleShapeReady === true,
	      releaseCliProofReady: item?.releaseCliProofReady === true,
	      packageUpdateReady: item?.packageUpdateReady === true,
	      commandResultReady: item?.commandResultReady === true,
	      installLaunchReady: item?.installLaunchReady === true,
	      userPresencePolicyReady: item?.userPresencePolicyReady === true,
	      platformSystemCredentialAuthReady: item?.platformSystemCredentialAuthReady === true,
	      platformCallbackContractReady: item?.platformCallbackContractReady === true
	    })),
    physicalProofClassCount: Array.isArray(report?.physicalProofClasses) ? report.physicalProofClasses.length : 0,
    releaseProofClassCount: Array.isArray(report?.releaseProofClasses) ? report.releaseProofClasses.length : 0,
    artifactDigestCount: artifactDigests.filter((item) => item?.present === true).length,
	    custodyStatusPresent: Boolean(report?.custodyStatus && Object.keys(report.custodyStatus).length > 0),
		    macosProductionEntitlementTemplateReady: macosCoverage.productionEntitlementTemplateReady === true,
		    macosProductionEntitlementFailClosedReady:
		      macosCoverage.productionEntitlementFailClosedReady === true ||
		      summary.macosProductionEntitlementFailClosedReady === true,
		    macosProductionEntitlementGateAccepted:
		      macosCoverage.productionEntitlementGateAccepted === true ||
		      summary.macosProductionEntitlementGateAccepted === true,
		    macosProductionEntitlementMissingFailClosed:
		      macosCoverage.productionEntitlementMissingFailClosed === true ||
		      summary.macosProductionEntitlementMissingFailClosed === true,
		    macosStandardKeychainRejectedForProduction:
		      macosCoverage.standardKeychainRejectedForProduction === true ||
		      summary.macosStandardKeychainRejectedForProduction === true,
		    macosStandardKeychainUserPresenceAcceptedForProduction:
		      macosCoverage.standardKeychainUserPresenceAcceptedForProduction === true ||
		      summary.macosStandardKeychainUserPresenceAcceptedForProduction === true,
		    macosStandardKeychainFallbackFailClosedReady:
		      macosCoverage.standardKeychainFallbackFailClosedReady === true ||
		      summary.macosStandardKeychainFallbackFailClosedReady === true,
		    macosKeyringReleaseEvidenceReady: summary.macosKeyringReleaseEvidenceReady === true,
	    macosLocalSecretStore: String(macosCoverage.localSecretStore || ""),
	    macosHostSecretStoreReady: macosCoverage.hostSecretStoreReady === true,
	    macosReleaseBundleShapeReady: macosCoverage.releaseBundleShapeReady === true,
	    macosReleaseCliProofReady: macosCoverage.releaseCliProofReady === true,
	    macosUserPresenceProofAttempted:
	      macosCoverage.userPresenceProofAttempted === true ||
	      summary.macosUserPresenceProofAttempted === true,
	    macosUserPresenceFailClosedUntilProductionEntitled:
	      macosCoverage.userPresenceFailClosedUntilProductionEntitled === true ||
	      summary.macosUserPresenceFailClosedUntilProductionEntitled === true,
	    macosUserPresenceBlockerCategory:
	      String(macosCoverage.userPresenceBlockerCategory || summary.macosUserPresenceBlockerCategory || ""),
	    macosUserPresencePolicyReady: macosCoverage.userPresencePolicyReady === true,
    macosSingleSystemAuthorizationContextVerified:
      macosCoverage.singleSystemAuthorizationContextVerified === true ||
      summary.macosSingleSystemAuthorizationContextVerified === true,
    macosInteractiveAuthorizationPromptBudgetReady:
      macosCoverage.interactiveAuthorizationPromptBudgetReady === true ||
      summary.macosInteractiveAuthorizationPromptBudgetReady === true,
    macosInteractiveAuthorizationAttemptCount:
      Number(macosCoverage.interactiveAuthorizationAttemptCount ||
        summary.macosInteractiveAuthorizationAttemptCount ||
        0),
    macosMaximumInteractiveAuthorizationAttemptsPerProof:
      Number(macosCoverage.maximumInteractiveAuthorizationAttemptsPerProof ||
        summary.macosMaximumInteractiveAuthorizationAttemptsPerProof ||
        1),
    macosAppCredentialPromptUsed:
      macosCoverage.appCredentialPromptUsed === true ||
      summary.macosAppCredentialPromptUsed === true,
    macosAppPasswordPromptUsed:
      macosCoverage.appPasswordPromptUsed === true ||
      summary.macosAppPasswordPromptUsed === true,
    macosSystemCredentialEntrySurface:
      String(macosCoverage.systemCredentialEntrySurface ||
        summary.macosSystemCredentialEntrySurface ||
	        ""),
	    ubuntuLinuxPackageUpdateReady: ubuntuCoverage.packageUpdateReady === true,
		    ubuntuLinuxReleaseEvidenceReady: summary.ubuntuLinuxReleaseEvidenceReady === true,
		    ubuntuLinuxLocalSecretStore: String(ubuntuCoverage.localSecretStore || ""),
		    ubuntuLinuxHostSecretStoreReady: ubuntuCoverage.hostSecretStoreReady === true,
		    ubuntuLinuxSecretStoreAuthorizationPolicyPresent:
		      ubuntuCoverage.secretStoreAuthorizationPolicyPresent === true ||
		      summary.ubuntuLinuxSecretStoreAuthorizationPolicyPresent === true,
		    ubuntuLinuxSecretStoreAuthorizationPolicyReady:
		      ubuntuCoverage.secretStoreAuthorizationPolicyReady === true ||
		      summary.ubuntuLinuxSecretStoreAuthorizationPolicyReady === true,
		    ubuntuLinuxReleaseCliProofReady: ubuntuCoverage.releaseCliProofReady === true,
	    ubuntuLinuxAdaptiveCustodyReady: ubuntuCoverage.adaptiveCustodyReady === true,
	    androidLocalSecretStore: String(androidCoverage.localSecretStore || ""),
	    androidPlatformSecretStoreReady: summary.androidPlatformSecretStoreReady === true,
    androidPhysicalSecretStoreBindingReady:
      summary.androidPhysicalSecretStoreBindingReady === true,
	    androidPhysicalSystemCredentialAuthReady:
	      summary.androidPhysicalSystemCredentialAuthReady === true,
    androidPhysicalKeyStoreHardwareAuthReady:
      summary.androidPhysicalKeyStoreHardwareAuthReady === true,
    androidPhysicalKeyStoreSecurityLevelName:
      String(summary.androidPhysicalKeyStoreSecurityLevelName || ""),
    androidPhysicalKeyStoreInsideSecureHardware:
      summary.androidPhysicalKeyStoreInsideSecureHardware === true,
    androidPhysicalKeyStoreUserAuthenticationHardwareEnforced:
      summary.androidPhysicalKeyStoreUserAuthenticationHardwareEnforced === true,
    androidPhysicalKeyStoreUnlockedDeviceRequired:
      summary.androidPhysicalKeyStoreUnlockedDeviceRequired === true,
	    androidPhysicalCallbackContractReady:
	      summary.androidPhysicalCallbackContractReady === true,
    androidPhysicalRawJsonSecretOverridesProvenAbsent:
      summary.androidPhysicalRawJsonSecretOverridesProvenAbsent === true,
    androidPhysicalRawJsonSecretOverridesUsed:
      summary.androidPhysicalRawJsonSecretOverridesUsed === true,
    androidPhysicalRawJsonSecretOverridesUnknown:
      summary.androidPhysicalRawJsonSecretOverridesUnknown === true,
    androidPhysicalInstallLaunchSchemaDrift:
      summary.androidPhysicalInstallLaunchSchemaDrift === true,
    androidPhysicalInstallLaunchSchemaDriftFieldCount:
      Number(summary.androidPhysicalInstallLaunchSchemaDriftFieldCount || 0),
    androidPhysicalInstallLaunchSchemaStatus:
      String(summary.androidPhysicalInstallLaunchSchemaStatus || "unknown"),
	    androidPhysicalMissingFieldsAbsent:
	      summary.androidPhysicalMissingFieldsAbsent === true,
	    androidPhysicalMissingFieldAuditPresent:
	      summary.androidPhysicalMissingFieldAuditPresent === true,
	    androidPhysicalMissingFields:
	      stableStringList(summary.androidPhysicalMissingFields),
	    androidPhysicalMissingFieldCount:
	      Number(summary.androidPhysicalMissingFieldCount || 0),
	    androidPhysicalWeakProofFieldsAbsent:
	      summary.androidPhysicalWeakProofFieldsAbsent === true,
	    androidPhysicalWeakProofFieldAuditPresent:
	      summary.androidPhysicalWeakProofFieldAuditPresent === true,
	    androidPhysicalWeakProofFields:
	      stableStringList(summary.androidPhysicalWeakProofFields),
	    androidPhysicalWeakProofFieldCount:
	      Number(summary.androidPhysicalWeakProofFieldCount || 0),
	    androidUserAuthenticationBlockedBeforeKeyStoreE2e:
	      summary.androidUserAuthenticationBlockedBeforeKeyStoreE2e === true,
	    androidUserAuthenticationRequested:
	      summary.androidUserAuthenticationRequested === true,
	    androidUserAuthenticationPromptStarted:
	      summary.androidUserAuthenticationPromptStarted === true,
	    androidSystemCredentialPromptNotCompleted:
	      summary.androidSystemCredentialPromptNotCompleted === true,
	    androidUserAuthenticationBlockerReason:
	      String(summary.androidUserAuthenticationBlockerReason || ""),
	    androidUserAuthenticationUserActionRequired:
	      String(summary.androidUserAuthenticationUserActionRequired || ""),
	    androidUserAuthenticationDiagnosticCode:
	      String(summary.androidUserAuthenticationDiagnosticCode || ""),
	    androidUserAuthenticationResultCodePresent:
	      summary.androidUserAuthenticationResultCodePresent === true,
	    androidUserAuthenticationResultCode:
	      Number(summary.androidUserAuthenticationResultCode || 0),
	    androidUserAuthenticationCredentialEntrySurface:
	      String(summary.androidUserAuthenticationCredentialEntrySurface || ""),
	    androidUserAuthenticationSystemAuthenticationOnly:
	      summary.androidUserAuthenticationSystemAuthenticationOnly === true,
	    androidUserAuthenticationAppLockScreenCredentialCollection:
	      summary.androidUserAuthenticationAppLockScreenCredentialCollection === true,
	    androidUserAuthenticationKeyMaterialExported:
	      summary.androidUserAuthenticationKeyMaterialExported === true,
	    androidUserAuthenticationAppCredentialPromptUsed:
	      summary.androidUserAuthenticationAppCredentialPromptUsed === true,
    androidUserAuthenticationAppPasswordPromptUsed:
      summary.androidUserAuthenticationAppPasswordPromptUsed === true,
    androidUserAuthenticationPromptResult:
      String(summary.androidUserAuthenticationPromptResult || ""),
    androidKeyStoreAuthPolicyState:
      String(summary.androidKeyStoreAuthPolicyState || ""),
    iosPlatformSecretStoreReady: summary.iosPlatformSecretStoreReady === true,
    iosPhysicalSecretStoreBindingReady:
      summary.iosPhysicalSecretStoreBindingReady === true,
	    iosUserPresencePolicyReady:
	      summary.iosUserPresencePolicyReady === true ||
	      iosCoverage.platformUserPresencePolicyReady === true,
	    iosProductionCallbackAuthReady:
	      summary.iosProductionCallbackAuthReady === true ||
	      iosCoverage.platformProductionCallbackAuthReady === true,
	    iosCallbackReadsUseSharedLAContext:
	      summary.iosCallbackReadsUseSharedLAContext === true ||
	      iosCoverage.platformCallbackReadsUseSharedLAContext === true,
	    iosSingleSystemAuthorizationContextVerified:
	      summary.iosSingleSystemAuthorizationContextVerified === true ||
	      iosCoverage.platformSingleSystemAuthorizationContextVerified === true,
	    iosCallbackAuthContextAttachedToAllReads:
	      summary.iosCallbackAuthContextAttachedToAllReads === true ||
	      iosCoverage.platformCallbackAuthContextAttachedToAllReads === true,
	    appPasswordPromptUsedPresent:
	      summary.appPasswordPromptUsedPresent === true ||
	      iosCoverage.appPasswordPromptUsedPresent === true,
	    appCredentialPromptUsedPresent:
	      summary.appCredentialPromptUsedPresent === true ||
	      iosCoverage.appCredentialPromptUsedPresent === true,
	    keyMaterialExportedPresent:
	      summary.keyMaterialExportedPresent === true ||
	      iosCoverage.keyMaterialExportedPresent === true,
	    iosSystemLocalAuthPromptReady:
      summary.iosSystemLocalAuthPromptReady === true ||
      iosCoverage.platformSystemLocalAuthPromptReady === true,
    iosKeychainAccessControlNotDowngraded:
      summary.iosKeychainAccessControlNotDowngraded === true ||
      iosCoverage.platformKeychainAccessControlNotDowngraded === true,
    iosNonInteractiveFailClosedReady:
      summary.iosNonInteractiveFailClosedReady === true ||
      iosCoverage.platformNonInteractiveFailClosedReady === true,
    iosCancelLockFailClosedReady:
      summary.iosCancelLockFailClosedReady === true ||
      iosCoverage.platformCancelLockFailClosedReady === true,
    iosAppPasswordPromptUsed:
      summary.iosAppPasswordPromptUsed === true ||
      iosCoverage.appPasswordPromptUsed === true,
    iosAppCredentialPromptUsed:
      summary.iosAppCredentialPromptUsed === true ||
      iosCoverage.appCredentialPromptUsed === true,
    iosKeyMaterialExported:
      summary.iosKeyMaterialExported === true ||
      iosCoverage.keyMaterialExported === true,
    iosPhysicalCallbackContractReady:
      summary.iosPhysicalCallbackContractReady === true,
	    iosPhysicalRawJsonSecretOverridesProvenAbsent:
	      summary.iosPhysicalRawJsonSecretOverridesProvenAbsent === true,
	    iosPhysicalDeviceDiscovered: summary.iosPhysicalDeviceDiscovered === true,
	    iosWaitForDeviceAttempted: summary.iosWaitForDeviceAttempted === true,
	    iosWaitForDeviceTimeoutSeconds:
	      Number(summary.iosWaitForDeviceTimeoutSeconds || 0),
	    iosRemediationDeviceIdentifiersIncluded:
	      summary.iosRemediationDeviceIdentifiersIncluded === true,
	    iosRemediationSawUnavailablePhysicalDevice:
	      summary.iosRemediationSawUnavailablePhysicalDevice === true,
	    currentIosDeviceTrustState: String(summary.currentIosDeviceTrustState || ""),
	    currentIosTrustBlockerStaleCandidate:
	      summary.currentIosTrustBlockerStaleCandidate === true,
	    iosDeviceTrustBlockerEvidence:
	      summary.iosDeviceTrustBlockerEvidence || {},
	    iosLocalSecretStore: String(iosCoverage.localSecretStore || ""),
	    iosDeveloperModeOrDeviceTrustBlocked:
	      summary.iosDeveloperModeOrDeviceTrustBlocked === true,
    iosDeviceTrustGateResult: String(summary.iosDeviceTrustGateResult || ""),
    iosUserPresenceMissingFields:
      stableStringList(summary.iosUserPresenceMissingFields),
    iosUserPresenceMissingFieldCount:
      Number(summary.iosUserPresenceMissingFieldCount || 0),
    iosUserPresenceMissingFieldsAbsent:
      summary.iosUserPresenceMissingFieldsAbsent === true,
    iosPhysicalPrerequisiteMissingFields:
      stableStringList(summary.iosPhysicalPrerequisiteMissingFields),
    iosPhysicalPrerequisiteMissingFieldCount:
      Number(summary.iosPhysicalPrerequisiteMissingFieldCount || 0),
    iosPhysicalPrerequisiteMissingFieldsAbsent:
      summary.iosPhysicalPrerequisiteMissingFieldsAbsent === true,
    iosReleaseBuiltDesktopCliSelected: summary.iosReleaseBuiltDesktopCliSelected === true,
    boundaryGateSummary: {
      android: String(summary.boundaryGateSummary?.android || ""),
      ios: String(summary.boundaryGateSummary?.ios || "")
    },
    windowsLocalImplementationReady:
      summary.windowsLocalImplementationReady === true,
    windowsNativeHostEvidenceReady:
      summary.windowsNativeHostEvidenceReady === true,
    productionAcceptedEvidenceRecordsReady: releaseEvidenceReady === true &&
      platformSystemAuthorizationReleaseReady &&
      manifestIntegrityReady === true &&
      physicalEvidenceChainReady === true &&
      evidenceChainComplete === true &&
      report?.productionReady !== true &&
      report?.releaseReady !== true &&
      Number(summary.linkedReportCount || 0) > 0 &&
      platformCoverage.length >= 5 &&
      artifactDigests.some((item) => item?.present === true)
  };
}

function summarizeWindowsImplementation(report = {}) {
  report = reportRecord(report);
  const summary = report?.summary || {};
  const platform = report?.platform || {};
  const present = Boolean(report && Object.keys(report).length > 0);
  const ready = report?.ok === true &&
    report?.redacted === true &&
    report?.blocker === "physical device matrix" &&
    report?.diagnosticStatus === "implementation_ready_host_evidence_pending" &&
    report?.productionReady !== true &&
    report?.releaseReady !== true &&
    summary.windowsLocalBlockersCleared === true &&
    summary.nativeHostEvidencePending === true &&
    summary.dpapiOrWindowsHelloProofReady !== true &&
    summary.windowsSignedInstallerProofReady !== true &&
    platform.platform === "windows" &&
    platform.status === "implementation-ready-host-evidence-pending" &&
    platform.localImplementationReady === true &&
    platform.x64BuilderVerifierReady === true &&
    platform.productionSupportClaimed !== true;
  return {
    report: windowsImplementationReportPath,
    present,
    ok: report?.ok === true,
    redacted: report?.redacted === true,
    blocker: String(report?.blocker || ""),
    diagnosticStatus: String(report?.diagnosticStatus || ""),
    windowsLocalBlockersCleared: summary.windowsLocalBlockersCleared === true,
    nativeHostEvidencePending: summary.nativeHostEvidencePending === true,
    dpapiOrWindowsHelloProofReady: summary.dpapiOrWindowsHelloProofReady === true,
    windowsSignedInstallerProofReady: summary.windowsSignedInstallerProofReady === true,
    productionReady: report?.productionReady === true,
    releaseReady: report?.releaseReady === true,
    ready
  };
}

async function summarizeReportRedactionProof(report = {}, expectedRedactionRunId = "") {
  const summary = report?.summary || {};
  const present = Boolean(report && Object.keys(report).length > 0);
  const scannedRefs = Array.isArray(report?.scannedRefs)
    ? report.scannedRefs.map((item) => String(item || "")).filter(Boolean)
    : [];
  const scannedRefDigestEntries = Array.isArray(report?.scannedRefDigests)
    ? report.scannedRefDigests
        .map((entry) => ({
          ref: String(entry?.ref || ""),
          sha256: String(entry?.sha256 || "")
        }))
        .filter((entry) => entry.ref && entry.sha256)
    : [];
  const digestEntriesByRef = new Map();
  const duplicateDigestRefs = [];
  for (const entry of scannedRefDigestEntries) {
    if (digestEntriesByRef.has(entry.ref)) {
      duplicateDigestRefs.push(entry.ref);
      continue;
    }
    digestEntriesByRef.set(entry.ref, entry.sha256);
  }
  const scannedRefSet = new Set(scannedRefs);
  const extraDigestRefs = scannedRefDigestEntries
    .map((entry) => entry.ref)
    .filter((ref) => !scannedRefSet.has(ref));
  const staleOrMissingDigestRefs = [];
  for (const ref of scannedRefs) {
    const expectedDigest = digestEntriesByRef.get(ref) || "";
    const actualDigest = await sha256FileIfPresent(ref);
    if (!expectedDigest || !actualDigest || expectedDigest !== actualDigest) {
      staleOrMissingDigestRefs.push(ref);
    }
  }
  const digestManifestExact = scannedRefs.length > 0 &&
    scannedRefs.length === scannedRefSet.size &&
    scannedRefDigestEntries.length === scannedRefs.length &&
    Number(summary.scannedRefDigestCount || 0) === scannedRefDigestEntries.length &&
    duplicateDigestRefs.length === 0 &&
    extraDigestRefs.length === 0;
  const scannedRefDigestsCurrent = scannedRefs.length > 0 &&
    digestManifestExact &&
    staleOrMissingDigestRefs.length === 0;
  const redactionRunIdMatched = String(report?.redactionRunId || "") === expectedRedactionRunId &&
    expectedRedactionRunId.length > 0;
  const ready = report?.ok === true &&
    report?.redacted === true &&
    report?.diagnosticStatus === "passed" &&
    summary.reportRedactionReady === true &&
    summary.selfTestReady === true &&
    Number(summary.scannedReportCount || 0) > 0 &&
    scannedRefDigestsCurrent &&
    redactionRunIdMatched &&
    Number(summary.hitCount || 0) === 0 &&
    summary.releaseProofInputsOnly === true &&
    report?.rawPrivateMaterialIncluded !== true &&
    report?.rawPlaintextIncluded !== true &&
    report?.rawLocalPathIncluded !== true &&
    report?.rawIdentityMaterialIncluded !== true;
  return {
    report: reportRedactionReportPath,
    present,
    ok: report?.ok === true,
    redacted: report?.redacted === true,
    diagnosticStatus: String(report?.diagnosticStatus || ""),
    reportRedactionReady: summary.reportRedactionReady === true,
    selfTestReady: summary.selfTestReady === true,
    scannedRefs,
    scannedRefDigestCount: scannedRefDigestEntries.length,
    digestManifestExact,
    scannedRefDigestsCurrent,
    duplicateDigestRefs,
    extraDigestRefs,
    staleOrMissingDigestRefs,
    redactionRunIdMatched,
    scannedReportCount: Number(summary.scannedReportCount || 0),
    missingReportCount: Number(summary.missingReportCount || 0),
    hitCount: Number(summary.hitCount || 0),
    releaseProofInputsOnly: summary.releaseProofInputsOnly === true,
    ready
  };
}

async function runReportRedactionFreshnessSelfTest() {
  const fixtureRef = "tools/scripts/client-secure-mesh-release-proof-bundle.mjs";
  const fixtureDigest = await sha256FileIfPresent(fixtureRef);
  const runId = "self-test-redaction-run";
  const baseReport = {
    ok: true,
    redacted: true,
    diagnosticStatus: "passed",
    redactionRunId: runId,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawLocalPathIncluded: false,
    rawIdentityMaterialIncluded: false,
    scannedRefs: [fixtureRef],
    scannedRefDigests: [{ ref: fixtureRef, sha256: fixtureDigest }],
    summary: {
      reportRedactionReady: true,
      selfTestReady: true,
      scannedReportCount: 1,
      scannedRefDigestCount: 1,
      hitCount: 0,
      releaseProofInputsOnly: true
    }
  };
  const good = await summarizeReportRedactionProof(baseReport, runId);
  const duplicateDigest = await summarizeReportRedactionProof({
    ...baseReport,
    scannedRefDigests: [
      { ref: fixtureRef, sha256: fixtureDigest },
      { ref: fixtureRef, sha256: fixtureDigest }
    ],
    summary: {
      ...baseReport.summary,
      scannedRefDigestCount: 2
    }
  }, runId);
  const extraDigest = await summarizeReportRedactionProof({
    ...baseReport,
    scannedRefDigests: [
      { ref: fixtureRef, sha256: fixtureDigest },
      { ref: "build/reports/self-test-extra-report.json", sha256: fixtureDigest }
    ],
    summary: {
      ...baseReport.summary,
      scannedRefDigestCount: 2
    }
  }, runId);
  const staleDigest = await summarizeReportRedactionProof({
    ...baseReport,
    scannedRefDigests: [{ ref: fixtureRef, sha256: "sha256:self-test-stale-digest" }]
  }, runId);
  const runIdMismatch = await summarizeReportRedactionProof(baseReport, "self-test-other-run");
  const ok = good.ready === true &&
    duplicateDigest.ready === false &&
    duplicateDigest.digestManifestExact === false &&
    extraDigest.ready === false &&
    extraDigest.digestManifestExact === false &&
    staleDigest.ready === false &&
    staleDigest.scannedRefDigestsCurrent === false &&
    runIdMismatch.ready === false &&
    runIdMismatch.redactionRunIdMatched === false;
  return {
    ok,
    positiveAccepted: good.ready === true,
    duplicateDigestRejected: duplicateDigest.ready === false,
    extraDigestRejected: extraDigest.ready === false,
    staleDigestRejected: staleDigest.ready === false,
    runIdMismatchRejected: runIdMismatch.ready === false
  };
}

function runPhysicalEvidenceManifestReadinessSelfTest() {
  const baseReport = {
    schemaVersion: "licolite.secure-mesh.physical-evidence-manifest-report.v2",
    evidenceRefSchemaVersion: SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
    sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    verifier: "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs",
    generatedBy: "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs",
    blocker: "physical device matrix",
    ok: true,
    diagnosticOk: true,
    okMeaning: "manifest_integrity_not_production_evidence",
    redacted: true,
    reportLeakScan: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    redactionReady: true,
    manifestIntegrityReady: true,
    physicalEvidenceChainReady: true,
    evidenceChainComplete: false,
    releaseEvidenceReady: false,
    ready: false,
    productionReady: false,
    releaseReady: false,
    platformCoverage: [
	      {
	        platform: "macos",
	        userPresencePolicyReady: true,
	        productionEntitlementFailClosedReady: true,
	        productionEntitlementGateAccepted: true,
	        productionEntitlementMissingFailClosed: true,
	        standardKeychainRejectedForProduction: true,
	        standardKeychainUserPresenceAcceptedForProduction: false,
	        standardKeychainFallbackFailClosedReady: true,
	        singleSystemAuthorizationContextVerified: true,
        interactiveAuthorizationPromptBudgetReady: true,
        interactiveAuthorizationCompletedWithinBudget: true,
        dataProtectionSecretReadBlockedOrUnavailable: false,
        interactiveAuthorizationAttemptCount: 1,
        maximumInteractiveAuthorizationAttemptsPerProof: 1,
        appPasswordPromptUsed: false,
        appCredentialPromptUsed: false,
        systemCredentialEntrySurface: "macos_local_authentication_system_prompt",
        keyMaterialExported: false
      },
      {
        platform: "ios",
        platformUserPresencePolicyReady: true,
        platformProductionCallbackAuthReady: true,
        platformCallbackReadsUseSharedLAContext: true,
        platformSingleSystemAuthorizationContextVerified: true,
        platformCallbackAuthContextAttachedToAllReads: true,
        platformSystemLocalAuthPromptReady: true,
        platformKeychainAccessControlNotDowngraded: true,
        platformNonInteractiveFailClosedReady: true,
        platformCancelLockFailClosedReady: true,
        appPasswordPromptUsedPresent: true,
        appPasswordPromptUsed: false,
        appCredentialPromptUsedPresent: true,
        appCredentialPromptUsed: false,
        keyMaterialExportedPresent: true,
        keyMaterialExported: false
      }
    ],
    summary: {
      diagnosticOk: true,
      allConfiguredReportsPresent: true,
      redactionReady: true,
      manifestIntegrityReady: true,
      physicalEvidenceChainReady: true,
      evidenceChainComplete: false,
	      releaseEvidenceReady: false,
	      androidPhysicalSystemCredentialAuthReady: true,
      androidPhysicalKeyStoreHardwareAuthReady: true,
      androidPhysicalKeyStoreSecurityLevelName: "trusted_execution_environment",
      androidPhysicalKeyStoreInsideSecureHardware: true,
      androidPhysicalKeyStoreUserAuthenticationHardwareEnforced: true,
      androidPhysicalKeyStoreUnlockedDeviceRequired: true,
	      androidUserAuthenticationSystemAuthenticationOnly: true,
      androidUserAuthenticationCredentialEntrySurface: "android_system_credential_prompt",
      androidUserAuthenticationAppLockScreenCredentialCollection: false,
      androidUserAuthenticationAppCredentialPromptUsed: false,
      androidUserAuthenticationAppPasswordPromptUsed: false,
      androidUserAuthenticationKeyMaterialExported: false,
      androidPhysicalRawJsonSecretOverridesProvenAbsent: true,
      androidPhysicalMissingFieldAuditPresent: true,
      androidPhysicalMissingFieldsAbsent: true,
	      androidPhysicalWeakProofFieldAuditPresent: true,
	      androidPhysicalWeakProofFieldsAbsent: true,
	      macosProductionEntitlementFailClosedReady: true,
	      macosProductionEntitlementGateAccepted: true,
	      macosProductionEntitlementMissingFailClosed: true,
	      macosStandardKeychainRejectedForProduction: true,
	      macosStandardKeychainUserPresenceAcceptedForProduction: false,
	      macosStandardKeychainFallbackFailClosedReady: true,
	      macosUserPresencePolicyReady: true,
      macosSingleSystemAuthorizationContextVerified: true,
      macosInteractiveAuthorizationPromptBudgetReady: true,
      macosInteractiveAuthorizationCompletedWithinBudget: true,
      macosDataProtectionSecretReadBlockedOrUnavailable: false,
      macosInteractiveAuthorizationAttemptCount: 1,
      macosMaximumInteractiveAuthorizationAttemptsPerProof: 1,
      macosAppPasswordPromptUsed: false,
      macosAppCredentialPromptUsed: false,
      macosKeyMaterialExported: false,
      macosSystemCredentialEntrySurface: "macos_local_authentication_system_prompt",
      iosUserPresencePolicyReady: true,
      iosProductionCallbackAuthReady: true,
      iosCallbackReadsUseSharedLAContext: true,
      iosSingleSystemAuthorizationContextVerified: true,
      iosCallbackAuthContextAttachedToAllReads: true,
      appPasswordPromptUsedPresent: true,
      appCredentialPromptUsedPresent: true,
      keyMaterialExportedPresent: true,
      iosSystemLocalAuthPromptReady: true,
      iosKeychainAccessControlNotDowngraded: true,
      iosNonInteractiveFailClosedReady: true,
      iosCancelLockFailClosedReady: true,
      iosAppPasswordPromptUsed: false,
      iosAppCredentialPromptUsed: false,
      iosKeyMaterialExported: false,
      remainingGates: ["physical device release evidence chain ready"]
    }
  };
  const diagnosticOnly = summarizePhysicalEvidenceManifest(baseReport);
  const releaseReady = summarizePhysicalEvidenceManifest({
    ...baseReport,
    okMeaning: "release_evidence_chain_ready",
    evidenceChainComplete: true,
    releaseEvidenceReady: true,
    ready: true,
    summary: {
      ...baseReport.summary,
      evidenceChainComplete: true,
      releaseEvidenceReady: true,
      remainingGates: []
    }
  });
  const androidAppPasswordPrompt = summarizePhysicalEvidenceManifest({
    ...baseReport,
    okMeaning: "release_evidence_chain_ready",
    evidenceChainComplete: true,
    releaseEvidenceReady: true,
    ready: true,
    summary: {
      ...baseReport.summary,
      evidenceChainComplete: true,
      releaseEvidenceReady: true,
      androidUserAuthenticationAppPasswordPromptUsed: true,
      remainingGates: []
    }
  });
  const macosRepeatedAuthorization = summarizePhysicalEvidenceManifest({
    ...baseReport,
    okMeaning: "release_evidence_chain_ready",
    evidenceChainComplete: true,
    releaseEvidenceReady: true,
    ready: true,
    platformCoverage: baseReport.platformCoverage.map((item) =>
      item.platform === "macos"
        ? { ...item, interactiveAuthorizationAttemptCount: 2 }
        : item
    ),
    summary: {
      ...baseReport.summary,
      evidenceChainComplete: true,
      releaseEvidenceReady: true,
      macosInteractiveAuthorizationAttemptCount: 2,
      remainingGates: []
    }
  });
  const macosAppPasswordPrompt = summarizePhysicalEvidenceManifest({
    ...baseReport,
    okMeaning: "release_evidence_chain_ready",
    evidenceChainComplete: true,
    releaseEvidenceReady: true,
    ready: true,
    platformCoverage: baseReport.platformCoverage.map((item) =>
      item.platform === "macos"
        ? { ...item, appPasswordPromptUsed: true }
        : item
    ),
    summary: {
      ...baseReport.summary,
      evidenceChainComplete: true,
      releaseEvidenceReady: true,
      macosAppPasswordPromptUsed: true,
      remainingGates: []
    }
  });
  const macosAuthorizationNotCompleted = summarizePhysicalEvidenceManifest({
    ...baseReport,
    okMeaning: "release_evidence_chain_ready",
    evidenceChainComplete: true,
    releaseEvidenceReady: true,
    ready: true,
    platformCoverage: baseReport.platformCoverage.map((item) =>
      item.platform === "macos"
        ? { ...item, interactiveAuthorizationCompletedWithinBudget: false }
        : item
    ),
    summary: {
      ...baseReport.summary,
      evidenceChainComplete: true,
      releaseEvidenceReady: true,
      macosInteractiveAuthorizationCompletedWithinBudget: false,
      remainingGates: []
    }
  });
  const macosKeyMaterialExported = summarizePhysicalEvidenceManifest({
    ...baseReport,
    okMeaning: "release_evidence_chain_ready",
    evidenceChainComplete: true,
    releaseEvidenceReady: true,
    ready: true,
    platformCoverage: baseReport.platformCoverage.map((item) =>
      item.platform === "macos"
        ? { ...item, keyMaterialExported: true }
        : item
    ),
    summary: {
      ...baseReport.summary,
      evidenceChainComplete: true,
      releaseEvidenceReady: true,
      macosKeyMaterialExported: true,
      remainingGates: []
    }
  });
  const iosAppCredentialPrompt = summarizePhysicalEvidenceManifest({
    ...baseReport,
    okMeaning: "release_evidence_chain_ready",
    evidenceChainComplete: true,
    releaseEvidenceReady: true,
    ready: true,
    platformCoverage: baseReport.platformCoverage.map((item) =>
      item.platform === "ios"
        ? { ...item, appCredentialPromptUsed: true }
        : item
    ),
    summary: {
      ...baseReport.summary,
      evidenceChainComplete: true,
      releaseEvidenceReady: true,
      iosAppCredentialPromptUsed: true,
      remainingGates: []
    }
  });
  const readyOnlyWithoutReleaseEvidence = summarizePhysicalEvidenceManifest({
    ...baseReport,
    okMeaning: "release_evidence_chain_ready",
    evidenceChainComplete: true,
    releaseEvidenceReady: false,
    ready: true,
    summary: {
      ...baseReport.summary,
      evidenceChainComplete: true,
      releaseEvidenceReady: false,
      remainingGates: []
    }
  });
  const legacySchema = summarizePhysicalEvidenceManifest({
    ...baseReport,
    schemaVersion: "licolite.secure-mesh.physical-evidence-manifest-report.v1"
  });
  const ok = diagnosticOnly.inputIntegrityReady === true &&
    diagnosticOnly.diagnosticIntegrityReady === true &&
    diagnosticOnly.ready === false &&
    diagnosticOnly.releaseEvidenceReady === false &&
    diagnosticOnly.evidenceChainComplete === false &&
    releaseReady.inputIntegrityReady === true &&
    releaseReady.diagnosticIntegrityReady === true &&
    releaseReady.releaseEvidenceReady === true &&
    releaseReady.evidenceChainComplete === true &&
    releaseReady.platformSystemAuthorizationReleaseReady === true &&
    releaseReady.ready === true &&
    androidAppPasswordPrompt.ready === false &&
    androidAppPasswordPrompt.androidSystemCredentialReleaseReady === false &&
    macosRepeatedAuthorization.ready === false &&
    macosRepeatedAuthorization.macosSingleSystemAuthorizationReleaseReady === false &&
    macosAppPasswordPrompt.ready === false &&
    macosAppPasswordPrompt.macosSingleSystemAuthorizationReleaseReady === false &&
    macosAuthorizationNotCompleted.ready === false &&
    macosAuthorizationNotCompleted.macosSingleSystemAuthorizationReleaseReady === false &&
    macosKeyMaterialExported.ready === false &&
    macosKeyMaterialExported.macosSingleSystemAuthorizationReleaseReady === false &&
    iosAppCredentialPrompt.ready === false &&
    iosAppCredentialPrompt.iosSystemLocalAuthReleaseReady === false &&
    readyOnlyWithoutReleaseEvidence.ready === false &&
    readyOnlyWithoutReleaseEvidence.releaseEvidenceReady === false &&
    legacySchema.inputIntegrityReady === false &&
    legacySchema.ready === false;
  return {
    ok,
    diagnosticOnlyRejected: diagnosticOnly.ready === false,
    diagnosticIntegrityAccepted: diagnosticOnly.diagnosticIntegrityReady === true,
    releaseEvidenceRequired: diagnosticOnly.releaseEvidenceReady === false,
    evidenceChainRequired: diagnosticOnly.evidenceChainComplete === false,
    platformSystemAuthorizationRequired:
      releaseReady.platformSystemAuthorizationReleaseReady === true,
    androidAppPasswordPromptRejected: androidAppPasswordPrompt.ready === false,
    macosRepeatedAuthorizationRejected: macosRepeatedAuthorization.ready === false,
    macosAppPasswordPromptRejected: macosAppPasswordPrompt.ready === false,
    iosAppCredentialPromptRejected: iosAppCredentialPrompt.ready === false,
    readyOnlyWithoutReleaseEvidenceRejected:
      readyOnlyWithoutReleaseEvidence.ready === false,
    legacySchemaRejected:
      legacySchema.inputIntegrityReady === false && legacySchema.ready === false,
    positiveReleaseFixtureAccepted: releaseReady.ready === true
	  };
	}

function runReleaseProofContractReadinessSelfTest() {
  const forgedPhysicalMatrix = {
    schemaVersion: "licolite.secure-mesh.physical-device-matrix-report.v2",
    evidenceRefSchemaVersion: SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
    sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    verifier: "tools/scripts/client-secure-mesh-physical-device-matrix.mjs",
    generatedBy: "tools/scripts/client-secure-mesh-physical-device-matrix.mjs",
    checkedAt: new Date().toISOString(),
    blocker: "physical device matrix",
    ok: true,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    reportLeakScan: true,
    productionReady: false,
    releaseReady: false,
    physicalEvidenceChainReady: true,
    releaseEvidenceReady: true,
    summary: {
      physicalEvidenceChainReady: true,
      releaseEvidenceReady: true,
      remainingGates: []
    }
  };
  const forgedPhysicalEvidenceManifest = {
    schemaVersion: "licolite.secure-mesh.physical-evidence-manifest-report.v2",
    evidenceRefSchemaVersion: SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
    sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    verifier: "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs",
    generatedBy: "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs",
    checkedAt: new Date().toISOString(),
    blocker: "physical device matrix",
    ok: true,
    ready: true,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    reportLeakScan: true,
    productionReady: false,
    releaseReady: false,
    physicalEvidenceChainReady: true,
    releaseEvidenceReady: true,
    summary: {
      ready: true,
      physicalEvidenceChainReady: true,
      releaseEvidenceReady: true,
      remainingGates: []
    }
  };
  const forgedPhysicalMatrixReadiness =
    evaluateSecureClientMeshEvidenceRefReportReadiness(
      forgedPhysicalMatrix,
      "physical device matrix"
    );
  const forgedPhysicalEvidenceManifestReadiness =
    evaluateSecureClientMeshEvidenceRefReportReadiness(
      forgedPhysicalEvidenceManifest,
      "physical device matrix"
    );
  const legacyPhysicalMatrix = summarizePhysicalMatrixReport({
    ...forgedPhysicalMatrix,
    schemaVersion: "licolite.secure-mesh.physical-device-matrix-report.v1"
  });
  const legacyPhysicalEvidenceManifest = summarizePhysicalEvidenceManifest({
    ...forgedPhysicalEvidenceManifest,
    schemaVersion: "licolite.secure-mesh.physical-evidence-manifest-report.v1"
  });
  const androidPhysicalInstallLaunch = summarizeAndroidPhysicalInstallLaunchReport({
    ok: true,
    physicalDevice: true,
    summary: {
      apkReady: true,
      installReady: true,
      launchReady: true,
      runtimeStatusReady: true,
      nativeRuntimeReady: true,
      androidKeyStoreReady: true,
      keyStoreUserAuthReady: true
    },
    runtimeStatus: {
      mobileRelaySecretStore: {
        provider: "AndroidKeyStore",
        ffiBoundary: "jni",
        secretTransport: "platform_keyring_to_rust_ffi_memory_override",
        secretStoreBackend: "android-keystore",
        secretStoreContract: "rust_secure_mesh_secret_store_handle_v1",
        secretStoreAccountPrefix: "mobileRelayE2ee",
        secretStoreNamespace: "mobileRelayRuntime",
        sharedRustSecretStoreHandleContract: true,
        rawJsonSecretOverridesProvenAbsent: true,
        rawJsonSecretOverridesUsed: false,
        keyMaterialExported: false,
        appCredentialPromptUsed: false,
        appPasswordPromptUsed: false,
        userAuthenticationRequired: true,
        credentialEntrySurface: "android_system_credential_prompt"
      }
    }
  });
  const ok =
    forgedPhysicalMatrixReadiness.ready === false &&
    forgedPhysicalEvidenceManifestReadiness.ready === false &&
    legacyPhysicalMatrix.inputIntegrityReady === false &&
    legacyPhysicalEvidenceManifest.inputIntegrityReady === false &&
    androidPhysicalInstallLaunch.localReadyDiagnostic === true &&
    !Object.hasOwn(androidPhysicalInstallLaunch, "ready");
  return {
    ok,
    forgedPhysicalMatrixSummaryReadyRejected:
      forgedPhysicalMatrixReadiness.ready === false,
    forgedPhysicalEvidenceManifestSummaryReadyRejected:
      forgedPhysicalEvidenceManifestReadiness.ready === false,
    legacyPhysicalMatrixSchemaRejected:
      legacyPhysicalMatrix.inputIntegrityReady === false,
    legacyPhysicalEvidenceManifestSchemaRejected:
      legacyPhysicalEvidenceManifest.inputIntegrityReady === false,
    androidPhysicalInstallLaunchLocalReadyDiagnosticOnly:
      androidPhysicalInstallLaunch.localReadyDiagnostic === true &&
      !Object.hasOwn(androidPhysicalInstallLaunch, "ready"),
    forgedPhysicalMatrixContractRemainingGateCount:
      Number(forgedPhysicalMatrixReadiness.remainingGateCount || 0),
    forgedPhysicalEvidenceManifestContractRemainingGateCount:
      Number(forgedPhysicalEvidenceManifestReadiness.remainingGateCount || 0)
  };
}

const relayMockAcceptanceSchemaVersion =
  "licolite.secure-client-relay.client-acceptance-report.v1";
const rustCryptoSchemaVersion =
  "licolite.secure-mesh.pairwise-content-audit-report.v1";
const platformCryptoSchemaVersion =
  "licolite.secure-mesh.platform-secret-store-matrix-report.v2";
const androidPlatformCryptoSchemaVersion =
  "licolite.secure-mesh.android-platform-crypto-acceptance.v1";

function redactedClientReleaseInputReady(report, expectedSchemaVersion) {
  return report?.ok === true &&
    report.schemaVersion === expectedSchemaVersion &&
    report.redacted === true &&
    report.rawPrivateMaterialIncluded === false &&
    report.rawPlaintextIncluded === false &&
    report.rawPublicWireBytesIncluded === false &&
    report.reportLeakScan === true;
}

function summarizeClientRelayCryptoInputs({
  relayMock = {},
  rustCrypto = {},
  platformCrypto = {},
  androidPlatformCrypto = {},
  reportRedactionProof = {}
} = {}) {
  const relayMockPayload = relayMock.mock || {};
  const relayMockSummary = relayMock.summary || {};
  const rustCryptoSummary = rustCrypto.summary || {};
  const platformCryptoSummary = platformCrypto.summary || {};
  const androidPlatformCryptoSummary = androidPlatformCrypto.summary || {};
  const scannedRefs = new Set(reportRedactionProof.scannedRefs || []);
  const requiredRefs = [
    relayMockReportPath,
    rustCryptoReportPath,
    platformCryptoReportPath,
    androidPlatformCryptoReportPath
  ];
  const releaseInputRedactionCoversClientRefs =
    requiredRefs.every((ref) => scannedRefs.has(ref));

  const relayMockExactFiveOperationsReady =
    relayMockPayload.operationCount === 5 &&
    relayMockPayload.exactFiveOperationsObserved === true &&
    relayMockSummary.exactFiveOperationsObserved === true;
  const relayMockExactSixOuterFieldsReady =
    relayMockPayload.outerEnvelopeFieldCount === 6 &&
    relayMockPayload.exactSixOuterFieldsObserved === true &&
    relayMockSummary.exactSixOuterFieldsObserved === true;
  const relayMockReplayRejected =
    relayMockPayload.replayRejected === true &&
    relayMockSummary.replayRejected === true;
  const relayMockStaleLeaseRejected =
    relayMockPayload.staleLeaseRejected === true &&
    relayMockSummary.staleLeaseRejected === true;
  const relayMockAckIdempotencyReady =
    relayMockPayload.ackIdempotencyVerified === true &&
    relayMockSummary.ackIdempotencyVerified === true &&
    Number.isSafeInteger(relayMockPayload.acknowledgedEnvelopeCount) &&
    relayMockPayload.acknowledgedEnvelopeCount > 0;
  const relayMockPlaintextWireReady =
    relayMockPayload.plaintextAbsentFromServerVisibleWire === true &&
    relayMockSummary.plaintextAbsentFromServerVisibleWire === true &&
    relayMock.rawPlaintextIncluded === false;
  const relayMockWireBytesSemanticsReady =
    relayMockPayload.wireBytesMeasured === true &&
    relayMockSummary.wireBytesMeasured === true &&
    relayMock.rawPublicWireBytesIncluded === false;
  const relayMockContractReady =
    redactedClientReleaseInputReady(relayMock, relayMockAcceptanceSchemaVersion) &&
    secureClientRelayMockE2eReady(relayMockPayload) &&
    relayMockSummary.ok === true &&
    Array.isArray(relayMockSummary.remainingGates) &&
    relayMockSummary.remainingGates.length === 0 &&
    relayMockExactFiveOperationsReady &&
    relayMockExactSixOuterFieldsReady &&
    relayMockReplayRejected &&
    relayMockStaleLeaseRejected &&
    relayMockAckIdempotencyReady &&
    relayMockPlaintextWireReady &&
    relayMockWireBytesSemanticsReady;

  const rustCryptoNativeResults = Array.isArray(rustCrypto.nativeResults)
    ? rustCrypto.nativeResults
    : [];
  const rustCryptoNativeTestsReady =
    rustCryptoNativeResults.length > 0 &&
    rustCryptoNativeResults.every((result) => result?.ok === true) &&
    rustCryptoSummary.nativeTestCount === rustCryptoNativeResults.length;
  const rustCryptoVectorCorpusReady =
    rustCrypto.vectorCorpus?.ok === true &&
    rustCrypto.vectorCorpus?.redacted === true &&
    rustCrypto.vectorCorpus?.rawPrivateMaterialIncluded === false &&
    rustCrypto.vectorCorpus?.rawPlaintextIncluded === false &&
    rustCrypto.vectorCorpus?.rawPublicWireBytesIncluded === false &&
    Number(rustCrypto.vectorCorpus?.entryCount || 0) > 0;
  const rustCryptoReportReady =
    redactedClientReleaseInputReady(rustCrypto, rustCryptoSchemaVersion) &&
    rustCryptoSummary.verificationPassed === true &&
    rustCryptoSummary.metadataResistanceReady === true &&
    rustCryptoSummary.vectorCorpusGenerated === true &&
    rustCryptoNativeTestsReady &&
    rustCryptoVectorCorpusReady;
  const rustCryptoReviewReady =
    rustCryptoSummary.reviewSignoffReady === true &&
    rustCryptoSummary.reviewerSignatureVerified === true &&
    rustCryptoSummary.releaseOwnerSignatureVerified === true;

  const platformCryptoNativeResults = Array.isArray(platformCrypto.nativeResults)
    ? platformCrypto.nativeResults
    : [];
  const platformCryptoMatrix = Array.isArray(platformCrypto.platformMatrix)
    ? platformCrypto.platformMatrix
    : [];
  const platformCryptoReportReady =
    redactedClientReleaseInputReady(platformCrypto, platformCryptoSchemaVersion) &&
    platformCryptoSummary.verificationPassed === true &&
    platformCryptoNativeResults.length > 0 &&
    platformCryptoNativeResults.every((result) => result?.ok === true) &&
    platformCryptoSummary.nativeTestCount === platformCryptoNativeResults.length &&
    platformCryptoMatrix.length > 0 &&
    platformCryptoSummary.platformCount === platformCryptoMatrix.length &&
    platformCryptoSummary.hostNativeSecretStoreReady === true;

  const androidPlatformCryptoReportReady =
    redactedClientReleaseInputReady(
      androidPlatformCrypto,
      androidPlatformCryptoSchemaVersion
    ) &&
    androidPlatformCrypto.verifier ===
      "tools/scripts/client-android-native-tests.mjs" &&
    androidPlatformCryptoSummary.ok === true &&
    androidPlatformCryptoSummary.platformCryptoAcceptanceReady === true &&
    androidPlatformCryptoSummary.platformCustodyContractReady === true &&
    androidPlatformCryptoSummary.platformAuthorizationContractReady === true &&
    androidPlatformCryptoSummary.rustFfiActionContractReady === true &&
    androidPlatformCryptoSummary.mlsMemberRemoveReleaseActionReady === true &&
    androidPlatformCryptoSummary.unknownReleaseActionsFailClosed === true &&
    androidPlatformCryptoSummary.nativeTestClassCount === 6 &&
    androidPlatformCryptoSummary.privatePathsIncluded === false;

  const remainingGates = [
    ...(releaseInputRedactionCoversClientRefs && reportRedactionProof.ready === true
      ? []
      : ["release-input redaction scan covers client relay and cryptography reports"]),
    ...(relayMockContractReady
      ? []
      : ["client relay mock exact operation, envelope, replay, lease, ACK, and wire contract ready"]),
    ...(rustCryptoReportReady
      ? []
      : ["client Rust cryptography report ready"]),
    ...(rustCryptoReviewReady
      ? []
      : ["client Rust cryptographic review signatures ready"]),
    ...(platformCryptoReportReady
      ? []
      : ["client platform cryptography report ready"]),
    ...(androidPlatformCryptoReportReady
      ? []
      : ["Android platform cryptography acceptance report ready"])
  ];
  return {
    ready: remainingGates.length === 0,
    remainingGates,
    requiredRefs,
    releaseInputRedactionCoversClientRefs,
    relayMockContractReady,
    relayMockExactFiveOperationsReady,
    relayMockExactSixOuterFieldsReady,
    relayMockReplayRejected,
    relayMockStaleLeaseRejected,
    relayMockAckIdempotencyReady,
    relayMockPlaintextWireReady,
    relayMockWireBytesSemanticsReady,
    rustCryptoReportReady,
    rustCryptoNativeTestsReady,
    rustCryptoVectorCorpusReady,
    rustCryptoReviewReady,
    platformCryptoReportReady,
    androidPlatformCryptoReportReady,
    reportRefs: {
      relayMock: relayMockReportPath,
      rustCrypto: rustCryptoReportPath,
      platformCrypto: platformCryptoReportPath,
      androidPlatformCrypto: androidPlatformCryptoReportPath
    }
  };
}

function runClientRelayCryptoInputsReadinessSelfTest() {
  const digest = `sha256:${"a".repeat(64)}`;
  const relayMockPayload = {
    ok: true,
    schemaVersion: "licolite.secure-client-relay.mock-e2e-report.v1",
    protocolVersion: "secure-client-relay-test",
    coreContractDigest: digest,
    coreConformanceDigest: digest,
    operationCount: 5,
    outerEnvelopeFieldCount: 6,
    exactFiveOperationsObserved: true,
    exactSixOuterFieldsObserved: true,
    exactConformanceCorpusVerified: true,
    replayRejected: true,
    staleLeaseRejected: true,
    activeLeaseSuppressed: true,
    ackIdempotencyVerified: true,
    duplicateAckFenceBound: true,
    mailboxBackpressureCatalogBound: true,
    plaintextAbsentFromServerVisibleWire: true,
    wireBytesMeasured: true,
    acknowledgedEnvelopeCount: 1
  };
  const relayMockSummary = {
    ok: true,
    remainingGates: [],
    exactFiveOperationsObserved: true,
    exactSixOuterFieldsObserved: true,
    replayRejected: true,
    staleLeaseRejected: true,
    activeLeaseSuppressed: true,
    ackIdempotencyVerified: true,
    duplicateAckFenceBound: true,
    mailboxBackpressureCatalogBound: true,
    plaintextAbsentFromServerVisibleWire: true,
    wireBytesMeasured: true
  };
  const relayMock = {
    ok: true,
    schemaVersion: relayMockAcceptanceSchemaVersion,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    reportLeakScan: true,
    mock: relayMockPayload,
    summary: relayMockSummary
  };
  const rustCrypto = {
    ok: true,
    schemaVersion: rustCryptoSchemaVersion,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    reportLeakScan: true,
    nativeResults: [{ id: "native-crypto", ok: true }],
    vectorCorpus: {
      ok: true,
      redacted: true,
      rawPrivateMaterialIncluded: false,
      rawPlaintextIncluded: false,
      rawPublicWireBytesIncluded: false,
      entryCount: 1
    },
    summary: {
      verificationPassed: true,
      metadataResistanceReady: true,
      nativeTestCount: 1,
      vectorCorpusGenerated: true,
      reviewSignoffReady: true,
      reviewerSignatureVerified: true,
      releaseOwnerSignatureVerified: true
    }
  };
  const platformCrypto = {
    ok: true,
    schemaVersion: platformCryptoSchemaVersion,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    reportLeakScan: true,
    nativeResults: [{ id: "platform-crypto", ok: true }],
    platformMatrix: [{ platform: "test", status: "complete" }],
    summary: {
      verificationPassed: true,
      nativeTestCount: 1,
      platformCount: 1,
      hostNativeSecretStoreReady: true
    }
  };
  const androidPlatformCrypto = {
    ok: true,
    schemaVersion: androidPlatformCryptoSchemaVersion,
    verifier: "tools/scripts/client-android-native-tests.mjs",
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    reportLeakScan: true,
    summary: {
      ok: true,
      platformCryptoAcceptanceReady: true,
      platformCustodyContractReady: true,
      platformAuthorizationContractReady: true,
      rustFfiActionContractReady: true,
      mlsMemberRemoveReleaseActionReady: true,
      unknownReleaseActionsFailClosed: true,
      nativeTestClassCount: 6,
      privatePathsIncluded: false
    }
  };
  const reportRedactionProof = {
    ready: true,
    scannedRefs: [
      relayMockReportPath,
      rustCryptoReportPath,
      platformCryptoReportPath,
      androidPlatformCryptoReportPath
    ]
  };
  const complete = summarizeClientRelayCryptoInputs({
    relayMock,
    rustCrypto,
    platformCrypto,
    androidPlatformCrypto,
    reportRedactionProof
  });
  const summarizeRelayMutation = (mockPatch, summaryPatch) =>
    summarizeClientRelayCryptoInputs({
      relayMock: {
        ...relayMock,
        mock: { ...relayMockPayload, ...mockPatch },
        summary: { ...relayMockSummary, ...summaryPatch }
      },
      rustCrypto,
      platformCrypto,
      androidPlatformCrypto,
      reportRedactionProof
    });
  const invalidOperationCount = summarizeRelayMutation(
    { operationCount: 4 },
    {}
  );
  const invalidOuterFieldCount = summarizeRelayMutation(
    { outerEnvelopeFieldCount: 5 },
    {}
  );
  const acceptedReplay = summarizeRelayMutation(
    { replayRejected: false },
    { replayRejected: false }
  );
  const acceptedStaleLease = summarizeRelayMutation(
    { staleLeaseRejected: false },
    { staleLeaseRejected: false }
  );
  const nonIdempotentAck = summarizeRelayMutation(
    { ackIdempotencyVerified: false },
    { ackIdempotencyVerified: false }
  );
  const plaintextOnWire = summarizeRelayMutation(
    { plaintextAbsentFromServerVisibleWire: false },
    { plaintextAbsentFromServerVisibleWire: false }
  );
  const unmeasuredWireBytes = summarizeRelayMutation(
    { wireBytesMeasured: false },
    { wireBytesMeasured: false }
  );
  const rawRustPlaintext = summarizeClientRelayCryptoInputs({
    relayMock,
    rustCrypto: { ...rustCrypto, rawPlaintextIncluded: true },
    platformCrypto,
    androidPlatformCrypto,
    reportRedactionProof
  });
  const rawAndroidPrivateMaterial = summarizeClientRelayCryptoInputs({
    relayMock,
    rustCrypto,
    platformCrypto,
    androidPlatformCrypto: {
      ...androidPlatformCrypto,
      rawPrivateMaterialIncluded: true
    },
    reportRedactionProof
  });
  const legacyPlatformCrypto = summarizeClientRelayCryptoInputs({
    relayMock,
    rustCrypto,
    platformCrypto: {
      ...platformCrypto,
      schemaVersion: "licolite.secure-mesh.platform-secret-store-matrix-report.v1"
    },
    androidPlatformCrypto,
    reportRedactionProof
  });
  const ok = complete.ready === true &&
    invalidOperationCount.ready === false &&
    invalidOuterFieldCount.ready === false &&
    acceptedReplay.ready === false &&
    acceptedStaleLease.ready === false &&
    nonIdempotentAck.ready === false &&
    plaintextOnWire.ready === false &&
    unmeasuredWireBytes.ready === false &&
    rawRustPlaintext.ready === false &&
    rawAndroidPrivateMaterial.ready === false &&
    legacyPlatformCrypto.ready === false;
  return {
    ok,
    completeEvidenceAccepted: complete.ready === true,
    invalidOperationCountRejected: invalidOperationCount.ready === false,
    invalidOuterFieldCountRejected: invalidOuterFieldCount.ready === false,
    replayAcceptanceRejected: acceptedReplay.ready === false,
    staleLeaseAcceptanceRejected: acceptedStaleLease.ready === false,
    nonIdempotentAckRejected: nonIdempotentAck.ready === false,
    plaintextWireRejected: plaintextOnWire.ready === false,
    unmeasuredWireBytesRejected: unmeasuredWireBytes.ready === false,
    rawRustPlaintextRejected: rawRustPlaintext.ready === false,
    rawAndroidPrivateMaterialRejected: rawAndroidPrivateMaterial.ready === false,
    legacyPlatformCryptoSchemaRejected: legacyPlatformCrypto.ready === false
  };
}

function assertNoLeak(value, label) {
  const text = JSON.stringify(value);
  for (const [kind, pattern] of leakPatterns) {
    if (pattern.test(text)) {
      throw new Error(`${label} contains sensitive data: ${kind}`);
    }
  }
}

function sanitizeError(error) {
  return String(error instanceof Error ? error.message : error)
    .replace(/\/Users\/[^/\s"]+/gu, "<user-home>")
    .replace(/\/private\/var\/folders\/[^\s"]+/gu, "<local-temp>")
    .replace(/[A-Za-z]:\\[^\s"]+/gu, "<local-path>")
    .replace(/file:\/\/\/[^\s"]+/gu, "file:///<redacted>")
    .replace(/Bearer\s+\S+/gu, "Bearer [redacted]")
    .replace(/\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]+\b/gu, "[redacted]")
    .slice(0, 1200);
}

const contract = await loadSecureClientContract();
const {
  evaluateSecureClientMeshEvidenceRefReportReadiness,
  SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
  SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS,
  SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH
} = contract;
const blocker = SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.find((item) => item === "release proof bundle");
if (!blocker) {
  throw new Error("Client-pinned Secure Client Mesh contract does not define release proof bundle blocker");
}
if (args.has("--client-relay-crypto-readiness-self-test")) {
  const selfTest = runClientRelayCryptoInputsReadinessSelfTest();
  console.log(JSON.stringify(selfTest, null, 2));
  if (selfTest.ok !== true) {
    process.exitCode = 1;
  }
  process.exit();
}
if (args.has("--release-proof-contract-readiness-self-test")) {
  const selfTest = runReleaseProofContractReadinessSelfTest();
  console.log(JSON.stringify(selfTest, null, 2));
  if (selfTest.ok !== true) {
    process.exitCode = 1;
  }
  process.exit();
}

const sourceResults = [];
for (const check of sourceChecks) {
  sourceResults.push(await evaluateSourceCheck(check));
}
const updateReleaseVerifier = runUpdateReleaseVerifier();
const physicalEvidenceManifestVerifier = runPhysicalEvidenceManifestVerifier();
const releaseProofRedactionRunId = `secure-mesh-release-redaction:${randomUUID()}`;
const reportRedactionVerifier = runReportRedactionVerifier(releaseProofRedactionRunId);
const updateReleaseReportRaw = updateReleaseVerifier.ok ? await readJson(updateReleaseReportPath) : {};
const physicalMatrixReportRaw = await readJsonIfPresent(physicalMatrixReportPath);
const androidPhysicalInstallLaunchReportRaw = await readJsonIfPresent(androidPhysicalInstallLaunchReportPath);
const physicalEvidenceManifestReportRaw = await readJsonIfPresent(physicalEvidenceManifestReportPath);
const checkedAt = new Date().toISOString();
const releaseInputFreshness = summarizeReleaseInputFreshness({
  updateRelease: updateReleaseReportRaw,
  physicalMatrix: physicalMatrixReportRaw,
  androidPhysicalInstallLaunch: androidPhysicalInstallLaunchReportRaw,
  physicalEvidenceManifest: physicalEvidenceManifestReportRaw
}, checkedAt);
const releaseInputFreshnessSelfTest = runReleaseInputFreshnessSelfTest();
const updateReleaseReport = updateReleaseVerifier.ok ? summarizeUpdateReport(updateReleaseReportRaw) : {};
const physicalMatrixReport = summarizePhysicalMatrixReport(physicalMatrixReportRaw);
const androidPhysicalInstallLaunchReport = summarizeAndroidPhysicalInstallLaunchReport(
  androidPhysicalInstallLaunchReportRaw
);
	  const physicalEvidenceManifest = summarizePhysicalEvidenceManifest(
	    physicalEvidenceManifestReportRaw
	  );
	const physicalMatrixContractReadiness = summarizeContractReadiness(
	  evaluateSecureClientMeshEvidenceRefReportReadiness(
	    physicalMatrixReportRaw,
	    "physical device matrix"
	  ),
	  "physical matrix contract readiness"
	);
	const physicalEvidenceManifestContractReadiness = summarizeContractReadiness(
	  evaluateSecureClientMeshEvidenceRefReportReadiness(
	    physicalEvidenceManifestReportRaw,
	    "physical device matrix"
	  ),
	  "physical evidence manifest contract readiness"
	);
	  const windowsImplementation = summarizeWindowsImplementation(
	    await readJsonIfPresent(windowsImplementationReportPath)
	  );
const reportRedactionProof = await summarizeReportRedactionProof(
  await readJsonIfPresent(reportRedactionReportPath),
  releaseProofRedactionRunId
);
const redactionFreshnessSelfTest = await runReportRedactionFreshnessSelfTest();
	const physicalEvidenceManifestReadinessSelfTest =
	  runPhysicalEvidenceManifestReadinessSelfTest();
	const releaseProofContractReadinessSelfTest =
	  runReleaseProofContractReadinessSelfTest();
const clientRelayCryptoInputsReadinessSelfTest =
  runClientRelayCryptoInputsReadinessSelfTest();
const clientRelayCryptoInputs = summarizeClientRelayCryptoInputs({
  relayMock: await readJsonIfPresent(relayMockReportPath),
  rustCrypto: await readJsonIfPresent(rustCryptoReportPath),
  platformCrypto: await readJsonIfPresent(platformCryptoReportPath),
  androidPlatformCrypto: await readJsonIfPresent(androidPlatformCryptoReportPath),
  reportRedactionProof
});
// `ok` proves that the client-owned reducer and locally available evidence are
// internally valid. Physical devices, independent review and signed-host
// receipts remain represented by `productionReady`/`remainingGates` and must
// not turn the local implementation gate into an impossible prerequisite.
const ok = sourceResults.every((check) => check.ok) &&
  updateReleaseVerifier.ok &&
  physicalEvidenceManifestVerifier.ok &&
	  reportRedactionVerifier.ok &&
	  updateReleaseReport.ok === true &&
	  physicalMatrixReport.inputIntegrityReady === true &&
	  physicalEvidenceManifest.inputIntegrityReady === true &&
	  reportRedactionProof.ready === true &&
	  redactionFreshnessSelfTest.ok === true &&
	  physicalEvidenceManifestReadinessSelfTest.ok === true &&
	  releaseProofContractReadinessSelfTest.ok === true &&
	  clientRelayCryptoInputsReadinessSelfTest.ok === true &&
  releaseInputFreshnessSelfTest.ok === true &&
  clientRelayCryptoInputs.relayMockContractReady === true &&
  clientRelayCryptoInputs.androidPlatformCryptoReportReady === true;
const productionReady = false;
const scopeEvidence = await createSecureClientMeshE2eeRefReportScope({
  contract,
  reportRef: reportPath,
  blocker,
  checkedAt
});
const ubuntuLinuxPackageUpdateReady = physicalEvidenceManifest.ubuntuLinuxPackageUpdateReady === true;
const windowsLocalImplementationReady =
  windowsImplementation.ready === true &&
  physicalEvidenceManifest.windowsLocalImplementationReady === true;
const windowsNativeHostEvidenceReady =
  physicalEvidenceManifest.windowsNativeHostEvidenceReady === true;
	const remainingGates = dedupeRemainingGates([
  ...(
    windowsLocalImplementationReady
      ? []
      : [
          ubuntuLinuxPackageUpdateReady
            ? "Windows installer/package execution proof on declared production hosts"
            : "Windows and Linux installer/package execution proof on declared production hosts"
        ]
  ),
	  ...(windowsNativeHostEvidenceReady ? [] : ["Windows installer or portable replacement execution proof"]),
	  ...(reportRedactionProof.ready === true
	    ? []
	    : ["redacted report leakage scan over release evidence inputs"]),
  ...(physicalMatrixReport.inputIntegrityReady === true
    ? []
    : ["physical device matrix v2 schema and producer integrity ready"]),
  ...(physicalEvidenceManifest.inputIntegrityReady === true
    ? []
    : ["physical evidence manifest v2 schema and producer integrity ready"]),
  ...(clientRelayCryptoInputs.ready === true
    ? []
    : clientRelayCryptoInputs.remainingGates),
	  ...(releaseInputFreshness.ready === true
	    ? []
	    : releaseInputFreshness.remainingGates),
	  ...(physicalMatrixContractReadiness.ready === true
	    ? []
	    : (physicalMatrixContractReadiness.remainingGates.length > 0
	        ? physicalMatrixContractReadiness.remainingGates
	        : ["physical device matrix contract evidence ready"])),
	  ...(physicalEvidenceManifestContractReadiness.ready === true
	    ? []
	    : (physicalEvidenceManifestContractReadiness.remainingGates.length > 0
	        ? physicalEvidenceManifestContractReadiness.remainingGates
	        : ["physical evidence manifest contract evidence ready"]))
		]);
const report = {
  ok,
  schemaVersion: "licolite.secure-mesh.release-proof-bundle-report.v1",
  evidenceRefSchemaVersion: SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
  verifier: "tools/scripts/client-secure-mesh-release-proof-bundle.mjs",
  generatedBy: "tools/scripts/client-secure-mesh-release-proof-bundle.mjs",
  generatedAt: checkedAt,
  checkedAt,
  sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
  blocker,
  diagnosticStatus: "incomplete",
  productionReady,
  releaseReady: false,
  evidenceKind: "redacted-release-proof-bundle-gap-report",
  redacted: true,
  rawPrivateMaterialIncluded: false,
  rawPlaintextIncluded: false,
  rawPublicWireBytesIncluded: false,
  reportLeakScan: true,
  releaseProofConfig: {
    ref: releaseProofConfig.configRef,
    schemaVersion: releaseProofConfig.schemaVersion,
    inputReportCount: Object.keys(releaseProofConfig.inputReports).length,
    verifierCommandCount: Object.keys(releaseProofConfig.verifierCommands).length,
    freshnessWindowCount: Object.keys(releaseProofConfig.freshnessWindows).length,
    sourceCheckCount: sourceChecks.length
  },
  ...scopeEvidence,
  contractBinding: {
    sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    canonicalBlocker: blocker,
    canonicalBlockerCount: SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.length
  },
  sourceResults,
  updateReleaseVerifier,
  physicalEvidenceManifestVerifier,
  releaseProofEvidence: {
    updateReleaseReport: updateReleaseReportPath,
    ...updateReleaseReport,
	    physicalMatrixReport: physicalMatrixReportPath,
	    physicalMatrix: physicalMatrixReport,
	    physicalMatrixContractReadiness,
	    physicalEvidenceManifestReport: physicalEvidenceManifestReportPath,
	    physicalEvidenceManifest,
	    physicalEvidenceManifestContractReadiness,
	    windowsImplementation,
    reportRedactionVerifier,
    reportRedactionProof,
    redactionFreshnessSelfTest,
	    physicalEvidenceManifestReadinessSelfTest,
	    releaseProofContractReadinessSelfTest,
	    clientRelayCryptoInputsReadinessSelfTest,
    releaseInputFreshness,
    releaseInputFreshnessSelfTest,
    clientRelayCryptoInputs,
    androidPhysicalInstallLaunch: androidPhysicalInstallLaunchReport
  },
  requiredProductionProofClasses: [
    "consumer-verifiable update manifest and purpose-separated verification keys",
    "signed revocation, downgrade-rejection, and rollback safety evidence",
    "downgrade rejection on release-built clients",
    "Windows installer or portable replacement execution proof, or accepted fail-closed Windows security blocker",
    "Ubuntu/Linux package or update proof",
    "Android physical install and launch evidence",
    "physical Secure Mesh matrix linked by redacted manifest",
    "client-owned relay mock exact five-operation and six-field wire contract",
    "client relay replay, stale lease, ACK idempotency, no-plaintext, and wire-byte semantics",
    "client Rust and platform cryptography reports with redacted review evidence",
    "cross-report redaction scan over release evidence inputs"
  ],
	  summary: {
	    verificationPassed: ok,
	    bundleDiagnosticOk:
	      sourceResults.every((check) => check.ok) &&
	      updateReleaseVerifier.ok &&
	      reportRedactionVerifier.ok &&
	      updateReleaseReport.ok === true &&
	      releaseInputFreshness.ready === true,
	    sourceCheckCount: sourceResults.length,
    releaseInputFreshnessReady: releaseInputFreshness.ready === true,
    releaseInputFreshnessCurrentCount: releaseInputFreshness.currentCount,
    releaseInputFreshnessStaleOrInvalidCount: releaseInputFreshness.staleOrInvalidCount,
    releaseInputFreshnessFailedLabels: releaseInputFreshness.failedLabels,
    releaseInputFreshnessSelfTestReady: releaseInputFreshnessSelfTest.ok === true,
    updateReleaseVerifierPassed: updateReleaseVerifier.ok,
    physicalEvidenceManifestVerifierPassed: physicalEvidenceManifestVerifier.ok,
    reportRedactionVerifierPassed: reportRedactionVerifier.ok,
    reportRedactionReady: reportRedactionProof.ready === true,
    redactionFreshnessSelfTestReady: redactionFreshnessSelfTest.ok === true,
	    physicalEvidenceManifestReadinessSelfTestReady:
	      physicalEvidenceManifestReadinessSelfTest.ok === true,
	    releaseProofContractReadinessSelfTestReady:
	      releaseProofContractReadinessSelfTest.ok === true,
	    forgedPhysicalMatrixSummaryReadyRejected:
	      releaseProofContractReadinessSelfTest.forgedPhysicalMatrixSummaryReadyRejected === true,
	    forgedPhysicalEvidenceManifestSummaryReadyRejected:
	      releaseProofContractReadinessSelfTest.forgedPhysicalEvidenceManifestSummaryReadyRejected === true,
	    legacyPhysicalMatrixSchemaRejected:
	      releaseProofContractReadinessSelfTest.legacyPhysicalMatrixSchemaRejected === true,
	    legacyPhysicalEvidenceManifestSchemaRejected:
	      releaseProofContractReadinessSelfTest.legacyPhysicalEvidenceManifestSchemaRejected === true,
	    androidPhysicalInstallLaunchLocalReadyDiagnosticOnly:
	      releaseProofContractReadinessSelfTest.androidPhysicalInstallLaunchLocalReadyDiagnosticOnly === true,
	    physicalMatrixContractReadinessReady:
	      physicalMatrixContractReadiness.ready === true,
	    physicalMatrixContractReadinessReason:
	      physicalMatrixContractReadiness.reason,
	    physicalMatrixContractReadinessRemainingGateCount:
	      physicalMatrixContractReadiness.remainingGateCount,
	    physicalMatrixContractReadinessSourceOfTruthAccepted:
	      physicalMatrixContractReadiness.sourceOfTruthAccepted === true,
	    physicalMatrixContractReadinessProvenanceAccepted:
	      physicalMatrixContractReadiness.provenanceAccepted === true,
	    physicalMatrixContractReadinessScopeAccepted:
	      physicalMatrixContractReadiness.missingRequiredScopeClaims.length === 0 &&
	      physicalMatrixContractReadiness.missingRequiredScopeEvidenceClaims.length === 0,
	    physicalEvidenceManifestContractReadinessReady:
	      physicalEvidenceManifestContractReadiness.ready === true,
	    physicalEvidenceManifestContractReadinessReason:
	      physicalEvidenceManifestContractReadiness.reason,
	    physicalEvidenceManifestContractReadinessRemainingGateCount:
	      physicalEvidenceManifestContractReadiness.remainingGateCount,
	    physicalEvidenceManifestContractReadinessSourceOfTruthAccepted:
	      physicalEvidenceManifestContractReadiness.sourceOfTruthAccepted === true,
	    physicalEvidenceManifestContractReadinessProvenanceAccepted:
	      physicalEvidenceManifestContractReadiness.provenanceAccepted === true,
	    physicalEvidenceManifestContractReadinessScopeAccepted:
	      physicalEvidenceManifestContractReadiness.missingRequiredScopeClaims.length === 0 &&
	      physicalEvidenceManifestContractReadiness.missingRequiredScopeEvidenceClaims.length === 0,
	    physicalEvidenceManifestDiagnosticOnlyRejected:
      physicalEvidenceManifestReadinessSelfTest.diagnosticOnlyRejected === true,
    physicalEvidenceManifestReleaseEvidenceRequired:
      physicalEvidenceManifestReadinessSelfTest.releaseEvidenceRequired === true,
    physicalEvidenceManifestLegacySchemaRejected:
      physicalEvidenceManifestReadinessSelfTest.legacySchemaRejected === true,
    physicalEvidenceManifestPlatformSystemAuthorizationReady:
      physicalEvidenceManifest.platformSystemAuthorizationReleaseReady === true,
    physicalEvidenceManifestAndroidSystemCredentialReleaseReady:
      physicalEvidenceManifest.androidSystemCredentialReleaseReady === true,
    physicalEvidenceManifestMacosSingleSystemAuthorizationReleaseReady:
      physicalEvidenceManifest.macosSingleSystemAuthorizationReleaseReady === true,
    physicalEvidenceManifestIosSystemLocalAuthReleaseReady:
      physicalEvidenceManifest.iosSystemLocalAuthReleaseReady === true,
    physicalEvidenceManifestPlatformSystemAuthorizationRequired:
      physicalEvidenceManifestReadinessSelfTest.platformSystemAuthorizationRequired === true,
    physicalEvidenceManifestAndroidAppPasswordPromptRejected:
      physicalEvidenceManifestReadinessSelfTest.androidAppPasswordPromptRejected === true,
    physicalEvidenceManifestMacosRepeatedAuthorizationRejected:
      physicalEvidenceManifestReadinessSelfTest.macosRepeatedAuthorizationRejected === true,
    physicalEvidenceManifestMacosAppPasswordPromptRejected:
      physicalEvidenceManifestReadinessSelfTest.macosAppPasswordPromptRejected === true,
    physicalEvidenceManifestIosAppCredentialPromptRejected:
      physicalEvidenceManifestReadinessSelfTest.iosAppCredentialPromptRejected === true,
    releaseInputRedactionDigestsCurrent:
      reportRedactionProof.scannedRefDigestsCurrent === true,
    releaseInputRedactionDigestManifestExact:
      reportRedactionProof.digestManifestExact === true,
    releaseInputRedactionRunIdMatched:
      reportRedactionProof.redactionRunIdMatched === true,
    releaseInputRedactionDigestCount:
      reportRedactionProof.scannedRefDigestCount,
    clientRelayCryptoInputsReady: clientRelayCryptoInputs.ready === true,
    clientRelayCryptoInputsReadinessSelfTestReady:
      clientRelayCryptoInputsReadinessSelfTest.ok === true,
    completeClientRelayCryptoEvidenceAccepted:
      clientRelayCryptoInputsReadinessSelfTest.completeEvidenceAccepted === true,
    invalidRelayOperationCountRejected:
      clientRelayCryptoInputsReadinessSelfTest.invalidOperationCountRejected === true,
    invalidRelayOuterFieldCountRejected:
      clientRelayCryptoInputsReadinessSelfTest.invalidOuterFieldCountRejected === true,
    relayReplayAcceptanceRejected:
      clientRelayCryptoInputsReadinessSelfTest.replayAcceptanceRejected === true,
    relayStaleLeaseAcceptanceRejected:
      clientRelayCryptoInputsReadinessSelfTest.staleLeaseAcceptanceRejected === true,
    relayNonIdempotentAckRejected:
      clientRelayCryptoInputsReadinessSelfTest.nonIdempotentAckRejected === true,
    relayPlaintextWireRejected:
      clientRelayCryptoInputsReadinessSelfTest.plaintextWireRejected === true,
    unmeasuredRelayWireBytesRejected:
      clientRelayCryptoInputsReadinessSelfTest.unmeasuredWireBytesRejected === true,
    rawRustCryptoPlaintextRejected:
      clientRelayCryptoInputsReadinessSelfTest.rawRustPlaintextRejected === true,
    rawAndroidCryptoPrivateMaterialRejected:
      clientRelayCryptoInputsReadinessSelfTest.rawAndroidPrivateMaterialRejected === true,
    legacyPlatformCryptoSchemaRejected:
      clientRelayCryptoInputsReadinessSelfTest.legacyPlatformCryptoSchemaRejected === true,
    releaseInputRedactionCoversClientRefs:
      clientRelayCryptoInputs.releaseInputRedactionCoversClientRefs === true,
    relayMockContractReady:
      clientRelayCryptoInputs.relayMockContractReady === true,
    relayMockExactFiveOperationsReady:
      clientRelayCryptoInputs.relayMockExactFiveOperationsReady === true,
    relayMockExactSixOuterFieldsReady:
      clientRelayCryptoInputs.relayMockExactSixOuterFieldsReady === true,
    relayMockReplayRejected:
      clientRelayCryptoInputs.relayMockReplayRejected === true,
    relayMockStaleLeaseRejected:
      clientRelayCryptoInputs.relayMockStaleLeaseRejected === true,
    relayMockAckIdempotencyReady:
      clientRelayCryptoInputs.relayMockAckIdempotencyReady === true,
    relayMockPlaintextWireReady:
      clientRelayCryptoInputs.relayMockPlaintextWireReady === true,
    relayMockWireBytesSemanticsReady:
      clientRelayCryptoInputs.relayMockWireBytesSemanticsReady === true,
    rustCryptoReportReady:
      clientRelayCryptoInputs.rustCryptoReportReady === true,
    rustCryptoNativeTestsReady:
      clientRelayCryptoInputs.rustCryptoNativeTestsReady === true,
    rustCryptoVectorCorpusReady:
      clientRelayCryptoInputs.rustCryptoVectorCorpusReady === true,
    rustCryptoReviewReady:
      clientRelayCryptoInputs.rustCryptoReviewReady === true,
    platformCryptoReportReady:
      clientRelayCryptoInputs.platformCryptoReportReady === true,
    androidPlatformCryptoReportReady:
      clientRelayCryptoInputs.androidPlatformCryptoReportReady === true,
			    physicalEvidenceManifestLocalReadyDiagnostic:
			      physicalEvidenceManifest.localReadyDiagnostic === true,
		    physicalEvidenceManifestInputIntegrityReady:
		      physicalEvidenceManifest.inputIntegrityReady === true,
		    physicalEvidenceManifestInputSchemaStatus:
		      String(physicalEvidenceManifest.inputSchemaStatus || "unknown"),
		    physicalEvidenceManifestInputSchemaFailureCount:
		      Number(physicalEvidenceManifest.inputSchemaFailureCount || 0),
		    physicalEvidenceManifestDiagnosticOk:
		      physicalEvidenceManifest.diagnosticOk === true,
	    physicalEvidenceManifestRedactionReady:
	      physicalEvidenceManifest.redactionReady === true,
	    physicalEvidenceManifestIntegrityReady:
	      physicalEvidenceManifest.manifestIntegrityReady === true,
	    physicalEvidenceManifestChainReady:
	      physicalEvidenceManifest.physicalEvidenceChainReady === true,
	    physicalEvidenceManifestEvidenceChainComplete:
	      physicalEvidenceManifest.evidenceChainComplete === true,
		    physicalEvidenceManifestLocalReleaseEvidenceReadyDiagnostic:
		      physicalEvidenceManifest.localReleaseEvidenceReadyDiagnostic === true,
		    physicalMatrixAllPhysicalScenariosReady:
		      physicalMatrixReport.allPhysicalScenariosReady === true,
		    physicalMatrixInputIntegrityReady:
		      physicalMatrixReport.inputIntegrityReady === true,
		    physicalMatrixInputSchemaStatus:
		      String(physicalMatrixReport.inputSchemaStatus || "unknown"),
		    physicalMatrixInputSchemaFailureCount:
		      Number(physicalMatrixReport.inputSchemaFailureCount || 0),
			    physicalMatrixLocalPhysicalEvidenceChainReadyDiagnostic:
			      physicalMatrixReport.localPhysicalEvidenceChainReadyDiagnostic === true,
		    physicalMatrixLocalEvidenceChainCompleteDiagnostic:
		      physicalMatrixReport.localEvidenceChainCompleteDiagnostic === true,
		    physicalMatrixLocalReleaseEvidenceReadyDiagnostic:
		      physicalMatrixReport.localReleaseEvidenceReadyDiagnostic === true,
		    androidPhysicalInstallLaunchLocalReadyDiagnostic:
		      androidPhysicalInstallLaunchReport.localReadyDiagnostic === true,
    physicalMatrixAndroidPlatformSecretStoreReady:
      physicalMatrixReport.androidPlatformSecretStoreReady === true,
    physicalMatrixAndroidPhysicalSecretStoreBindingReady:
      physicalMatrixReport.androidPhysicalSecretStoreBindingReady === true,
	    physicalMatrixAndroidPhysicalSystemCredentialAuthReady:
	      physicalMatrixReport.androidPhysicalSystemCredentialAuthReady === true,
    physicalMatrixAndroidPhysicalKeyStoreHardwareAuthReady:
      physicalMatrixReport.androidPhysicalKeyStoreHardwareAuthReady === true,
    physicalMatrixAndroidPhysicalKeyStoreSecurityLevelName:
      String(physicalMatrixReport.androidPhysicalKeyStoreSecurityLevelName || ""),
    physicalMatrixAndroidPhysicalKeyStoreInsideSecureHardware:
      physicalMatrixReport.androidPhysicalKeyStoreInsideSecureHardware === true,
    physicalMatrixAndroidPhysicalKeyStoreUserAuthenticationHardwareEnforced:
      physicalMatrixReport.androidPhysicalKeyStoreUserAuthenticationHardwareEnforced === true,
    physicalMatrixAndroidPhysicalKeyStoreUnlockedDeviceRequired:
      physicalMatrixReport.androidPhysicalKeyStoreUnlockedDeviceRequired === true,
	    physicalMatrixAndroidPhysicalCallbackContractReady:
	      physicalMatrixReport.androidPhysicalCallbackContractReady === true,
    physicalMatrixAndroidPhysicalRawJsonSecretOverridesProvenAbsent:
      physicalMatrixReport.androidPhysicalRawJsonSecretOverridesProvenAbsent === true,
    physicalMatrixAndroidPhysicalRawJsonSecretOverridesUsed:
      physicalMatrixReport.androidPhysicalRawJsonSecretOverridesUsed === true,
    physicalMatrixAndroidPhysicalRawJsonSecretOverridesUnknown:
      physicalMatrixReport.androidPhysicalRawJsonSecretOverridesUnknown === true,
    physicalMatrixAndroidInstallLaunchSchemaDrift:
      physicalMatrixReport.androidPhysicalInstallLaunchSchemaDrift === true,
    physicalMatrixAndroidInstallLaunchSchemaDriftFieldCount:
      Number(physicalMatrixReport.androidPhysicalInstallLaunchSchemaDriftFieldCount || 0),
    physicalMatrixAndroidInstallLaunchSchemaStatus:
      String(physicalMatrixReport.androidPhysicalInstallLaunchSchemaStatus || "unknown"),
    physicalMatrixAndroidAppPasswordPromptUsed:
      physicalMatrixReport.androidPhysicalAppPasswordPromptUsed === true,
	    physicalMatrixAndroidMissingFieldsAbsent:
	      physicalMatrixReport.androidPhysicalMissingFieldsAbsent === true,
	    physicalMatrixAndroidMissingFieldAuditPresent:
	      physicalMatrixReport.androidPhysicalMissingFieldAuditPresent === true,
	    physicalMatrixAndroidMissingFields:
	      stableStringList(physicalMatrixReport.androidPhysicalMissingFields),
	    physicalMatrixAndroidMissingFieldCount:
	      Number(physicalMatrixReport.androidPhysicalMissingFieldCount || 0),
	    physicalMatrixAndroidWeakProofFieldsAbsent:
	      physicalMatrixReport.androidPhysicalWeakProofFieldsAbsent === true,
	    physicalMatrixAndroidWeakProofFieldAuditPresent:
	      physicalMatrixReport.androidPhysicalWeakProofFieldAuditPresent === true,
	    physicalMatrixAndroidWeakProofFields:
	      stableStringList(physicalMatrixReport.androidPhysicalWeakProofFields),
	    physicalMatrixAndroidWeakProofFieldCount:
	      Number(physicalMatrixReport.androidPhysicalWeakProofFieldCount || 0),
    physicalMatrixIosPlatformSecretStoreReady:
      physicalMatrixReport.iosPlatformSecretStoreReady === true,
    physicalMatrixIosPhysicalSecretStoreBindingReady:
      physicalMatrixReport.iosPhysicalSecretStoreBindingReady === true,
	    physicalMatrixIosUserPresencePolicyReady:
	      physicalMatrixReport.iosUserPresencePolicyReady === true,
	    physicalMatrixIosProductionCallbackAuthReady:
	      physicalMatrixReport.iosProductionCallbackAuthReady === true,
	    physicalMatrixIosCallbackReadsUseSharedLAContext:
	      physicalMatrixReport.iosCallbackReadsUseSharedLAContext === true,
	    physicalMatrixIosSingleSystemAuthorizationContextVerified:
	      physicalMatrixReport.iosSingleSystemAuthorizationContextVerified === true,
	    physicalMatrixIosCallbackAuthContextAttachedToAllReads:
	      physicalMatrixReport.iosCallbackAuthContextAttachedToAllReads === true,
	    physicalMatrixAppPasswordPromptUsedPresent:
	      physicalMatrixReport.appPasswordPromptUsedPresent === true,
	    physicalMatrixAppCredentialPromptUsedPresent:
	      physicalMatrixReport.appCredentialPromptUsedPresent === true,
	    physicalMatrixKeyMaterialExportedPresent:
	      physicalMatrixReport.keyMaterialExportedPresent === true,
	    physicalMatrixIosSystemLocalAuthPromptReady:
	      physicalMatrixReport.iosSystemLocalAuthPromptReady === true,
    physicalMatrixIosKeychainAccessControlNotDowngraded:
      physicalMatrixReport.iosKeychainAccessControlNotDowngraded === true,
    physicalMatrixIosNonInteractiveFailClosedReady:
      physicalMatrixReport.iosNonInteractiveFailClosedReady === true,
    physicalMatrixIosCancelLockFailClosedReady:
      physicalMatrixReport.iosCancelLockFailClosedReady === true,
    physicalMatrixIosAppPasswordPromptUsed:
      physicalMatrixReport.iosAppPasswordPromptUsed === true,
    physicalMatrixIosAppCredentialPromptUsed:
      physicalMatrixReport.iosAppCredentialPromptUsed === true,
    physicalMatrixIosKeyMaterialExported:
      physicalMatrixReport.iosKeyMaterialExported === true,
    physicalMatrixIosPhysicalCallbackContractReady:
      physicalMatrixReport.iosPhysicalCallbackContractReady === true,
    physicalMatrixIosPhysicalRawJsonSecretOverridesProvenAbsent:
      physicalMatrixReport.iosPhysicalRawJsonSecretOverridesProvenAbsent === true,
    physicalMatrixMacosUserPresencePolicyReady:
      physicalMatrixReport.macosUserPresencePolicyReady === true,
    physicalMatrixMacosSingleSystemAuthorizationContextVerified:
      physicalMatrixReport.macosSingleSystemAuthorizationContextVerified === true,
    physicalMatrixMacosInteractiveAuthorizationPromptBudgetReady:
      physicalMatrixReport.macosInteractiveAuthorizationPromptBudgetReady === true,
    physicalMatrixMacosAppPasswordPromptUsed:
      physicalMatrixReport.macosAppPasswordPromptUsed === true,
    physicalMatrixMacosAppCredentialPromptUsed:
      physicalMatrixReport.macosAppCredentialPromptUsed === true,
    physicalMatrixMacosSystemCredentialEntrySurface:
      physicalMatrixReport.macosSystemCredentialEntrySurface,
    physicalEvidenceManifestAndroidPlatformSecretStoreReady:
      physicalEvidenceManifest.androidPlatformSecretStoreReady === true,
    physicalEvidenceManifestAndroidPhysicalSecretStoreBindingReady:
      physicalEvidenceManifest.androidPhysicalSecretStoreBindingReady === true,
	    physicalEvidenceManifestAndroidPhysicalSystemCredentialAuthReady:
	      physicalEvidenceManifest.androidPhysicalSystemCredentialAuthReady === true,
    physicalEvidenceManifestAndroidPhysicalKeyStoreHardwareAuthReady:
      physicalEvidenceManifest.androidPhysicalKeyStoreHardwareAuthReady === true,
    physicalEvidenceManifestAndroidPhysicalKeyStoreSecurityLevelName:
      String(physicalEvidenceManifest.androidPhysicalKeyStoreSecurityLevelName || ""),
    physicalEvidenceManifestAndroidPhysicalKeyStoreInsideSecureHardware:
      physicalEvidenceManifest.androidPhysicalKeyStoreInsideSecureHardware === true,
    physicalEvidenceManifestAndroidPhysicalKeyStoreUserAuthenticationHardwareEnforced:
      physicalEvidenceManifest.androidPhysicalKeyStoreUserAuthenticationHardwareEnforced === true,
    physicalEvidenceManifestAndroidPhysicalKeyStoreUnlockedDeviceRequired:
      physicalEvidenceManifest.androidPhysicalKeyStoreUnlockedDeviceRequired === true,
	    physicalEvidenceManifestAndroidPhysicalCallbackContractReady:
	      physicalEvidenceManifest.androidPhysicalCallbackContractReady === true,
    physicalEvidenceManifestAndroidPhysicalRawJsonSecretOverridesProvenAbsent:
      physicalEvidenceManifest.androidPhysicalRawJsonSecretOverridesProvenAbsent === true,
    physicalEvidenceManifestAndroidPhysicalRawJsonSecretOverridesUsed:
      physicalEvidenceManifest.androidPhysicalRawJsonSecretOverridesUsed === true,
    physicalEvidenceManifestAndroidPhysicalRawJsonSecretOverridesUnknown:
      physicalEvidenceManifest.androidPhysicalRawJsonSecretOverridesUnknown === true,
    physicalEvidenceManifestAndroidInstallLaunchSchemaDrift:
      physicalEvidenceManifest.androidPhysicalInstallLaunchSchemaDrift === true,
    physicalEvidenceManifestAndroidInstallLaunchSchemaDriftFieldCount:
      Number(physicalEvidenceManifest.androidPhysicalInstallLaunchSchemaDriftFieldCount || 0),
    physicalEvidenceManifestAndroidInstallLaunchSchemaStatus:
      String(physicalEvidenceManifest.androidPhysicalInstallLaunchSchemaStatus || "unknown"),
	    physicalEvidenceManifestAndroidMissingFieldsAbsent:
	      physicalEvidenceManifest.androidPhysicalMissingFieldsAbsent === true,
	    physicalEvidenceManifestAndroidMissingFieldAuditPresent:
	      physicalEvidenceManifest.androidPhysicalMissingFieldAuditPresent === true,
	    physicalEvidenceManifestAndroidMissingFields:
	      stableStringList(physicalEvidenceManifest.androidPhysicalMissingFields),
	    physicalEvidenceManifestAndroidMissingFieldCount:
	      Number(physicalEvidenceManifest.androidPhysicalMissingFieldCount || 0),
	    physicalEvidenceManifestAndroidWeakProofFieldsAbsent:
	      physicalEvidenceManifest.androidPhysicalWeakProofFieldsAbsent === true,
	    physicalEvidenceManifestAndroidWeakProofFieldAuditPresent:
	      physicalEvidenceManifest.androidPhysicalWeakProofFieldAuditPresent === true,
	    physicalEvidenceManifestAndroidWeakProofFields:
	      stableStringList(physicalEvidenceManifest.androidPhysicalWeakProofFields),
	    physicalEvidenceManifestAndroidWeakProofFieldCount:
	      Number(physicalEvidenceManifest.androidPhysicalWeakProofFieldCount || 0),
	    physicalEvidenceManifestAndroidUserAuthenticationRequested:
	      physicalEvidenceManifest.androidUserAuthenticationRequested === true,
	    physicalEvidenceManifestAndroidUserAuthenticationPromptStarted:
	      physicalEvidenceManifest.androidUserAuthenticationPromptStarted === true,
	    physicalEvidenceManifestAndroidSystemCredentialPromptNotCompleted:
	      physicalEvidenceManifest.androidSystemCredentialPromptNotCompleted === true,
	    physicalEvidenceManifestAndroidUserAuthenticationBlockerReason:
	      physicalEvidenceManifest.androidUserAuthenticationBlockerReason,
	    physicalEvidenceManifestAndroidUserAuthenticationUserActionRequired:
	      physicalEvidenceManifest.androidUserAuthenticationUserActionRequired,
	    physicalEvidenceManifestAndroidUserAuthenticationDiagnosticCode:
	      physicalEvidenceManifest.androidUserAuthenticationDiagnosticCode,
	    physicalEvidenceManifestAndroidUserAuthenticationResultCodePresent:
	      physicalEvidenceManifest.androidUserAuthenticationResultCodePresent === true,
	    physicalEvidenceManifestAndroidUserAuthenticationResultCode:
	      Number(physicalEvidenceManifest.androidUserAuthenticationResultCode || 0),
	    physicalEvidenceManifestAndroidUserAuthenticationCredentialEntrySurface:
	      physicalEvidenceManifest.androidUserAuthenticationCredentialEntrySurface,
	    physicalEvidenceManifestAndroidUserAuthenticationSystemAuthenticationOnly:
	      physicalEvidenceManifest.androidUserAuthenticationSystemAuthenticationOnly === true,
	    physicalEvidenceManifestAndroidUserAuthenticationAppLockScreenCredentialCollection:
	      physicalEvidenceManifest.androidUserAuthenticationAppLockScreenCredentialCollection === true,
	    physicalEvidenceManifestAndroidUserAuthenticationKeyMaterialExported:
	      physicalEvidenceManifest.androidUserAuthenticationKeyMaterialExported === true,
	    physicalEvidenceManifestAndroidLocalSecretStore:
	      physicalEvidenceManifest.androidLocalSecretStore,
	    physicalEvidenceManifestIosPlatformSecretStoreReady:
	      physicalEvidenceManifest.iosPlatformSecretStoreReady === true,
    physicalEvidenceManifestIosPhysicalSecretStoreBindingReady:
      physicalEvidenceManifest.iosPhysicalSecretStoreBindingReady === true,
	    physicalEvidenceManifestIosUserPresencePolicyReady:
	      physicalEvidenceManifest.iosUserPresencePolicyReady === true,
	    physicalEvidenceManifestIosDeviceTrustBlockerEvidence:
	      physicalEvidenceManifest.iosDeviceTrustBlockerEvidence || {},
	    physicalEvidenceManifestIosUserPresenceMissingFields:
	      stableStringList(physicalEvidenceManifest.iosUserPresenceMissingFields),
	    physicalEvidenceManifestIosUserPresenceMissingFieldCount:
	      Number(physicalEvidenceManifest.iosUserPresenceMissingFieldCount || 0),
	    physicalEvidenceManifestIosUserPresenceMissingFieldsAbsent:
	      physicalEvidenceManifest.iosUserPresenceMissingFieldsAbsent === true,
	    physicalEvidenceManifestIosPhysicalPrerequisiteMissingFields:
	      stableStringList(physicalEvidenceManifest.iosPhysicalPrerequisiteMissingFields),
	    physicalEvidenceManifestIosPhysicalPrerequisiteMissingFieldCount:
	      Number(physicalEvidenceManifest.iosPhysicalPrerequisiteMissingFieldCount || 0),
	    physicalEvidenceManifestIosPhysicalPrerequisiteMissingFieldsAbsent:
	      physicalEvidenceManifest.iosPhysicalPrerequisiteMissingFieldsAbsent === true,
	    physicalEvidenceManifestIosProductionCallbackAuthReady:
	      physicalEvidenceManifest.iosProductionCallbackAuthReady === true,
	    physicalEvidenceManifestIosCallbackReadsUseSharedLAContext:
	      physicalEvidenceManifest.iosCallbackReadsUseSharedLAContext === true,
	    physicalEvidenceManifestIosSingleSystemAuthorizationContextVerified:
	      physicalEvidenceManifest.iosSingleSystemAuthorizationContextVerified === true,
	    physicalEvidenceManifestIosCallbackAuthContextAttachedToAllReads:
	      physicalEvidenceManifest.iosCallbackAuthContextAttachedToAllReads === true,
	    physicalEvidenceManifestAppPasswordPromptUsedPresent:
	      physicalEvidenceManifest.appPasswordPromptUsedPresent === true,
	    physicalEvidenceManifestAppCredentialPromptUsedPresent:
	      physicalEvidenceManifest.appCredentialPromptUsedPresent === true,
	    physicalEvidenceManifestKeyMaterialExportedPresent:
	      physicalEvidenceManifest.keyMaterialExportedPresent === true,
	    physicalEvidenceManifestIosSystemLocalAuthPromptReady:
      physicalEvidenceManifest.iosSystemLocalAuthPromptReady === true,
    physicalEvidenceManifestIosKeychainAccessControlNotDowngraded:
      physicalEvidenceManifest.iosKeychainAccessControlNotDowngraded === true,
    physicalEvidenceManifestIosNonInteractiveFailClosedReady:
      physicalEvidenceManifest.iosNonInteractiveFailClosedReady === true,
    physicalEvidenceManifestIosCancelLockFailClosedReady:
      physicalEvidenceManifest.iosCancelLockFailClosedReady === true,
    physicalEvidenceManifestIosAppPasswordPromptUsed:
      physicalEvidenceManifest.iosAppPasswordPromptUsed === true,
    physicalEvidenceManifestIosAppCredentialPromptUsed:
      physicalEvidenceManifest.iosAppCredentialPromptUsed === true,
    physicalEvidenceManifestIosKeyMaterialExported:
      physicalEvidenceManifest.iosKeyMaterialExported === true,
    physicalEvidenceManifestIosPhysicalCallbackContractReady:
      physicalEvidenceManifest.iosPhysicalCallbackContractReady === true,
	    physicalEvidenceManifestIosPhysicalRawJsonSecretOverridesProvenAbsent:
	      physicalEvidenceManifest.iosPhysicalRawJsonSecretOverridesProvenAbsent === true,
	    physicalEvidenceManifestIosWaitForDeviceAttempted:
	      physicalEvidenceManifest.iosWaitForDeviceAttempted === true,
	    physicalEvidenceManifestIosWaitForDeviceTimeoutSeconds:
	      Number(physicalEvidenceManifest.iosWaitForDeviceTimeoutSeconds || 0),
	    physicalEvidenceManifestIosRemediationDeviceIdentifiersIncluded:
	      physicalEvidenceManifest.iosRemediationDeviceIdentifiersIncluded === true,
	    physicalEvidenceManifestIosRemediationSawUnavailablePhysicalDevice:
	      physicalEvidenceManifest.iosRemediationSawUnavailablePhysicalDevice === true,
	    physicalEvidenceManifestCurrentIosDeviceTrustState:
	      physicalEvidenceManifest.currentIosDeviceTrustState,
	    physicalEvidenceManifestCurrentIosTrustBlockerStaleCandidate:
	      physicalEvidenceManifest.currentIosTrustBlockerStaleCandidate === true,
	    physicalEvidenceManifestIosLocalSecretStore:
	      physicalEvidenceManifest.iosLocalSecretStore,
		    macosProductionEntitlementTemplateReady:
		      physicalEvidenceManifest.macosProductionEntitlementTemplateReady === true,
		    physicalEvidenceManifestMacosProductionEntitlementFailClosedReady:
		      physicalEvidenceManifest.macosProductionEntitlementFailClosedReady === true,
		    physicalEvidenceManifestMacosProductionEntitlementGateAccepted:
		      physicalEvidenceManifest.macosProductionEntitlementGateAccepted === true,
		    physicalEvidenceManifestMacosProductionEntitlementMissingFailClosed:
		      physicalEvidenceManifest.macosProductionEntitlementMissingFailClosed === true,
		    physicalEvidenceManifestMacosStandardKeychainRejectedForProduction:
		      physicalEvidenceManifest.macosStandardKeychainRejectedForProduction === true,
		    physicalEvidenceManifestMacosStandardKeychainUserPresenceAcceptedForProduction:
		      physicalEvidenceManifest.macosStandardKeychainUserPresenceAcceptedForProduction === true,
		    physicalEvidenceManifestMacosStandardKeychainFallbackFailClosedReady:
		      physicalEvidenceManifest.macosStandardKeychainFallbackFailClosedReady === true,
		    physicalEvidenceManifestMacosKeyringReleaseEvidenceReady:
		      physicalEvidenceManifest.macosKeyringReleaseEvidenceReady === true,
	    physicalEvidenceManifestMacosLocalSecretStore:
	      physicalEvidenceManifest.macosLocalSecretStore,
	    physicalEvidenceManifestMacosHostSecretStoreReady:
	      physicalEvidenceManifest.macosHostSecretStoreReady === true,
	    physicalEvidenceManifestMacosReleaseBundleShapeReady:
	      physicalEvidenceManifest.macosReleaseBundleShapeReady === true,
	    physicalEvidenceManifestMacosReleaseCliProofReady:
	      physicalEvidenceManifest.macosReleaseCliProofReady === true,
	    physicalEvidenceManifestMacosUserPresenceProofAttempted:
	      physicalEvidenceManifest.macosUserPresenceProofAttempted === true,
	    physicalEvidenceManifestMacosUserPresenceFailClosedUntilProductionEntitled:
	      physicalEvidenceManifest.macosUserPresenceFailClosedUntilProductionEntitled === true,
	    physicalEvidenceManifestMacosUserPresenceBlockerCategory:
	      physicalEvidenceManifest.macosUserPresenceBlockerCategory,
	    macosUserPresencePolicyReady: physicalEvidenceManifest.macosUserPresencePolicyReady === true,
    macosSingleSystemAuthorizationContextVerified:
      physicalEvidenceManifest.macosSingleSystemAuthorizationContextVerified === true,
    macosInteractiveAuthorizationPromptBudgetReady:
      physicalEvidenceManifest.macosInteractiveAuthorizationPromptBudgetReady === true,
    macosInteractiveAuthorizationAttemptCount:
      physicalEvidenceManifest.macosInteractiveAuthorizationAttemptCount,
    macosMaximumInteractiveAuthorizationAttemptsPerProof:
      physicalEvidenceManifest.macosMaximumInteractiveAuthorizationAttemptsPerProof,
    macosAppPasswordPromptUsed:
      physicalEvidenceManifest.macosAppPasswordPromptUsed === true,
    macosAppCredentialPromptUsed:
      physicalEvidenceManifest.macosAppCredentialPromptUsed === true,
    macosSystemCredentialEntrySurface:
      physicalEvidenceManifest.macosSystemCredentialEntrySurface,
    androidUserAuthenticationBlockedBeforeKeyStoreE2e:
      physicalEvidenceManifest.androidUserAuthenticationBlockedBeforeKeyStoreE2e === true,
    androidUserAuthenticationAppCredentialPromptUsed:
      physicalEvidenceManifest.androidUserAuthenticationAppCredentialPromptUsed === true,
    androidUserAuthenticationAppPasswordPromptUsed:
      physicalEvidenceManifest.androidUserAuthenticationAppPasswordPromptUsed === true,
    iosPhysicalDeviceDiscovered: physicalEvidenceManifest.iosPhysicalDeviceDiscovered === true,
    iosDeveloperModeOrDeviceTrustBlocked:
      physicalEvidenceManifest.iosDeveloperModeOrDeviceTrustBlocked === true,
	    iosReleaseBuiltDesktopCliSelected:
	      physicalEvidenceManifest.iosReleaseBuiltDesktopCliSelected === true,
	    physicalEvidenceManifestUbuntuLinuxReleaseEvidenceReady:
	      physicalEvidenceManifest.ubuntuLinuxReleaseEvidenceReady === true,
	    physicalEvidenceManifestUbuntuLinuxLocalSecretStore:
	      physicalEvidenceManifest.ubuntuLinuxLocalSecretStore,
		    physicalEvidenceManifestUbuntuLinuxHostSecretStoreReady:
		      physicalEvidenceManifest.ubuntuLinuxHostSecretStoreReady === true,
		    physicalEvidenceManifestUbuntuLinuxSecretStoreAuthorizationPolicyPresent:
		      physicalEvidenceManifest.ubuntuLinuxSecretStoreAuthorizationPolicyPresent === true,
		    physicalEvidenceManifestUbuntuLinuxSecretStoreAuthorizationPolicyReady:
		      physicalEvidenceManifest.ubuntuLinuxSecretStoreAuthorizationPolicyReady === true,
		    ubuntuLinuxPackageUpdateReady,
    windowsLocalImplementationReady,
    windowsNativeHostEvidenceReady,
    macosActualReleaseBundleVerified: updateReleaseReport.macosActualReleaseBundleVerified === true,
    productionReady,
    releaseReady: false,
    reportLeakScan: true,
    remainingGates
  }
};

assertNoLeak(report, "secure mesh release proof bundle report");
const safeReportPath = resolveSafeReportPath(repoRoot, reportPath);
await fs.mkdir(path.dirname(safeReportPath), { recursive: true });
atomicWriteReportJson(repoRoot, reportPath, report);

console.log(JSON.stringify({
  ok,
  report: reportPath,
  sourceOfTruth: report.sourceOfTruth,
  blocker: report.blocker,
  diagnosticStatus: report.diagnosticStatus,
  productionReady,
  sourceCheckCount: sourceResults.length,
  updateReleaseVerifierPassed: updateReleaseVerifier.ok,
	  physicalEvidenceManifestContractReadinessReady:
	    physicalEvidenceManifestContractReadiness.ready === true,
	  physicalEvidenceManifestLocalReadyDiagnostic:
	    physicalEvidenceManifest.localReadyDiagnostic === true,
	  physicalEvidenceManifestLocalReleaseEvidenceReadyDiagnostic:
	    physicalEvidenceManifest.localReleaseEvidenceReadyDiagnostic === true,
  releaseInputFreshnessReady: releaseInputFreshness.ready === true,
  releaseInputFreshnessStaleOrInvalidCount: releaseInputFreshness.staleOrInvalidCount,
  physicalMatrixLinked: physicalMatrixReport.ok === true,
	  physicalMatrixContractReadinessReady:
	    physicalMatrixContractReadiness.ready === true,
	  physicalMatrixLocalPhysicalEvidenceChainReadyDiagnostic:
	    physicalMatrixReport.localPhysicalEvidenceChainReadyDiagnostic === true,
	  androidPhysicalInstallLaunchLocalReadyDiagnostic:
	    androidPhysicalInstallLaunchReport.localReadyDiagnostic === true,
  physicalMatrixPartialScenarioCount: physicalMatrixReport.partialScenarioCount,
  physicalMatrixAndroidPlatformSecretStoreReady:
    physicalMatrixReport.androidPlatformSecretStoreReady === true,
  physicalMatrixAndroidMissingFields:
    stableStringList(physicalMatrixReport.androidPhysicalMissingFields),
  physicalMatrixAndroidMissingFieldCount:
    Number(physicalMatrixReport.androidPhysicalMissingFieldCount || 0),
  physicalMatrixAndroidWeakProofFieldsAbsent:
    physicalMatrixReport.androidPhysicalWeakProofFieldsAbsent === true,
  physicalMatrixAndroidWeakProofFields:
    stableStringList(physicalMatrixReport.androidPhysicalWeakProofFields),
  physicalMatrixAndroidWeakProofFieldCount:
    Number(physicalMatrixReport.androidPhysicalWeakProofFieldCount || 0),
  physicalEvidenceManifestAndroidMissingFields:
    stableStringList(physicalEvidenceManifest.androidPhysicalMissingFields),
  physicalEvidenceManifestAndroidMissingFieldCount:
    Number(physicalEvidenceManifest.androidPhysicalMissingFieldCount || 0),
  physicalEvidenceManifestAndroidWeakProofFields:
    stableStringList(physicalEvidenceManifest.androidPhysicalWeakProofFields),
  physicalEvidenceManifestAndroidWeakProofFieldCount:
    Number(physicalEvidenceManifest.androidPhysicalWeakProofFieldCount || 0),
  physicalMatrixIosPlatformSecretStoreReady:
    physicalMatrixReport.iosPlatformSecretStoreReady === true,
  physicalMatrixIosUserPresencePolicyReady:
    physicalMatrixReport.iosUserPresencePolicyReady === true,
  physicalEvidenceManifestIosUserPresencePolicyReady:
    physicalEvidenceManifest.iosUserPresencePolicyReady === true,
	  reportRedactionReady: reportRedactionProof.ready === true,
	  clientRelayCryptoInputsReady: clientRelayCryptoInputs.ready === true,
	  relayMockContractReady: clientRelayCryptoInputs.relayMockContractReady === true,
	  relayMockExactFiveOperationsReady:
	    clientRelayCryptoInputs.relayMockExactFiveOperationsReady === true,
	  relayMockExactSixOuterFieldsReady:
	    clientRelayCryptoInputs.relayMockExactSixOuterFieldsReady === true,
	  relayMockReplayRejected: clientRelayCryptoInputs.relayMockReplayRejected === true,
	  relayMockStaleLeaseRejected:
	    clientRelayCryptoInputs.relayMockStaleLeaseRejected === true,
	  relayMockAckIdempotencyReady:
	    clientRelayCryptoInputs.relayMockAckIdempotencyReady === true,
	  relayMockPlaintextWireReady:
	    clientRelayCryptoInputs.relayMockPlaintextWireReady === true,
	  relayMockWireBytesSemanticsReady:
	    clientRelayCryptoInputs.relayMockWireBytesSemanticsReady === true,
	  rustCryptoReportReady: clientRelayCryptoInputs.rustCryptoReportReady === true,
	  rustCryptoReviewReady: clientRelayCryptoInputs.rustCryptoReviewReady === true,
	  platformCryptoReportReady:
	    clientRelayCryptoInputs.platformCryptoReportReady === true,
	  androidPlatformCryptoReportReady:
	    clientRelayCryptoInputs.androidPlatformCryptoReportReady === true,
	  windowsLocalImplementationReady,
	  windowsNativeHostEvidenceReady,
  macosActualReleaseBundleVerified: updateReleaseReport.macosActualReleaseBundleVerified === true,
  releaseTargetCount: updateReleaseReport.targetCount || 0,
  remainingGateCount: report.summary.remainingGates.length
}, null, 2));

if (!ok || (strict && productionReady !== true)) {
  process.exitCode = 1;
}
