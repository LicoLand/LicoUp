export async function checkAndroidIos({ assert, files }) {
  const { readSourceBundle, readText } = files;
const androidInstallLaunchVerifier = await readSourceBundle(
  "tools/scripts/client-android-physical-install-launch.mjs",
  "tools/scripts/client-android-physical-install-launch",
  ".mjs",
);
const androidMainActivity =
  await readText("apps/desktop/android/app/src/main/kotlin/com/liko/arc/MainActivity.kt");
const androidSecureMeshUserAuthenticator =
  await readText("apps/desktop/android/app/src/main/kotlin/com/liko/arc/SecureMeshAndroidUserAuthenticator.kt");
const androidProductionSources = await readSourceBundle(
  "apps/desktop/android/app/src/main/kotlin/com/liko/arc/MainActivity.kt",
  "apps/desktop/android/app/src/main/kotlin/com/liko/arc",
  ".kt",
);
const androidAuthBoundarySources = androidProductionSources;
const iosSecureMeshBridge =
  await readText("apps/desktop/ios/Runner/SecureMeshIosBridge.swift");
const iosSecureMeshSecretStore =
  await readText("apps/desktop/ios/Runner/SecureMeshIosBridge+SecretStore.swift");
for (const token of [
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "physicalEvidenceConfig.linkedReports.androidInstallLaunch",
  "export const reportPath"
]) {
  assert(androidInstallLaunchVerifier.includes(token),
    `Android install/launch verifier must derive its report ref from config token ${token}`);
}
for (const token of [
  "SecureMeshAndroidUserAuthenticator(this)",
  "SecureMeshAndroidCommandRouter(",
  "authenticator.request(params)",
  "authenticator.status()",
  "authenticator.onActivityResult(requestCode, resultCode)",
  "nativeRuntime.invoke(",
  "secretStore.invokeWithAuthorizedCustody {"
]) {
  assert(androidProductionSources.includes(token),
    `Android bridge source bundle must delegate Secure Mesh platform work through separated modules token ${token}`);
}

for (const token of [
  "class SecureMeshAndroidUserAuthenticator",
  "KeyguardManager",
  "createConfirmDeviceCredentialIntent",
  "startActivityForResult(prompt, REQUEST_CODE)",
  "systemCredentialPromptAvailable",
  "systemCredentialPromptStarted",
  "systemCredentialPromptCompleted",
  "systemCredentialPromptResultCodePresent",
  "systemCredentialPromptResultCode",
  "systemCredentialPromptResult",
  "systemCredentialPromptReusedFromPendingRequest",
  "pendingLatch",
  "userActionRequired",
	  "credentialEntrySurface",
	  "android_system_credential_prompt",
	  "systemCredentialPromptReusedFromPendingRequest",
	  "appCredentialPromptUsed",
		  "appPasswordPromptUsed",
		  "physicalUserPresenceRequired",
		  "systemAuthenticationOnly",
		  "appLockScreenCredentialCollection",
		  ".put(\"systemAuthenticationOnly\", true)",
		  ".put(\"appLockScreenCredentialCollection\", false)",
		  ".put(\"appCredentialPromptUsed\", false)",
		  ".put(\"appPasswordPromptUsed\", false)",
	  "keyMaterialHandledByAuthenticationFlow",
  "bodyRedacted"
]) {
  assert(androidSecureMeshUserAuthenticator.includes(token),
    `Android Secure Mesh authentication must use a dedicated system credential module token ${token}`);
}
for (const forbidden of [
  "lockScreenPassword",
  "screenPassword",
	  "devicePasswordInput",
	  "EditText",
	  "TextInputEditText",
	  "TextField",
	  "OutlinedTextField",
	  "BasicTextField",
		  "PasswordTransformationMethod",
		  "PasswordVisualTransformation",
		  "KeyboardType.Password",
		  "TYPE_TEXT_VARIATION_PASSWORD",
		  "TYPE_NUMBER_VARIATION_PASSWORD",
		  "numberPassword",
		  "textPassword",
		  "lockScreenPin",
		  "devicePin",
		  "pinCode",
		  "setInputType",
		  "inputType",
		  ".put(\"appCredentialPromptUsed\", true)",
		  ".put(\"appPasswordPromptUsed\", true)",
		  ".put(\"appLockScreenCredentialCollection\", true)",
		  "\"appCredentialPromptUsed\" to true",
		  "\"appPasswordPromptUsed\" to true",
		  "\"appLockScreenCredentialCollection\" to true",
		  "appCredentialPromptUsed = true",
		  "appPasswordPromptUsed = true",
		  "appLockScreenCredentialCollection = true"
]) {
  assert(!androidAuthBoundarySources.includes(forbidden),
    `Android Secure Mesh authentication must not collect lock-screen credentials in app via ${forbidden}`);
}
for (const token of [
  "class SecureMeshAndroidSecretStore",
  "secureMeshAndroidSecretStoreSet",
  "secureMeshAndroidSecretStoreGet",
  "secureMeshAndroidSecretStoreDelete",
  "requireMobileRelaySelection",
  "SecureMeshAndroidKeyPolicyStrategy.candidates",
  "SecureMeshAndroidCustodySelection.MemoryOnly",
  "secureMeshAndroidCapabilityProbeJson",
  "setUserAuthenticationRequired(true)",
  "setUserAuthenticationParameters",
  "AUTH_DEVICE_CREDENTIAL",
  "AUTH_BIOMETRIC_STRONG",
  "SecureMeshAndroidSecretContract.MOBILE_RELAY_KEY_ALIAS",
  "android-mobile-relay-secrets",
  "mobileRelaySecretStore",
  "rawJsonSecretOverridesUsed"
]) {
  assert(androidProductionSources.includes(token),
    `Android Secure Mesh secret-store source bundle must preserve token ${token}`);
}
for (const forbiddenToken of [
  "overrides.put(\"pcToken\"",
  "overrides.put(\"mobileToken\"",
  "overrides.put(\"pairedDevices\""
]) {
  assert(!androidProductionSources.includes(forbiddenToken),
    `Android Secure Mesh secret-store overrides must use opaque handles instead of raw token JSON via ${forbiddenToken}`);
}
for (const forbiddenToken of [
  "overrides[\"pcToken\"]",
  "overrides[\"mobileToken\"]",
  "overrides[\"pairedDevices\"]"
]) {
  assert(!iosSecureMeshSecretStore.includes(forbiddenToken),
    `iOS Secure Mesh secret-store overrides must use opaque handles instead of raw token JSON via ${forbiddenToken}`);
}

for (const token of [
  "androidKeyStoreStatus",
  "atomicRecordWriter.write",
  "SecureMeshAndroidSecretContract.MOBILE_RELAY_KEY_ALIAS",
  "private val AAD_MAGIC",
  "private val PLAINTEXT_MAGIC",
  "KeyGenerator.getInstance",
  "Cipher.getInstance(SecureMeshAndroidSecretContract.CIPHER)",
  "setUserAuthenticationRequired(true)",
  "AUTH_DEVICE_CREDENTIAL",
  "AUTH_BIOMETRIC_STRONG",
  "persistentCustodySelected",
  "capabilityProbe",
  "restartSemantics"
]) {
  assert(androidProductionSources.includes(token),
    `Android Secure Mesh KeyStore source bundle must preserve token ${token}`);
}
for (const forbiddenToken of [
  "fun secureMeshAndroidSecretStoreSet",
  "fun secureMeshAndroidSecretStoreGet",
  "fun secureMeshAndroidSecretStoreDelete",
  "fun ensureAndroidMobileRelaySecretStoreKey",
  "ANDROID_MOBILE_RELAY_SECRET_STORE_KEY_ALIAS",
  "ANDROID_MOBILE_RELAY_SECRET_KIND",
  "android-mobile-relay-secrets",
  "filesDir.absolutePath\n        )"
]) {
  assert(!androidMainActivity.includes(forbiddenToken),
    `MainActivity must delegate Mobile Relay secret-store backend instead of defining ${forbiddenToken}`);
}

for (const forbiddenToken of [
  "fun androidKeyStoreStatus",
  "fun ensureAndroidSecureStoreKey",
  "fun androidSecretKeyRequiresUserAuthentication",
  "fun androidEndpointSigningKeyRequiresUserAuthentication",
  "fun applyAndroidUserAuthenticationPolicy",
  "fun androidDeviceCredentialIsConfigured",
  "fun ensureAndroidEndpointSigningKey",
  "fun androidEndpointSigningEntry",
  "fun signAndroidEndpointChallenge",
  "fun writeAndroidSecureStoreProof",
  "fun writeAndroidSecureStoreRecord",
  "fun writeAndroidSecureStoreRecordToFile",
  "fun readAndroidSecureStoreProbeRecord",
  "fun readAndroidSecureStoreRecordFromFile",
  "buildAndroidSecureStoreAad",
  "encodeAndroidSecureStorePlaintext",
  "decodeAndroidSecureStorePlaintext",
  "ANDROID_ENDPOINT_SIGNING_KEY_ALIAS",
  "ANDROID_SECURE_STORE_KEY_ALIAS",
  "ANDROID_SECURE_STORE_AAD_MAGIC",
  "ANDROID_SECURE_STORE_PLAINTEXT_MAGIC",
  "KeyPairGenerator.getInstance",
  "KeyGenerator.getInstance",
  "Cipher.getInstance(ANDROID_SECURE_STORE_CIPHER)",
  "Signature.getInstance(ANDROID_ENDPOINT_SIGNING_ALGORITHM)"
]) {
  assert(!androidMainActivity.includes(forbiddenToken),
    `MainActivity must delegate Android KeyStore implementation details to SecureMeshAndroidSecretStore.kt instead of defining ${forbiddenToken}`);
}
for (const token of [
  "ANDROID_AUTHENTICATED_PAIRWISE_RUNTIME_STATUS",
  "authenticatedPairwiseV2RuntimeReady",
  "runtimeStatusRedacted",
  "rawPayloadExportSurfaceAbsent",
  "objectContainsAnyKeyOrValue",
  "validateAndroidCapabilityProbe",
  "validateAndroidCapabilityMeasurements",
  "summarizeAndroidCapabilityStore",
  "androidCustodyReady",
  "adaptiveAuthorizationReady"
]) {
  assert(androidInstallLaunchVerifier.includes(token),
    `Android install/launch evidence must preserve redacted pairwise v2 runtime token ${token}`);
}
for (const token of [
  "classifyAndroidAdbPhysicalDevice",
  "classifyAndroidGetpropPhysicalDevice",
  "androidPhysicalDeviceProof",
  "androidAdbTransportAuthorized",
  "androidPhysicalDeviceProofReady",
  "androidDeviceClass",
  "androidGetpropProbeReady",
  "androidEmulatorSignalCategories",
  "androidPhysicalSignalCategories",
  "androidGetpropMissingFields",
  "androidGetpropAmbiguousFields",
  "rawGetpropIncluded",
  "rawDeviceIdentifiersIncluded",
  "ro.kernel.qemu",
  "ro.boot.qemu",
  "ro.build.characteristics",
  "ro.hardware",
  "ro.boot.hardware",
  "ro.product.model",
  "ro.build.fingerprint",
  "androidPhysicalDeviceProofMissingFields",
  "androidPhysicalDeviceProofWeakProofFields"
]) {
  assert(androidInstallLaunchVerifier.includes(token),
    `Android install/launch verifier must preserve non-emulator device proof token ${token}`);
}
for (const token of [
  "mobileRelaySecretStoreContractReady",
  "androidCustodyReady",
  "adaptiveAuthorizationReady",
  "rawJsonSecretOverridesUsedPresent",
  "rawJsonSecretOverridesUnknown",
  "applicationAuthorizationGrantRequired",
  "custodyStrategy",
  "restartSemantics",
  "enabledCapabilities"
]) {
  assert(androidInstallLaunchVerifier.includes(token),
    `Android install/launch verifier must preserve Mobile Relay secret-store schema token ${token}`);
}
for (const forbiddenToken of [
  "lockScreenPassword",
  "screenLockPassword",
  "devicePassword",
  "deviceCredentialPassword",
	  "devicePasswordInput",
	  "userEnteredPassword",
	  "appLockPassword",
	  "EditText",
	  "TextInputEditText",
	  "TextField",
	  "OutlinedTextField",
	  "BasicTextField",
		  "PasswordTransformationMethod",
		  "PasswordVisualTransformation",
		  "KeyboardType.Password",
		  "TYPE_TEXT_VARIATION_PASSWORD",
		  "TYPE_NUMBER_VARIATION_PASSWORD",
		  "numberPassword",
		  "textPassword",
		  "lockScreenPin",
		  "devicePin",
		  "pinCode",
		  "setInputType",
		  "inputType",
	  ".put(\"appCredentialPromptUsed\", true)",
	  ".put(\"appPasswordPromptUsed\", true)",
	  "\"appCredentialPromptUsed\" to true",
	  "\"appPasswordPromptUsed\" to true",
	  "appCredentialPromptUsed = true",
	  "appPasswordPromptUsed = true"
	]) {
  assert(!androidAuthBoundarySources.includes(forbiddenToken),
    `Android Secure Mesh authentication must not collect lock-screen credentials in-app via ${forbiddenToken}`);
}
for (const token of [
  "iosCallbackAuthContextAttachedToAllOperations",
  "sharedSystemAuthorizationContextRequired",
  "sharedSystemAuthorizationContextAvailable",
  "systemAuthorizationAttemptCount",
  "systemAuthorizationCompleted",
  "authorizationBatchPromptBudgetReady",
  "authorizationBatchOperationCount",
  "authorizationBatchConsumedOperationCount",
  "authorizationBatchRemainingOperationCount",
  "authorizationBatchWithinBudget",
  "allowableReuseDurationSeconds",
  "authenticationReuseWindowConfigured"
]) {
  assert(iosSecureMeshBridge.includes(token),
    `iOS Secure Mesh bridge must preserve single system authorization batch token ${token}`);
}

}
