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
import {
  summarizeClientRelayCryptoInputs
} from "../summarize/client-relay-crypto.mjs";
import {
  ANDROID_PLATFORM_CRYPTO_NATIVE_TEST_CLASS_COUNT,
} from "../../lib/secure-mesh-physical-report-coverage.mjs";

export function runClientRelayCryptoInputsReadinessSelfTest() {
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
      nativeTestClassCount: ANDROID_PLATFORM_CRYPTO_NATIVE_TEST_CLASS_COUNT,
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
