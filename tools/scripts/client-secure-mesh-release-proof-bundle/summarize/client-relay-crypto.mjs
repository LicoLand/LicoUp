import {
  androidPlatformCryptoReportPath,
  platformCryptoReportPath,
  relayMockReportPath,
  rustCryptoReportPath
} from "../config.mjs";
import {
  androidPlatformCryptoSchemaVersion,
  platformCryptoSchemaVersion,
  relayMockAcceptanceSchemaVersion,
  rustCryptoSchemaVersion
} from "../constants.mjs";
import { secureClientRelayMockE2eReady } from "../../lib/secure-client-relay-mock-e2e-report.mjs";
import {
  ANDROID_PLATFORM_CRYPTO_NATIVE_TEST_CLASS_COUNT,
} from "../../lib/secure-mesh-physical-report-coverage.mjs";

export function redactedClientReleaseInputReady(report, expectedSchemaVersion) {
  return report?.ok === true &&
    report.schemaVersion === expectedSchemaVersion &&
    report.redacted === true &&
    report.rawPrivateMaterialIncluded === false &&
    report.rawPlaintextIncluded === false &&
    report.rawPublicWireBytesIncluded === false &&
    report.reportLeakScan === true;
}

export function summarizeClientRelayCryptoInputs({
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
    androidPlatformCryptoSummary.nativeTestClassCount ===
      ANDROID_PLATFORM_CRYPTO_NATIVE_TEST_CLASS_COUNT &&
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
