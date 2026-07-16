export async function checkSecretStore({ assert, files }) {
  const { readJson, readSourceBundle, readText } = files;
const platformSecretStoreMatrix = await readSourceBundle(
  "tools/scripts/client-secure-mesh-platform-secret-store-matrix.mjs",
  "tools/scripts/client-secure-mesh-platform-secret-store-matrix",
  ".mjs",
);
const platformSecretStoreMatrixConfig =
  await readText("tools/scripts/config/secure-mesh-platform-secret-store-matrix.json");
const platformSecretStoreMatrixConfigJson =
  await readJson("tools/scripts/config/secure-mesh-platform-secret-store-matrix.json");
const platformSecretStoreMatrixConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-platform-secret-store-matrix-config.mjs");
const secureMeshSecretStoreRustSource =
  await readSourceBundle(
    "crates/lico-client-native/src/platform/secure_mesh_secret_store.rs",
    "crates/lico-client-native/src/platform/secure_mesh_secret_store",
    ".rs",
  );
const secureMeshSecretStoreCoreRustSource =
  await readSourceBundle(
    "crates/lico-client-native/src/core/secure_mesh_secret_store.rs",
    "crates/lico-client-native/src/core/secure_mesh_secret_store",
    ".rs",
  );
const mobileRelayPairwiseRustSource =
  await readSourceBundle(
    "crates/lico-client-native/src/domain/mobile_relay.rs",
    "crates/lico-client-native/src/domain/mobile_relay",
    ".rs",
  );
const mobileRelaySecretCustodyRustSource =
  await readSourceBundle(
    "crates/lico-client-native/src/domain/mobile_relay/secret_custody.rs",
    "crates/lico-client-native/src/domain/mobile_relay/secret_custody",
    ".rs",
  );
for (const token of [
  "loadSecureMeshPlatformSecretStoreMatrixConfig",
  "platformSecretStoreMatrixConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "reportPath = physicalReportRefs.platformSecretStore",
  "androidPlatformCryptoCoverage",
  "androidInstallLaunchCoverage",
  "macosPlatformCryptoCoverage",
  "ubuntuPlatformCryptoCoverage",
  "rustCryptographyAcceptanceReady",
  "hostClientCryptographyAcceptance",
  "loadSecureClientContract",
  "contractBinding"
]) {
  assert(platformSecretStoreMatrix.includes(token) || platformSecretStoreMatrixConfig.includes(token),
    `platform secret-store matrix must keep current client cryptography token ${token}`);
}
assert(platformSecretStoreMatrix.includes("platformSecretStoreMatrixConfig.sourceChecks.map(evaluateSourceCheck)") &&
  platformSecretStoreMatrix.includes("platformSecretStoreMatrixConfig.nativeTestFilters.map(runNativeTest)") &&
  !platformSecretStoreMatrix.includes("const sourceChecks = Object.freeze([") &&
  !platformSecretStoreMatrix.includes("const nativeTestFilters = Object.freeze(["),
  "platform secret-store matrix must load source checks and native filters from config instead of hardcoding inline arrays");
for (const token of [
  "licolite.secure-mesh.platform-secret-store-matrix-config.v2",
  "sourceChecks",
  "nativeTestFilters",
  "android-platform-crypto-report-is-current",
  "android-keystore-policy-is-platform-native",
  "android-authenticator-uses-system-biometric-or-device-credential",
  "ios-callback-abi-keychain-handle-and-raw-json-ban-exists",
  "ios-bridge-rust-secret-store-callback-wiring-exists",
  "ios-secret-store-callback-uses-single-system-authorization-context",
  "ios-local-auth-user-presence-proof-exists",
  "macos-keychain-proof-is-client-owned-and-redacted",
  "platform-matrix-consumes-current-client-cryptography-reports",
  "physicalReportRefs.androidPlatformCrypto",
  "hostClientCryptographyAcceptance"
]) {
  assert(platformSecretStoreMatrixConfig.includes(token),
    `platform secret-store matrix config must keep token ${token}`);
}
assert(Array.isArray(platformSecretStoreMatrixConfigJson.sourceChecks) &&
  platformSecretStoreMatrixConfigJson.sourceChecks.length >= 13 &&
  Array.isArray(platformSecretStoreMatrixConfigJson.nativeTestFilters) &&
  platformSecretStoreMatrixConfigJson.nativeTestFilters.length >= 10,
  "platform secret-store matrix config must define source checks and native test filters");
for (const token of [
  "objc2_local_authentication::{LAContext, LAPolicy}",
  "MacosAuthorizationContext",
  "setInteractionNotAllowed",
  "context.setInteractionNotAllowed(!request.allow_interaction())",
  "evaluatePolicy_localizedReason_reply",
  "block2::RcBlock::new",
  "system_authorization_attempt_count",
  "system_authorization_completed",
  "canEvaluatePolicy_error(LAPolicy::DeviceOwnerAuthentication)",
  "if request.allow_interaction() {",
  "secure mesh macOS user-presence authorization is unavailable",
  "with_capability_report",
  "SecurityCapability::AppleKeychain",
  "SecurityCapability::DataProtectionKeychain",
  "SecurityCapability::OsUserPresence",
  "SecurityCapability::DeviceCredential",
  "kSecUseDataProtectionKeychain",
	  "kSecUseAuthenticationContext",
	  "SecAccessControl::create_with_protection",
	  "ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly",
	  "kSecAccessControlUserPresence",
  "single_system_authorization_context_verified",
  "secure mesh native secret store read failed for",
  "pub(super) fn set_secret_with_session",
  "pub(super) fn get_secret_with_session",
  "pub(super) fn delete_secret_with_session",
  "if session.shared_system_context_required() {",
  "macos_user_presence::set_secret",
  "macos_user_presence::get_secret",
  "macos_user_presence::delete_secret"
]) {
  assert(secureMeshSecretStoreRustSource.includes(token),
    `Rust macOS platform secret store must preserve system LocalAuthentication token ${token}`);
}
for (const token of [
  "SecretStoreAuthorizationSession",
  "record_secret_store_operation",
  "consumed_operation_count",
  "authorization_batch_within_budget",
  "app_password_prompt_used: false"
]) {
  assert(secureMeshSecretStoreCoreRustSource.includes(token),
    `Rust secret-store core must preserve authorization-session contract token ${token}`);
}
for (const token of [
  "RuntimeSecretContext",
  "MobileRelaySecretStoreAuthBatch",
  "shared_authorization_session",
  "if self.session.is_none()",
  "self.session = Some(store.begin_authorized_session",
  "authorizationBatchPromptBudgetReady",
  "authorization_batch_operation_count",
  "authorization_batch_consumed_operation_count",
  "authorization_batch_remaining_operation_count",
  "\"operationCount\"",
  "\"consumedOperationCount\"",
  "\"remainingOperationCount\"",
  "authorizationBatchWithinBudget",
  "system_authorization_attempt_count == 1",
  "system_authorization_completed",
  "!app_password_prompt_used",
  "!app_credential_prompt_used"
]) {
  assert(mobileRelaySecretCustodyRustSource.includes(token),
    `Mobile Relay secret custody must reuse one system authorization batch token ${token}`);
}
for (const token of [
  "mobile_relay_pairwise_operation_with_runtime_secret_context",
  "e2ee_status_requires_single_system_authorization_prompt_budget"
]) {
  assert(mobileRelayPairwiseRustSource.includes(token),
    `Mobile Relay pairwise runtime must reuse the shared secret-store authorization token ${token}`);
}
for (const token of [
  "loadSecureMeshPlatformSecretStoreMatrixConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "normalizeNativeTestFilters",
  "assertNoLeak",
  "source checks must have unique ids",
  "native test filters must be unique"
]) {
  assert(platformSecretStoreMatrixConfigHelper.includes(token),
    `platform secret-store matrix config helper must keep safety token ${token}`);
}
for (const token of [
  "capabilityReport",
  "enabledCapabilities",
  "custodyStrategy",
  "exactCapabilitySetValid",
  "safeOsStoreAvailable",
  "standardKeychainAvailable",
  "dataProtectionKeychainAvailable",
  "userPresenceOperationSupported",
  "secureEnclaveOperationSupported",
  "singleSystemAuthorizationContextVerified",
  "macosAdaptiveCustodyReady",
  "macosEnabledCapabilities",
  "macosPromptBudgetSatisfied",
  "macosZeroBackgroundPrompts",
  "macosAppPasswordPromptUsed"
]) {
  assert(platformSecretStoreMatrix.includes(token),
    `platform secret-store matrix must keep macOS adaptive capability token ${token}`);
}
for (const token of [
  "const reportPath = \"build/reports/secure-mesh-platform-secret-store-matrix.json\"",
  "const windowsImplementationReportPath = \"build/reports/secure-mesh-windows-implementation.json\"",
  "\"build/client-cli-vm/ubuntu-arm64/mobile-relay-secret-store-self-test.json\"",
  "\"build/reports/secure-mesh-release-cli-proof-macos.json\"",
  "\"build/reports/secure-mesh-macos-keychain-user-presence-proof.json\"",
  "\"build/client-cli-vm/ubuntu-arm64/secure-mesh-release-cli-proof.json\"",
  "\"build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-adaptive-custody-proof.json\"",
  "\"build/client-cli-vm/ubuntu-arm64/secure-mesh-linux-package-update-proof.json\"",
  "evidenceCommands: [\"npm run client:verify:architecture\"]",
  "\"npm run client:cli:vm:verify -- --distro ubuntu\""
]) {
  assert(!platformSecretStoreMatrix.includes(token),
    `platform secret-store matrix must load configured evidence ref instead of hardcoding ${token}`);
}

}
