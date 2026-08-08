export async function checkTrustRelease({ assert, files }) {
  const { readJson, readText } = files;
const trustUx = await readText("tools/scripts/client-secure-mesh-trust-ux.mjs");
const trustUxConfig = await readText("tools/scripts/config/secure-mesh-trust-ux.json");
const trustUxConfigJson = await readJson("tools/scripts/config/secure-mesh-trust-ux.json");
const trustUxConfigHelper = await readText("tools/scripts/lib/secure-mesh-trust-ux-config.mjs");
const trustUxReducer = await readText("tools/scripts/lib/secure-mesh-trust-ux-reducer.mjs");
const clientReleaseAcceptance = await files.readSourceBundle(
  "tools/scripts/client-release-acceptance.mjs",
  "tools/scripts/client-release-acceptance",
  ".mjs",
);
const clientReleaseAcceptanceConfig = await readJson("tools/scripts/config/client-release-acceptance.json");
for (const token of [
  "loadSecureMeshTrustUxConfig",
  "trustUxConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "reportPath = physicalReportRefs.trustUx",
  "physicalReportRefs.androidPlatformCrypto",
  "androidPlatformTrustEvidence",
  "physical-peer-trust-not-proven",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "trust UX",
  "contractBinding"
]) {
  assert(trustUx.includes(token) || trustUxConfig.includes(token),
    `trust UX evidence report/config must keep contract-bound token ${token}`);
}
assert(trustUx.includes("sourceChecks,") &&
  trustUx.includes("nativeTestFilters,") &&
  trustUx.includes("productTestTargets,") &&
  trustUx.includes("expectedMobileNativeTrustActions") &&
  !trustUx.includes("const sourceChecks = Object.freeze([") &&
  !trustUx.includes("const nativeTestFilters = Object.freeze([") &&
  !trustUx.includes("const expectedMobileNativeTrustActions = Object.freeze(["),
  "trust UX must load source checks, native filters, and mobile trust actions from config instead of hardcoding inline arrays");
for (const token of [
  "licomesh.secure-mesh.trust-ux-config.v2",
  "sourceChecks",
  "nativeTestFilters",
  "productTestTargets",
  "apps/desktop/test/mobile_relay_service_test.dart",
  "apps/desktop/test/secure_mesh_panel_test.dart",
  "expectedMobileNativeTrustActions",
  "trust-helper-provides-cross-signing-sas-qr-and-key-change-policy",
  "pub fn sign_device_trust_record",
  "pub fn verify_device_trust_record_json",
  "secure_mesh_device_trust_record_signature_binds_peer_and_expiry",
  "android-release-channel-allows-shared-rust-trust-actions",
  "ios-client-tests-shared-rust-trust-lifecycle",
  "selected-target-trust-reducer-is-v2-and-fail-closed",
  "secure_mesh.deviceTrust.verifyQr"
]) {
  assert(trustUxConfig.includes(token),
    `trust UX config must keep token ${token}`);
}
assert(Array.isArray(trustUxConfigJson.sourceChecks) &&
  trustUxConfigJson.sourceChecks.length >= 10 &&
  Array.isArray(trustUxConfigJson.nativeTestFilters) &&
  trustUxConfigJson.nativeTestFilters.length >= 7 &&
  Array.isArray(trustUxConfigJson.productTestTargets) &&
  trustUxConfigJson.productTestTargets.length >= 2 &&
  Array.isArray(trustUxConfigJson.expectedMobileNativeTrustActions) &&
  trustUxConfigJson.expectedMobileNativeTrustActions.length >= 6,
  "trust UX config must define source checks, native test filters, and expected mobile native trust actions");
for (const token of [
  "loadSecureMeshTrustUxConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "normalizeNativeTestFilters",
  "normalizeProductTestTargets",
  "normalizeExpectedMobileNativeTrustActions",
  "assertNoLeak",
  "source checks must have unique ids"
]) {
  assert(trustUxConfigHelper.includes(token),
    `trust UX config helper must keep safety token ${token}`);
}
for (const token of [
  "licomesh.secure-mesh.trust-ux-report.v2",
  "SECURE_MESH_TRUST_UX_SELECTED_TARGETS",
  "SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS",
  "SECURE_MESH_TRUST_UX_PRODUCT_TEST_ID",
  "reduceSecureMeshTrustUxReadiness",
  "validateSecureMeshTrustUxV2Report",
  "embeddedAndroidPhysicalTrustReady",
  "productionClaimSuppressed",
  "unknownAuthorityFieldsAbsent",
  "runSecureMeshTrustUxReducerSelfTest"
]) {
  assert(trustUxReducer.includes(token),
    `trust UX v2 reducer must keep fail-closed token ${token}`);
}
assert(trustUx.includes("reduceSecureMeshTrustUxReadiness") &&
  trustUx.includes("runSecureMeshTrustUxReducerSelfTest") &&
  trustUx.includes("runProductTests(productTestTargets)") &&
  trustUx.includes("productTestResults"),
  "trust UX producer must use the reproducible v2 reducer and expose its self-test");
assert(clientReleaseAcceptance.includes("validateSecureMeshTrustUxV2Report") &&
  clientReleaseAcceptance.includes("androidPlatformCryptoEvidenceReady") &&
  clientReleaseAcceptance.includes("selected_android_platform_crypto_evidence_not_ready") &&
  clientReleaseAcceptance.includes("selected_ios_${SECURE_MESH_TRUST_UX_IOS_SUPPORT_STATUS}") &&
  clientReleaseAcceptance.includes("includeUnknownAuthorityField"),
  "client release acceptance must consume Trust UX v2 and keep unsupported iOS outside the physical trust gate");
assert(clientReleaseAcceptanceConfig.reports?.trust?.schemaVersion ===
    "licomesh.secure-mesh.trust-ux-report.v2" &&
  clientReleaseAcceptanceConfig.reports?.trust?.producer ===
    "tools/scripts/client-secure-mesh-trust-ux.mjs",
  "client release acceptance config must bind the canonical Trust UX v2 producer");
assert(!trustUx.includes("const reportPath = \"build/reports/secure-mesh-trust-ux.json\""),
  "trust UX must load its report ref from the physical evidence config");
const releaseProofBundle = await files.readSourceBundle(
  "tools/scripts/client-secure-mesh-release-proof-bundle.mjs",
  "tools/scripts/client-secure-mesh-release-proof-bundle",
  ".mjs",
);
const releaseProofConfig = await readText("tools/scripts/config/secure-mesh-release-proof.json");
const releaseProofConfigJson = await readJson("tools/scripts/config/secure-mesh-release-proof.json");
for (const token of [
  "licomesh.secure-mesh.release-proof-config.v1",
  "build/reports/secure-mesh-release-proof-bundle.json",
  "build/reports/client-update-release-channel.json",
  "build/reports/secure-mesh-physical-device-matrix.json",
  "build/reports/android-physical-install-launch.json",
  "build/reports/secure-mesh-physical-evidence-manifest.json",
  "build/reports/secure-mesh-windows-implementation.json",
  "build/reports/secure-mesh-release-input-report-redaction.json",
  "build/reports/licoarc-badtower-acceptance.json",
  "build/reports/secure-mesh-pairwise-content-crypto-audit.json",
  "build/reports/secure-mesh-platform-secret-store-matrix.json",
  "build/reports/secure-mesh-android-platform-crypto-acceptance.json",
  "verifierCommands",
  "freshnessWindows",
  "androidPhysicalInstallLaunchSeconds",
  "sourceChecks",
  "client-update-release-channel",
  "client-secure-mesh-physical-evidence-manifest",
  "client-secure-mesh-report-redaction",
  "tests/verify-client-update-release-channel.mjs",
  "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs",
  "tools/scripts/client-secure-mesh-report-redaction-verify.mjs",
  "--release-proof-inputs",
  "LICO_SECURE_MESH_REDACTION_RUN_ID"
]) {
  assert(releaseProofConfig.includes(token),
    `release proof config must keep input report token ${token}`);
}
assert(Object.keys(releaseProofConfigJson.inputReports || {}).length === 10,
  "release proof config must define every release proof input report");
assert(Object.keys(releaseProofConfigJson.verifierCommands || {}).length === 3,
  "release proof config must define every release proof verifier command");
assert(Array.isArray(releaseProofConfigJson.sourceChecks) &&
  releaseProofConfigJson.sourceChecks.length >= 11,
  "release proof config must define source checks");
const releaseProofConfigHelper = await readText("tools/scripts/lib/secure-mesh-release-proof-config.mjs");
for (const token of [
  "loadSecureMeshReleaseProofConfig",
  "requiredInputReportKeys",
  "requiredVerifierCommandKeys",
  "normalizeSafeReportRef",
  "normalizeVerifierCommands",
  "normalizeVerifierCommand",
  "normalizeVerifierScript",
  "normalizeVerifierArg",
  "normalizeFreshnessWindows",
  "normalizeFreshnessWindowSeconds",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "renderVerifierCommand",
  "assertNoLeak",
  "must not include its own output as an input report",
  "contains unknown input report keys",
  "is missing input report keys",
  "contains unknown verifier command keys",
  "is missing verifier command keys",
  "verifier command ids must be unique",
  "source checks must have unique ids",
  "freshness window keys",
  "report redaction verifier must receive the configured redaction run id env"
]) {
  assert(releaseProofConfigHelper.includes(token),
    `release proof config helper must keep safety token ${token}`);
}
assert(releaseProofBundle.includes("sourceChecks = Object.freeze(releaseProofConfig.sourceChecks)") &&
  !releaseProofBundle.includes("const sourceChecks = Object.freeze(["),
  "release proof bundle must load source checks from config instead of hardcoding inline arrays");
assert(!/const\s+(?:updateReleaseReportPath|physicalMatrixReportPath|reportRedactionReportPath)\s*=/u.test(releaseProofBundle),
  "release proof bundle must load report refs from config instead of hardcoding them");
assert(!releaseProofBundle.includes("report?.ready === true"),
  "release proof bundle must not accept top-level ready as a replacement for releaseEvidenceReady");
for (const token of [
  "const commandArgs = [\"tests/verify-client-update-release-channel.mjs\"]",
  "const commandArgs = [\"tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs\"]",
  "tools/scripts/client-secure-mesh-report-redaction-verify.mjs\",\n    \"--release-proof-inputs\"",
  "command: \"node tests/verify-client-update-release-channel.mjs\"",
  "command: \"node tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs\"",
  "command: \"node tools/scripts/client-secure-mesh-report-redaction-verify.mjs --release-proof-inputs\""
]) {
  assert(!releaseProofBundle.includes(token),
    `release proof bundle must load configured verifier command instead of hardcoding ${token}`);
}
for (const token of [
  "loadSecureMeshReleaseProofConfig",
  "releaseProofConfig",
  "releaseProofConfig.verifierCommands",
  "runConfiguredVerifier",
  "verifierCommand.script",
  "reportRedactionVerifierCommand.runIdEnv",
  "summarizeReleaseInputFreshness",
  "evaluateReportFreshness",
  "releaseInputFreshness.ready === true",
  "verifierCommandCount",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "release proof bundle",
  "releaseInputIntegrity",
  "schema_or_source_mismatch",
  "schemaVersion",
  "evidenceRefSchemaVersion",
  "sourceOfTruth",
  "generatedBy",
  "reportLeakScan",
  "rawMaterialFlags",
  "contractBinding",
  "releaseProofRedactionRunId",
  "redactionRunIdMatched",
  "digestManifestExact",
  "scannedRefDigestsCurrent",
  "summarizeClientLicoArcCryptoInputs",
  "runClientLicoArcCryptoInputsReadinessSelfTest",
  "clientLicoArcCryptoInputs",
  "releaseInputRedactionCoversClientRefs",
  "stationAcceptanceFreshEndpointCount",
  "stationAcceptancePositiveExchange",
  "stationAcceptanceRoundTrip",
  "stationAcceptancePlaintextAbsent",
  "stationAcceptanceNonConformantEnvelopeRejected",
  "stationAcceptanceTransportHintsNonAuthoritative",
  "stationAcceptanceExactFiveOuterFields",
  "stationCandidateBindingsReady",
  "stationCandidateInputsStable",
  "rustCryptoReportReady",
  "rustCryptoNativeTestsReady",
  "rustCryptoVectorCorpusReady",
  "rustCryptoReviewReady",
  "platformCryptoReportReady",
  "androidPlatformCryptoReportReady",
  "completeEvidenceAccepted",
  "invalidFreshEndpointCountRejected",
  "missingPositiveExchangeRejected",
  "missingRoundTripRejected",
  "stationPlaintextPresenceRejected",
  "nonConformantEnvelopeAcceptanceRejected",
  "transportHintAuthorityRejected",
  "invalidOuterFieldContractRejected",
  "staleClientCandidateRejected",
  "tamperedProtocolCandidateRejected",
  "mutatedStationInputRejected",
  "rawRustPlaintextRejected",
  "rawAndroidPrivateMaterialRejected",
  "legacyPlatformCryptoSchemaRejected",
  "physicalMatrixContractReadiness.ready === true",
  "physicalMatrixContractReadinessReady",
  "physicalEvidenceManifestContractReadiness.ready === true",
  "physicalEvidenceManifestContractReadinessReady",
  "runReleaseProofContractReadinessSelfTest",
  "forgedPhysicalMatrixSummaryReadyRejected",
  "forgedPhysicalEvidenceManifestSummaryReadyRejected",
  "androidPhysicalInstallLaunchLocalReadyDiagnosticOnly",
  "bundleDiagnosticOk"
]) {
  assert(releaseProofBundle.includes(token),
    `release proof bundle evidence report must keep contract-bound token ${token}`);
}

}
