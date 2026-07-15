#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { loadSecureClientContract } from "./lib/secure-client-contract.mjs";
import { createSecureClientMeshE2eeRefReportScope } from "./lib/secure-client-mesh-e2ee-ref-report.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";
import { loadSecureMeshPhysicalEvidenceConfig } from "./lib/secure-mesh-physical-evidence-config.mjs";
import { loadSecureMeshPhysicalDeviceMatrixConfig } from "./lib/secure-mesh-physical-device-matrix-config.mjs";
import { validateSecureMeshTrustUxV2Report } from "./lib/secure-mesh-trust-ux-reducer.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const args = new Set(process.argv.slice(2));
const strict = args.has("--strict");
const physicalEvidenceConfig = await loadSecureMeshPhysicalEvidenceConfig();
const physicalDeviceMatrixConfig = await loadSecureMeshPhysicalDeviceMatrixConfig();
const physicalReportRefs = physicalEvidenceConfig.linkedReports;
const reportPath = physicalReportRefs.physicalDeviceMatrix;

const leakPatterns = Object.freeze([
  ["local_path", /\/Users\/|\/private\/|\/var\/folders\/|[A-Za-z]:\\/u],
  ["bearer", /Bearer\s+(?!\[redacted\])\S+/u],
  ["token", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u],
  ["pem_material", /-----BEGIN|-----END/u],
  ["device_identifier", /\b(?:UDID|ECID|Serial(?:Number)?|DeviceIdentifier)\s*[:=]\s*[A-Za-z0-9-]{8,}\b/u],
  ["raw_secret_value", /"(?:privateKey|sessionKey|rootKey|chainKey|messageKey|rawSecret|secretMaterial)"\s*:\s*"(?!redacted|\[redacted\])[^"]{8,}"/u]
]);

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function readJsonIfPresent(relativePath) {
  try {
    return JSON.parse(await readText(relativePath));
  } catch {
    return null;
  }
}

function assertNoLeak(value, label) {
  const text = JSON.stringify(value);
  for (const [kind, pattern] of leakPatterns) {
    if (pattern.test(text)) {
      throw new Error(`${label} contains sensitive data: ${kind}`);
    }
  }
}

function dedupe(values) {
  return [...new Set((Array.isArray(values) ? values : [])
    .map((value) => String(value || "").trim())
    .filter(Boolean))];
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

function redactedReportReady(report) {
  return report?.ok === true &&
    report?.redacted === true &&
    report?.rawPrivateMaterialIncluded !== true &&
    report?.rawPlaintextIncluded !== true &&
    report?.rawPublicWireBytesIncluded !== true &&
    report?.reportLeakScan === true;
}

function relayMockCoverage(report) {
  const summary = report?.summary || {};
  const ready = redactedReportReady(report) &&
    report?.schemaVersion === "licolite.secure-client-relay.client-acceptance-report.v1" &&
    summary.exactFiveOperationsObserved === true &&
    summary.exactSixOuterFieldsObserved === true &&
    summary.replayRejected === true &&
    summary.staleLeaseRejected === true &&
    summary.ackIdempotencyVerified === true &&
    summary.plaintextAbsentFromServerVisibleWire === true &&
    summary.wireBytesMeasured === true;
  return {
    report: physicalReportRefs.relayMock,
    ready,
    exactFiveOperationsObserved: summary.exactFiveOperationsObserved === true,
    exactSixOuterFieldsObserved: summary.exactSixOuterFieldsObserved === true,
    replayRejected: summary.replayRejected === true,
    staleLeaseRejected: summary.staleLeaseRejected === true,
    ackIdempotencyVerified: summary.ackIdempotencyVerified === true,
    plaintextAbsentFromServerVisibleWire:
      summary.plaintextAbsentFromServerVisibleWire === true,
    wireBytesMeasured: summary.wireBytesMeasured === true
  };
}

function androidPlatformCryptoCoverage(report) {
  const summary = report?.summary || {};
  const ready = redactedReportReady(report) &&
    report?.schemaVersion === "licolite.secure-mesh.android-platform-crypto-acceptance.v1" &&
    report?.platform === "android" &&
    summary.platformCryptoAcceptanceReady === true &&
    summary.platformCustodyContractReady === true &&
    summary.platformAuthorizationContractReady === true &&
    summary.rustFfiActionContractReady === true &&
    summary.mlsMemberRemoveReleaseActionReady === true &&
    summary.unknownReleaseActionsFailClosed === true &&
    Number(summary.nativeTestClassCount || 0) === 6;
  return {
    report: physicalReportRefs.androidPlatformCrypto,
    ready,
    platformCryptoAcceptanceReady:
      summary.platformCryptoAcceptanceReady === true,
    platformCustodyContractReady:
      summary.platformCustodyContractReady === true,
    platformAuthorizationContractReady:
      summary.platformAuthorizationContractReady === true,
    rustFfiActionContractReady: summary.rustFfiActionContractReady === true,
    mlsMemberRemoveReleaseActionReady:
      summary.mlsMemberRemoveReleaseActionReady === true,
    unknownReleaseActionsFailClosed:
      summary.unknownReleaseActionsFailClosed === true,
    nativeTestClassCount: Number(summary.nativeTestClassCount || 0)
  };
}

function installLaunchCoverage(report) {
  const summary = report?.summary || {};
  return {
    report: physicalReportRefs.androidInstallLaunch,
    present: Boolean(report && Object.keys(report).length > 0),
    redacted: report?.redacted === true,
    ready: redactedReportReady(report),
    physicalDeviceProofReady:
      summary.androidPhysicalDeviceProofReady === true ||
      report?.androidPhysicalDeviceProofReady === true ||
      report?.physicalDevice === true,
    systemCredentialAuthReady:
      summary.androidSystemCredentialAuthReady === true ||
      report?.androidSystemCredentialAuthReady === true,
    runtimeStatusRedacted:
      summary.runtimeStatusRedacted === true || report?.runtimeStatusRedacted === true
  };
}

function platformCryptoCoverage(report) {
  const summary = report?.summary || {};
  const androidReady = report?.ok === true &&
    summary.androidPhysicalSecretStoreBindingReady === true &&
    summary.androidPhysicalSystemCredentialAuthReady === true &&
    summary.androidPhysicalKeyStoreHardwareAuthReady === true &&
    summary.androidPhysicalCallbackContractReady === true &&
    summary.androidPhysicalRawJsonSecretOverridesProvenAbsent === true;
  const iosReady = report?.ok === true &&
    summary.iosPhysicalSecretStoreBindingReady === true &&
    summary.iosUserPresencePolicyReady === true &&
    summary.iosProductionCallbackAuthReady === true &&
    summary.iosSystemLocalAuthPromptReady === true &&
    summary.iosKeychainAccessControlNotDowngraded === true &&
    summary.iosNonInteractiveFailClosedReady === true &&
    summary.iosCancelLockFailClosedReady === true &&
    summary.iosPhysicalCallbackContractReady === true &&
    summary.iosPhysicalRawJsonSecretOverridesProvenAbsent === true;
  const macosReady = report?.ok === true &&
    summary.macosSafeOsStoreAvailable === true &&
    summary.macosExactCapabilitySetValid === true &&
    summary.macosSingleSystemAuthorizationContextVerified === true &&
    summary.macosPromptBudgetSatisfied === true &&
    summary.macosAppCredentialPromptUsed !== true;
  return {
    report: physicalReportRefs.platformSecretStore,
    ok: report?.ok === true,
    androidReady,
    iosReady,
    macosReady,
    ubuntuReady: summary.ubuntuVmSecretStoreReady === true &&
      summary.ubuntuVmSecretStoreBackend === "linux-secret-service-keyring",
    androidPhysicalSecretStoreBindingReady:
      summary.androidPhysicalSecretStoreBindingReady === true,
    androidPhysicalSystemCredentialAuthReady:
      summary.androidPhysicalSystemCredentialAuthReady === true,
    androidPhysicalKeyStoreHardwareAuthReady:
      summary.androidPhysicalKeyStoreHardwareAuthReady === true,
    androidPhysicalCallbackContractReady:
      summary.androidPhysicalCallbackContractReady === true,
    iosPhysicalSecretStoreBindingReady:
      summary.iosPhysicalSecretStoreBindingReady === true,
    iosUserPresencePolicyReady: summary.iosUserPresencePolicyReady === true,
    iosProductionCallbackAuthReady:
      summary.iosProductionCallbackAuthReady === true,
    iosPhysicalCallbackContractReady:
      summary.iosPhysicalCallbackContractReady === true,
    macosKeychainReady: summary.macosSafeOsStoreAvailable === true,
    macosReleaseCliProofReady: summary.macosReleaseCliProofReady === true,
    macosUserPresencePolicyReady:
      summary.macosUserPresencePolicyReady === true ||
      summary.macosSafeOsStoreAvailable === true,
    macosSingleSystemAuthorizationContextVerified:
      summary.macosSingleSystemAuthorizationContextVerified === true,
    macosInteractiveAuthorizationPromptBudgetReady:
      summary.macosPromptBudgetSatisfied === true,
    ubuntuSecretServiceReady:
      summary.ubuntuVmSecretStoreReady === true &&
      summary.ubuntuVmSecretStoreBackend === "linux-secret-service-keyring",
    ubuntuReleaseCliProofReady: summary.ubuntuReleaseCliProofReady === true,
    ubuntuLinuxAdaptiveCustodyReady:
      summary.ubuntuLinuxAdaptiveCustodyReady === true,
    ubuntuLinuxPackageUpdateReady:
      summary.ubuntuLinuxPackageUpdateReady === true,
    remainingGates: Array.isArray(summary.remainingGates)
      ? summary.remainingGates.map((gate) => String(gate || "")).filter(Boolean)
      : []
  };
}

function windowsImplementationReady(report) {
  return report?.ok === true &&
    report?.redacted === true &&
    report?.diagnosticStatus === "implementation_ready_host_evidence_pending" &&
    report?.summary?.windowsLocalBlockersCleared === true &&
    report?.summary?.nativeHostEvidencePending === true &&
    report?.summary?.dpapiOrWindowsHelloProofReady !== true &&
    report?.productionReady !== true &&
    report?.releaseReady !== true;
}

function deriveMatrix({ relayMock, androidPlatformCrypto, androidInstallLaunch, platformCrypto, trustReady, fileReady, windowsReady }) {
  return physicalDeviceMatrixConfig.physicalMatrix.map((entry) => {
    if (entry.scenario === "pairing-and-trust") {
      return {
        ...entry,
        status: trustReady ? "partial" : "missing",
        evidenceReports: trustReady ? [physicalReportRefs.trustUx] : [],
        remainingGates: [
          "Run physical Android and iPhone QR/SAS verification, key-change, rotation, and revocation checks."
        ]
      };
    }
    if (entry.scenario === "command-result") {
      const partial = androidPlatformCrypto.ready || platformCrypto.iosReady;
      return {
        ...entry,
        status: partial ? "partial" : "missing",
        evidenceReports: [
          ...(androidPlatformCrypto.ready ? [androidPlatformCrypto.report] : []),
          ...(relayMock.ready ? [relayMock.report] : []),
          ...(platformCrypto.iosReady ? [platformCrypto.report] : [])
        ],
        remainingGates: [
          "Run physical Android and iPhone client command/result, restart, replay, stale-envelope, and ACK-purge checks."
        ]
      };
    }
    if (entry.scenario === "file-handoff") {
      return {
        ...entry,
        status: fileReady ? "partial" : "missing",
        evidenceReports: fileReady ? [physicalReportRefs.encryptedFileHandoff] : [],
        remainingGates: [
          "Run endpoint-specific file reseal and approved receive-root checks on physical Android and iPhone clients."
        ]
      };
    }
    if (entry.scenario === "relay-protocol") {
      return {
        ...entry,
        status: relayMock.ready ? "partial" : "missing",
        evidenceReports: relayMock.ready ? [relayMock.report] : [],
        remainingGates: relayMock.ready
          ? ["Repeat client ciphertext and replay checks on physical Android and iPhone clients."]
          : ["Run the client-owned relay Mock protocol acceptance."]
      };
    }
    if (entry.scenario === "desktop-release-platforms") {
      const partial = platformCrypto.macosReady || platformCrypto.ubuntuReady || windowsReady;
      return {
        ...entry,
        status: partial ? "partial" : "missing",
        evidenceReports: [
          ...(platformCrypto.ok ? [platformCrypto.report] : []),
          ...(windowsReady ? [physicalReportRefs.windowsImplementation] : [])
        ],
        remainingGates: [
          "Complete release-built macOS, Windows, and Ubuntu client cryptography and publication receipts."
        ]
      };
    }
    return entry;
  });
}

const contract = await loadSecureClientContract();
const {
  SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
  SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS,
  SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH
} = contract;
const blocker = SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.find((item) =>
  item === "physical device matrix"
);
if (!blocker) {
  throw new Error("Client-pinned Secure Client Mesh contract does not define physical device matrix blocker");
}

const sourceResults = await Promise.all(
  physicalDeviceMatrixConfig.sourceChecks.map(evaluateSourceCheck)
);
const [relayMockReport, androidPlatformCryptoReport, androidInstallLaunchReport,
  platformSecretStoreReport, trustUxReport, encryptedFileHandoffReport,
  physicalEvidenceManifestReport, windowsImplementationReport] = await Promise.all([
  readJsonIfPresent(physicalReportRefs.relayMock),
  readJsonIfPresent(physicalReportRefs.androidPlatformCrypto),
  readJsonIfPresent(physicalReportRefs.androidInstallLaunch),
  readJsonIfPresent(physicalReportRefs.platformSecretStore),
  readJsonIfPresent(physicalReportRefs.trustUx),
  readJsonIfPresent(physicalReportRefs.encryptedFileHandoff),
  readJsonIfPresent(physicalEvidenceConfig.reportOutput),
  readJsonIfPresent(physicalReportRefs.windowsImplementation)
]);

const relayMock = relayMockCoverage(relayMockReport);
const androidPlatformCrypto = androidPlatformCryptoCoverage(androidPlatformCryptoReport);
const androidInstallLaunch = installLaunchCoverage(androidInstallLaunchReport);
const platformCrypto = platformCryptoCoverage(platformSecretStoreReport);
const trustContract = validateSecureMeshTrustUxV2Report(trustUxReport);
const trustReady = trustUxReport?.ok === true && trustContract.contractReady === true;
const fileReady = redactedReportReady(encryptedFileHandoffReport);
const windowsReady = windowsImplementationReady(windowsImplementationReport);
const physicalMatrix = deriveMatrix({
  relayMock,
  androidPlatformCrypto,
  androidInstallLaunch,
  platformCrypto,
  trustReady,
  fileReady,
  windowsReady
});
const allPhysicalScenariosReady = physicalMatrix.every((entry) =>
  entry.status === "ready" && entry.remainingGates.length === 0
);
const physicalEvidenceChainReadyForSummary = allPhysicalScenariosReady &&
  relayMock.ready &&
  androidPlatformCrypto.ready &&
  androidInstallLaunch.physicalDeviceProofReady &&
  platformCrypto.androidReady &&
  platformCrypto.iosReady &&
  platformCrypto.macosReady;
const diagnosticOk = sourceResults.every((result) => result.ok) &&
  relayMock.ready &&
  androidPlatformCrypto.ready &&
  platformCrypto.ok &&
  trustReady &&
  fileReady;
const checkedAt = new Date().toISOString();
const scopeEvidence = await createSecureClientMeshE2eeRefReportScope({
  contract,
  reportRef: reportPath,
  blocker,
  checkedAt
});
const remainingGates = dedupe([
  ...platformCrypto.remainingGates,
  ...physicalMatrix.flatMap((entry) => entry.remainingGates),
  ...(androidInstallLaunch.physicalDeviceProofReady
    ? []
    : ["Attach a redacted physical Android install/launch and custody proof."]),
  ...(windowsReady ? [] : ["Complete Windows platform custody proof or accepted fail-closed blocker."]),
  ...(physicalEvidenceManifestReport?.manifestIntegrityReady === true
    ? []
    : ["Regenerate the redacted physical evidence manifest from current client reports."])
]);

const report = {
  ok: diagnosticOk,
  schemaVersion: "licolite.secure-mesh.physical-device-matrix-report.v2",
  evidenceRefSchemaVersion: SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
  verifier: "tools/scripts/client-secure-mesh-physical-device-matrix.mjs",
  generatedBy: "tools/scripts/client-secure-mesh-physical-device-matrix.mjs",
  generatedAt: checkedAt,
  checkedAt,
  sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
  blocker,
  diagnosticStatus: diagnosticOk ? "passed" : "incomplete",
  diagnosticOk,
  allPhysicalScenariosReady,
  physicalEvidenceChainReady: physicalEvidenceChainReadyForSummary,
  evidenceChainComplete: physicalEvidenceChainReadyForSummary,
  releaseEvidenceReady: physicalEvidenceChainReadyForSummary,
  ready: physicalEvidenceChainReadyForSummary,
  productionReady: false,
  releaseReady: false,
  evidenceKind: "redacted-client-platform-cryptography-and-physical-gap-matrix",
  redacted: true,
  rawPrivateMaterialIncluded: false,
  rawPlaintextIncluded: false,
  rawPublicWireBytesIncluded: false,
  reportLeakScan: true,
  physicalEvidenceConfig: {
    ref: physicalEvidenceConfig.configRef,
    schemaVersion: physicalEvidenceConfig.schemaVersion,
    linkedReportCount: Object.keys(physicalReportRefs).length
  },
  physicalDeviceMatrixConfig: {
    ref: physicalDeviceMatrixConfig.configRef,
    schemaVersion: physicalDeviceMatrixConfig.schemaVersion,
    sourceCheckCount: sourceResults.length,
    physicalScenarioCount: physicalMatrix.length
  },
  ...scopeEvidence,
  contractBinding: {
    sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    canonicalBlocker: blocker,
    canonicalBlockerCount: SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.length
  },
  sourceResults,
  evidenceSnapshots: {
    relayMock,
    androidPlatformCrypto,
    androidInstallLaunch,
    platformCrypto,
    trustUx: { report: physicalReportRefs.trustUx, ready: trustReady },
    encryptedFileHandoff: {
      report: physicalReportRefs.encryptedFileHandoff,
      ready: fileReady
    },
    windowsImplementation: {
      report: physicalReportRefs.windowsImplementation,
      ready: windowsReady
    }
  },
  physicalMatrix,
  currentProofSurface: {
    relayProtocolMockReady: relayMock.ready,
    androidPlatformCryptoAcceptanceReady: androidPlatformCrypto.ready,
    androidPhysicalInstallLaunchReady: androidInstallLaunch.ready,
    androidPhysicalDeviceProofPresent:
      androidInstallLaunch.physicalDeviceProofReady,
    androidPlatformSecretStoreReadyForSummary: platformCrypto.androidReady,
    iosPlatformSecretStoreReadyForSummary: platformCrypto.iosReady,
    macosClientCryptographyReady: platformCrypto.macosReady,
    ubuntuClientCryptographyReady: platformCrypto.ubuntuReady,
    physicalEvidenceChainReadyForSummary
  },
  summary: {
    diagnosticOk,
    relayProtocolMockReady: relayMock.ready,
    androidPlatformCryptoAcceptanceReady: androidPlatformCrypto.ready,
    androidPlatformCustodyContractReady:
      androidPlatformCrypto.platformCustodyContractReady,
    androidPlatformAuthorizationContractReady:
      androidPlatformCrypto.platformAuthorizationContractReady,
    androidRustFfiActionContractReady:
      androidPlatformCrypto.rustFfiActionContractReady,
    androidMlsMemberRemoveReleaseActionReady:
      androidPlatformCrypto.mlsMemberRemoveReleaseActionReady,
    androidUnknownReleaseActionsFailClosed:
      androidPlatformCrypto.unknownReleaseActionsFailClosed,
    androidNativeTestClassCount: androidPlatformCrypto.nativeTestClassCount,
    androidPhysicalDeviceProofPresent:
      androidInstallLaunch.physicalDeviceProofReady,
    androidPhysicalSecretStoreBindingReady:
      platformCrypto.androidPhysicalSecretStoreBindingReady,
    androidPhysicalSystemCredentialAuthReady:
      platformCrypto.androidPhysicalSystemCredentialAuthReady,
    androidPhysicalKeyStoreHardwareAuthReady:
      platformCrypto.androidPhysicalKeyStoreHardwareAuthReady,
    androidPhysicalCallbackContractReady:
      platformCrypto.androidPhysicalCallbackContractReady,
    iosPhysicalSecretStoreBindingReady:
      platformCrypto.iosPhysicalSecretStoreBindingReady,
    iosUserPresencePolicyReady: platformCrypto.iosUserPresencePolicyReady,
    iosProductionCallbackAuthReady:
      platformCrypto.iosProductionCallbackAuthReady,
    iosPhysicalCallbackContractReady:
      platformCrypto.iosPhysicalCallbackContractReady,
    iosPhysicalDeviceDiscovered: false,
    macosKeyringReleaseEvidenceReady: platformCrypto.macosReady &&
      platformCrypto.macosReleaseCliProofReady,
    macosUserPresencePolicyReady:
      platformCrypto.macosUserPresencePolicyReady,
    macosSingleSystemAuthorizationContextVerified:
      platformCrypto.macosSingleSystemAuthorizationContextVerified,
    macosInteractiveAuthorizationPromptBudgetReady:
      platformCrypto.macosInteractiveAuthorizationPromptBudgetReady,
    ubuntuLinuxReleaseEvidenceReady: platformCrypto.ubuntuReady &&
      platformCrypto.ubuntuReleaseCliProofReady &&
      platformCrypto.ubuntuLinuxAdaptiveCustodyReady &&
      platformCrypto.ubuntuLinuxPackageUpdateReady,
    windowsLocalImplementationReady: windowsReady,
    windowsNativeHostEvidenceReady: false,
    allPhysicalScenariosReady,
    physicalEvidenceChainReady: physicalEvidenceChainReadyForSummary,
    evidenceChainComplete: physicalEvidenceChainReadyForSummary,
    releaseEvidenceReady: physicalEvidenceChainReadyForSummary,
    productionReady: false,
    releaseReady: false,
    reportLeakScan: true,
    remainingGates
  }
};

assertNoLeak(report, "secure mesh physical device matrix report");
atomicWriteReportJson(
  path.join(repoRoot, "build"),
  reportPath.replace(/^build\//u, ""),
  report
);

console.log(JSON.stringify({
  ok: report.ok,
  report: reportPath,
  diagnosticStatus: report.diagnosticStatus,
  relayProtocolMockReady: report.summary.relayProtocolMockReady,
  androidPlatformCryptoAcceptanceReady:
    report.summary.androidPlatformCryptoAcceptanceReady,
  allPhysicalScenariosReady,
  physicalEvidenceChainReady: report.physicalEvidenceChainReady,
  remainingGateCount: remainingGates.length
}, null, 2));

if (!report.ok || (strict && report.physicalEvidenceChainReady !== true)) {
  process.exitCode = 1;
}
