export async function checkPhysicalEvidence({ assert, files }) {
  const { readJson, readText } = files;
const physicalDeviceMatrix = await readText("tools/scripts/client-secure-mesh-physical-device-matrix.mjs");
const physicalDeviceMatrixConfig =
  await readText("tools/scripts/config/secure-mesh-physical-device-matrix.json");
const physicalDeviceMatrixConfigJson =
  await readJson("tools/scripts/config/secure-mesh-physical-device-matrix.json");
const physicalDeviceMatrixConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-physical-device-matrix-config.mjs");
for (const token of [
  "loadSecureMeshPhysicalDeviceMatrixConfig",
  "physicalDeviceMatrixConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "physicalEvidenceConfig.reportOutput",
  "reportPath = physicalReportRefs.physicalDeviceMatrix",
  "relayMockCoverage",
  "androidPlatformCryptoCoverage",
  "deriveMatrix",
  "loadSecureClientContract",
  "SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS",
  "SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH",
  "physical device matrix",
  "contractBinding"
]) {
  assert(physicalDeviceMatrix.includes(token) || physicalDeviceMatrixConfig.includes(token),
    `physical device matrix evidence report must keep contract-bound token ${token}`);
}
assert(physicalDeviceMatrix.includes("physicalDeviceMatrixConfig.sourceChecks.map(evaluateSourceCheck)") &&
  physicalDeviceMatrix.includes("physicalDeviceMatrixConfig.physicalMatrix.map((entry)") &&
  !physicalDeviceMatrix.includes("const sourceChecks = Object.freeze([") &&
  !physicalDeviceMatrix.includes("const physicalMatrix = Object.freeze(["),
  "physical device matrix must load source checks and physical scenarios from config instead of hardcoding inline arrays");
assert(physicalDeviceMatrix.includes("validateSecureMeshTrustUxV2Report") &&
  physicalDeviceMatrix.includes("trustContract.contractReady"),
  "physical device matrix must consume the Trust UX v2 contract fail-closed");
for (const token of [
  "licomesh.secure-mesh.physical-device-matrix-config.v2",
  "sourceChecks",
  "physicalMatrix",
  "pairing-and-trust",
  "command-result",
  "file-handoff",
  "relay-protocol",
  "android-platform-crypto-acceptance-is-client-owned-and-redacted",
  "client-relay-mock-exercises-pinned-opaque-protocol",
  "physical-evidence-config-links-current-client-reports",
  "physical-evidence-manifest-consumes-relay-and-platform-crypto"
]) {
  assert(physicalDeviceMatrixConfig.includes(token),
    `physical device matrix config must keep token ${token}`);
}
assert(Array.isArray(physicalDeviceMatrixConfigJson.sourceChecks) &&
  physicalDeviceMatrixConfigJson.sourceChecks.length >= 9 &&
  Array.isArray(physicalDeviceMatrixConfigJson.physicalMatrix) &&
  physicalDeviceMatrixConfigJson.physicalMatrix.length >= 5,
  "physical device matrix config must define source checks and physical scenarios");
const physicalDeviceMatrixSourceCheckIds = new Set(
  physicalDeviceMatrixConfigJson.sourceChecks.map((check) => check.id)
);
for (const id of [
  "android-platform-crypto-acceptance-is-client-owned-and-redacted",
  "ios-client-tests-shared-rust-crypto-lifecycle",
  "client-relay-mock-exercises-pinned-opaque-protocol",
  "physical-evidence-config-links-current-client-reports",
  "physical-device-matrix-consumes-relay-and-platform-crypto"
]) {
  assert(physicalDeviceMatrixSourceCheckIds.has(id),
    `physical device matrix config must keep current client-owned source check ${id}`);
}
for (const token of [
  "loadSecureMeshPhysicalDeviceMatrixConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "normalizePhysicalMatrix",
  "assertNoLeak"
]) {
  assert(physicalDeviceMatrixConfigHelper.includes(token),
    `physical device matrix config helper must keep token ${token}`);
}
assert(!/const\s+(?:reportRefs|linkedReports)\s*=\s*Object\.freeze/u.test(physicalDeviceMatrix),
  "physical device matrix must load linked reports from the v2 physical evidence config");
const physicalEvidenceManifest = await readText("tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs");
const physicalEvidenceConfig = await readText("tools/scripts/config/secure-mesh-physical-evidence.json");
const physicalEvidenceConfigJson = await readJson("tools/scripts/config/secure-mesh-physical-evidence.json");
for (const token of [
  "licomesh.secure-mesh.physical-evidence-config.v2",
  "build/reports/secure-mesh-physical-evidence-manifest.json",
  "build/reports/secure-mesh-android-platform-crypto-acceptance.json",
  "build/reports/secure-client-relay-mock-e2e.json",
  "build/reports/android-physical-install-launch.json",
  "build/client-cli-vm/ubuntu-arm64/mobile-relay-secret-store-self-test.json",
  "build/reports/secure-mesh-release-cli-proof-macos.json",
  "build/reports/secure-mesh-macos-keychain-user-presence-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-release-cli-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-adaptive-custody-proof.json",
  "build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-package-update-proof.json",
  "build/reports/secure-mesh-platform-secret-store-matrix.json",
  "build/reports/secure-mesh-physical-device-matrix.json",
  "build/reports/secure-mesh-encrypted-file-handoff.json",
  "build/reports/secure-mesh-trust-ux.json",
  "build/reports/secure-mesh-windows-implementation.json",
  "build/reports/client-update-release-channel.json",
  "freshnessWindows",
  "androidPlatformCryptoSeconds",
  "evidenceCommands",
  "npm run client:verify:secure-client-relay-mock-e2e",
  "npm run client:test:android:native",
  "npm run client:build:android",
  "node tools/scripts/client-android-physical-install-launch.mjs --install --launch --apk build/apps/desktop/android/release/app-release.apk",
  "npm run client:verify:mobile-simulator-closure:ios",
  "npm run client:verify:secure-mesh-macos-keychain-user-presence",
  "npm run client:verify:secure-mesh-release-cli-proof",
  "npm run client:verify:macos-bundle",
  "npm run client:verify:windows-file-security",
  "npm run client:verify:secure-mesh-windows-implementation",
  "npm run client:cli:vm:verify -- --distro ubuntu",
  "npm run client:cli:vm:linux-product -- --distro ubuntu",
  "npm run client:verify:secure-mesh-linux-adaptive-custody",
  "npm run client:verify:secure-mesh-linux-package-update"
]) {
  assert(physicalEvidenceConfig.includes(token),
    `physical evidence config must keep linked report token ${token}`);
}
assert(Object.keys(physicalEvidenceConfigJson.linkedReports || {}).length === 17,
  "physical evidence config must define every linked physical evidence input report");
assert(Object.keys(physicalEvidenceConfigJson.evidenceCommands || {}).length === 5,
  "physical evidence config must define every platform evidence command list");
assert(Object.keys(physicalEvidenceConfigJson.freshnessWindows || {}).length === 1 &&
  Number.isInteger(physicalEvidenceConfigJson.freshnessWindows.androidPlatformCryptoSeconds),
  "physical evidence config must define the Android platform crypto freshness window");
assert((physicalEvidenceConfigJson.evidenceCommands?.android || []).includes("npm run client:test:android:native") &&
  (physicalEvidenceConfigJson.evidenceCommands?.android || []).includes("npm run client:verify:secure-client-relay-mock-e2e") &&
  (physicalEvidenceConfigJson.evidenceCommands?.android || []).includes("node tools/scripts/client-android-physical-install-launch.mjs --install --launch --apk build/apps/desktop/android/release/app-release.apk") &&
  !(physicalEvidenceConfigJson.evidenceCommands?.android || []).some((command) =>
    command.includes("app-debug.apk")),
  "physical evidence config must expose Android release install/launch and reject debug physical receipts");
assert((physicalEvidenceConfigJson.evidenceCommands?.ios || []).includes("npm run client:verify:mobile-simulator-closure:ios") &&
  (physicalEvidenceConfigJson.evidenceCommands?.ios || []).includes("npm run client:verify:secure-client-relay-mock-e2e"),
  "physical evidence config must expose iOS client simulator and relay Mock commands");
assert((physicalEvidenceConfigJson.evidenceCommands?.macos || []).includes("npm run client:verify:secure-mesh-macos-keychain-user-presence") &&
  (physicalEvidenceConfigJson.evidenceCommands?.linux || []).includes("npm run client:verify:secure-mesh-linux-adaptive-custody") &&
  (physicalEvidenceConfigJson.evidenceCommands?.windows || []).includes("npm run client:verify:secure-mesh-windows-implementation"),
  "physical evidence config must expose platform secret-store and adaptive custody evidence commands");
const physicalEvidenceConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-physical-evidence-config.mjs");
for (const token of [
  "loadSecureMeshPhysicalEvidenceConfig",
  "requiredLinkedReportKeys",
  "requiredEvidenceCommandKeys",
  "normalizeSafeReportRef",
  "normalizeEvidenceCommands",
  "normalizeEvidenceCommand",
  "normalizeFreshnessWindows",
  "normalizeFreshnessWindowSeconds",
  "requiredFreshnessWindowKeys",
  "assertNoLeak",
  "must not link its own output as an input report",
  "contains unknown linked report keys",
  "is missing linked report keys",
  "contains unknown evidence command keys",
  "is missing evidence command keys",
  "evidence command list must not be empty",
  "freshness window keys"
]) {
  assert(physicalEvidenceConfigHelper.includes(token),
    `physical evidence config helper must keep safety token ${token}`);
}
for (const token of [
  "freshnessWindows",
  "linkedReportFreshness",
  "evaluateFreshness",
  "linkedReportFreshnessReady",
  "linkedReportFreshnessStaleOrInvalidCount",
  "androidPlatformCryptoFreshnessReady",
  "relayProtocolMockReady",
  "androidPlatformCryptoAcceptanceReady",
  "mlsMemberRemoveReleaseActionReady",
  "relayMockCoverage",
  "androidPlatformCryptoCoverage",
  "client-owned relay Mock protocol acceptance"
]) {
  assert(physicalEvidenceManifest.includes(token),
    `physical evidence manifest must keep linked-report freshness token ${token}`);
}

}
