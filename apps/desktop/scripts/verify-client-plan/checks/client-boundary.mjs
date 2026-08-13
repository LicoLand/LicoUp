export async function checkClientBoundary({ assert, files }) {
  const { readJson, readText } = files;
const clientBoundaryVerifier = await readText("tools/verify-client-boundary.mjs");
const clientBoundaryConfig = await readText("tools/scripts/config/secure-mesh-client-boundary.json");
const clientBoundaryConfigJson = await readJson("tools/scripts/config/secure-mesh-client-boundary.json");
const clientBoundaryConfigHelper = await readText("tools/scripts/lib/secure-mesh-client-boundary-config.mjs");
for (const token of [
  "loadSecureMeshClientBoundaryConfig",
  "enforceConfiguredClientBoundary",
  "clientBoundarySummary",
  "clientBoundary: clientBoundarySummary",
  "ruleAllowsToken",
  "sourceChecks"
]) {
  assert(clientBoundaryVerifier.includes(token),
    `client boundary verifier must keep config-driven boundary token ${token}`);
}
assert(clientBoundaryVerifier.includes("await enforceConfiguredClientBoundary(await loadSecureMeshClientBoundaryConfig())"),
  "client boundary verifier must load and enforce the client boundary config");
for (const token of [
  "licomesh.secure-mesh.client-boundary-config.v1",
  "flutter-gui-no-secure-mesh-backend-implementation",
  "dart-services-are-bridges-not-protocol-implementations",
  "dart-method-channel-confined-to-platform-bridge",
  "rust-native-core-has-no-flutter-ui-dependency",
  "android-activity-does-not-own-payload-crypto",
  "android-platform-auth-does-not-collect-lock-screen-password",
  "android-mobile-relay-bridge-does-not-send-raw-e2ee-json",
  "ios-mobile-relay-bridge-does-not-send-raw-e2ee-json",
	  "rust-core-owns-secure-mesh-payload-crypto",
	  "rust-core-owns-secure-mesh-pairwise-state",
	  "handshake_transcript_hash",
	  "initiator_key_confirmed",
	  "pairwise_key_confirmation",
	  "rust-mobile-ffi-forbids-raw-payload-crypto-actions",
  "android-forbids-raw-payload-ffi-actions",
  "android-bridge-uses-system-device-auth",
  "android-bridge-uses-opaque-mobile-relay-secret-store-handle",
  "macos-rust-user-presence-uses-one-biometric-first-application-authorization",
  "macos-rust-secret-store-authorization-session-is-single-context",
  "macos-user-presence-proof-uses-single-system-auth-context",
  "APPLICATION_AUTHORIZATION",
  "LAPolicy::DeviceOwnerAuthenticationWithBiometrics",
  "password_fallback_allowed",
  "setLocalizedFallbackTitle",
  "MacosAuthorizationContext",
  "kSecUseAuthenticationContext",
  "SecretStoreAuthorizationSession",
  "begin_authorized_session",
  "set_secret_with_session",
  "ios-bridge-uses-keychain-and-local-auth",
  "ios-bridge-uses-single-system-auth-context"
]) {
  assert(clientBoundaryConfig.includes(token),
    `client boundary config must preserve frontend/backend split token ${token}`);
}
assert(Array.isArray(clientBoundaryConfigJson.rules) &&
  clientBoundaryConfigJson.rules.length >= 6 &&
  Array.isArray(clientBoundaryConfigJson.sourceChecks) &&
  clientBoundaryConfigJson.sourceChecks.length >= 11,
  "client boundary config must define scan rules and source checks");
for (const token of [
  "loadSecureMeshClientBoundaryConfig",
  "normalizeSafeRootRef",
  "normalizeSafeSourceRef",
	  "normalizeRules",
	  "normalizeAllowedMatches",
	  "normalizeSourceChecks",
	  "normalizeOptionalTokenList",
	  "const forbiddenTokens = normalizeOptionalTokenList",
	  "must define tokens or forbidden tokens",
	  "assertNoLeak",
  "rules must have unique ids",
  "source checks must have unique ids"
]) {
  assert(clientBoundaryConfigHelper.includes(token),
    `client boundary config helper must keep safety token ${token}`);
}


}
