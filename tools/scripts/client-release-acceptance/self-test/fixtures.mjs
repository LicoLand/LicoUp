import {
  SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS,
  SECURE_MESH_TRUST_UX_PRODUCT_TEST_ID,
  SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION,
} from "../../lib/secure-mesh-trust-ux-reducer.mjs";
import { METADATA_PAYLOAD_CLASSES } from "../evidence.mjs";
import {
  ANDROID_PLATFORM_CRYPTO_NATIVE_TEST_CLASS_COUNT,
} from "../../lib/secure-mesh-physical-report-coverage.mjs";

export function selfTestAndroidTrustEvidence(ready) {
  return {
    ok: ready,
    present: ready,
    platform: "android",
    physicalDevice: ready,
    peerVerified: ready,
    capabilityReportValid: ready,
    mandatoryFoundationComplete: ready,
    custodyStrategy: ready ? "os_secure_store" : "",
    safeCustodyReady: ready,
    portableConfigPrivateMaterialAbsent: ready,
    restartReplayReady: ready,
    lifecycleFfiReady: ready,
    trustLifecycleReady: ready,
    qrVerificationReady: ready,
    sasVerificationReady: ready,
    keyChangeBlocksSensitive: ready,
    rotateLifecycleReady: ready,
    revokeBlocksSensitive: ready,
    recoveryRequiresConfirmation: ready,
    status: ready ? "android-physical-trust-lifecycle-verified" : "missing"
  };
}

export function selfTestTrustReport({
  productTrustUxReady = true,
  androidPhysicalTrustReady = true,
  macosTrustReceiptReady = true,
  schemaVersion = SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION,
  includeUnknownAuthorityField = false
} = {}) {
  const selectedTargetReleaseReady =
    productTrustUxReady && androidPhysicalTrustReady && macosTrustReceiptReady;
  const summary = {
    verificationPassed: true,
    mobileNativeTrustActionsReady: true,
    productTrustUxTestsReady: productTrustUxReady,
    productTrustUxReady,
    androidPhysicalTrustLifecycleReady: androidPhysicalTrustReady,
    macosTrustReceiptReady,
    iosSupportStatus: SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS,
    iosReleaseGate: false,
    selectedTargetReleaseReady,
    productionReady: false,
    releaseReady: selectedTargetReleaseReady,
    ...(includeUnknownAuthorityField ? { unrecognizedTrustAuthorityOverride: true } : {})
  };
  return {
    schemaVersion,
    ok: true,
    productionReady: false,
    releaseReady: selectedTargetReleaseReady,
    productTestResults: [{
      id: SECURE_MESH_TRUST_UX_PRODUCT_TEST_ID,
      ok: productTrustUxReady
    }],
    physicalTrustEvidence: {
      android: selfTestAndroidTrustEvidence(androidPhysicalTrustReady),
      ios: {
        ok: false,
        supportStatus: SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS,
        releaseGate: false
      }
    },
    selectedTargetAcceptance: {
      selectedTargets: ["macos", "android"],
      productTrustUxReady,
      androidPhysicalTrustReady,
      macosTrustReceiptReady,
      iosSupportStatus: SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS,
      iosReleaseGate: false,
      selectedTargetReleaseReady
    },
    summary
  };
}

export function selfTestReports({
  plaintextReady = true,
  tamperReady = true,
  reviewSignoffReady = true,
  productTrustUxReady = true,
  androidPhysicalTrustReady = true,
  macosTrustReceiptReady = true,
  trustSchemaVersion = SECURE_MESH_TRUST_UX_REPORT_SCHEMA_VERSION,
  includeUnknownAuthorityField = false
} = {}) {
  const passed = [{ id: "check", ok: true }];
  return {
    pairwise: {
      summary: {
        verificationPassed: true,
        metadataResistanceReady: true,
        reviewSignoffReady,
        reviewerSignatureVerified: reviewSignoffReady,
        releaseOwnerSignatureVerified: reviewSignoffReady,
      },
      metadataResistanceEvidence: {
        schemaVersion: "licolite.secure-mesh.metadata-resistance-evidence.v1",
        sourceStateDigest: `sha256:${"a".repeat(64)}`,
        canonicalWireReportDigest: `sha256:${"d".repeat(64)}`,
        residualMetadataReportDigest: `sha256:${"e".repeat(64)}`,
        adaptiveTopologyReportDigest: `sha256:${"f".repeat(64)}`,
        deterministic: true,
        canonicalEnvelopeReady: true,
        fixedMlsPublicAadReady: true,
        mailboxKeyedDirectionalRotating: true,
        mailboxBoundedOverlapReady: true,
        hostileRelayWireCanariesAbsent: true,
        rawBypassRetired: true,
        payloadClasses: [...METADATA_PAYLOAD_CLASSES],
      },
      nativeResults: tamperReady ? [
        { id: "secure_mesh_pairwise_encrypted_relay_header_hides_ratchet_structure_and_rejects_tamper", ok: true },
        { id: "secure_mesh_pairwise_pc_pc_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_mobile_pc_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_pc_mobile_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_mobile_mobile_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_cli_desktop_command_result_relay_round_trip", ok: true },
        { id: "secure_mesh_pairwise_agent_host_command_result_relay_round_trip", ok: true }
      ] : []
    },
    relayMock: { summary: {
      ok: true,
      exactFiveOperationsObserved: true,
      exactSixOuterFieldsObserved: true,
      plaintextAbsentFromServerVisibleWire: plaintextReady,
      wireBytesMeasured: true,
      replayRejected: true,
      staleLeaseRejected: true,
      ackIdempotencyVerified: true
    } },
    file: { summary: { verificationPassed: true, multiRecipientEndpointSpecificResealProofReady: true, releaseBuiltDesktopFilePolicyReady: true, releaseBuiltDesktopReadyPlatforms: ["macos"], androidPhysicalEndpointFilePolicyReady: true, androidPhysicalReceiveConfirmationReady: true } },
    trust: selfTestTrustReport({
      productTrustUxReady,
      androidPhysicalTrustReady,
      macosTrustReceiptReady,
      schemaVersion: trustSchemaVersion,
      includeUnknownAuthorityField
    }),
    acp: {
      summary: { clientEnvelopeReady: true, gatewaySupportEvidenceProvided: false },
      sourceResults: passed,
      nativeResults: passed
    },
    acpArchive: { summary: { archiveLayerReady: true, releaseFilePolicyReady: true, releaseBuiltDesktopReadyPlatforms: ["macos"] }, sourceResults: passed, nativeResults: passed },
    androidPlatformCrypto: {
      schemaVersion: "licolite.secure-mesh.android-platform-crypto-acceptance.v1",
      verifier: "tools/scripts/client-android-native-tests.mjs",
      ok: true,
      platform: "android",
      redacted: true,
      rawPrivateMaterialIncluded: false,
      rawPlaintextIncluded: false,
      rawPublicWireBytesIncluded: false,
      summary: {
        ok: true,
        platformCryptoAcceptanceReady: true,
        platformCustodyContractReady: true,
        platformAuthorizationContractReady: true,
        rustFfiActionContractReady: true,
        mlsMemberRemoveReleaseActionReady: true,
        unknownReleaseActionsFailClosed: true,
        nativeTestClassCount: ANDROID_PLATFORM_CRYPTO_NATIVE_TEST_CLASS_COUNT,
        privatePathsIncluded: false,
      },
    },
    macosCli: selfTestReleaseCliReport("macos", "3"),
    redaction: { ok: true, summary: { reportRedactionReady: true, hitCount: 0 } },
    externalAcceptance: { productionReady: false },
    optionalExternalServices: { gemini: "unsupported", kimi: "unverified" }
  };
}

export function selfTestReleaseCliReport(platform, digestDigit) {
  return {
    schemaVersion: "licolite.secure-mesh.release-cli-proof-report.v1",
    verifier: "tools/scripts/client-secure-mesh-release-cli-proof.mjs",
    ok: true,
    platform,
    artifactKind: "release-cli-binary",
    sourceStateDigest: `sha256:${"a".repeat(64)}`,
    cliArtifactDigest: `sha256:${digestDigit.repeat(64)}`,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    summary: {
      releaseCliProofReady: true,
      statusReady: true,
      commandExecuteReady: true,
      commandReplayRejected: true,
      filePolicyReady: true,
      fileRouteReady: true,
      fileReceiveDestinationReady: true,
      fileReceiveConfirmationReady: true,
      trustPolicyReady: true,
    },
  };
}
