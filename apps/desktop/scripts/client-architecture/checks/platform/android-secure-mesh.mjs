export async function checkAndroidSecureMesh(context) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  const secureMeshAndroidBridgeSource = await readJoinedText([
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/MainActivity.kt",
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidBridgeContract.kt",
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidNativeRuntime.kt",
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidCommandRouter.kt",
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidJsonCodec.kt",
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidRuntimeStatusStore.kt"
  ]);
  const secureMeshAndroidDebugAcceptanceSource = await readJoinedText([
    "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/DebugMainActivity.kt",
    "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/ReleaseAcceptanceChannel.kt",
    "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/ReleaseAcceptanceDebugCodec.kt",
    "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/ReleaseAcceptanceDebugContract.kt",
    "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/ReleaseAcceptanceIngress.kt",
    "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/SecureMeshAndroidReleaseAcceptanceCoordinator.kt"
  ]);
  const secureMeshAndroidSecretStoreSource = await readJoinedText([
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidSecretStore.kt",
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidSecretContract.kt",
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidCustodyManager.kt",
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidEncryptedRecordStore.kt",
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidMobileRelaySecretBridge.kt"
  ]);
  const secureMeshAndroidCapabilitySource =
    await readText("apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidCapability.kt");
  const secureMeshAndroidCapabilityProbeSource =
    await readText("apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidCapabilityProbe.kt");
  const secureMeshAndroidKeyPolicySource =
    await readText("apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidKeyPolicy.kt");
  const secureMeshAndroidAdaptiveCustodyTestSource =
    await readText("apps/desktop/android/app/src/test/kotlin/land/lico/licoup/SecureMeshAndroidAdaptiveCustodyTest.kt");
  const secureMeshAndroidUserAuthenticatorSource =
    await readText("apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidUserAuthenticator.kt");
  const secureMeshAndroidAuthorizationPolicyTestSource =
    await readText("apps/desktop/android/app/src/test/kotlin/land/lico/licoup/SecureMeshAndroidAuthorizationPolicyTest.kt");
  const secureMeshAndroidBridgeBoundaryTestSource =
    await readText("apps/desktop/android/app/src/test/kotlin/land/lico/licoup/SecureMeshAndroidBridgeBoundaryTest.kt");
  const secureMeshAndroidSecretStoreBoundaryTestSource =
    await readText("apps/desktop/android/app/src/test/kotlin/land/lico/licoup/SecureMeshAndroidSecretStoreBoundaryTest.kt");
  const secureMeshAndroidManifestSource =
    await readText("apps/desktop/android/app/src/main/AndroidManifest.xml");
  const secureMeshAndroidDebugManifestSource =
    await readText("apps/desktop/android/app/src/debug/AndroidManifest.xml");
  const secureMeshAndroidBuildSource =
    await readText("apps/desktop/android/app/build.gradle.kts");
  const secureMeshAndroidBackupRulesSource = await readJoinedText([
    "apps/desktop/android/app/src/main/res/xml/backup_rules.xml",
    "apps/desktop/android/app/src/main/res/xml/backup_rules_legacy.xml"
  ]);
  const secureMeshAndroidAuthBoundarySource = [
    secureMeshAndroidBridgeSource,
    secureMeshAndroidSecretStoreSource,
    secureMeshAndroidUserAuthenticatorSource
  ].join("\n");
  assert(secureMeshAndroidBridgeSource.includes("SecureMeshAndroidSecretStore(this, filesDir)") &&
    secureMeshAndroidBridgeSource.includes("SecureMeshAndroidUserAuthenticator(this)") &&
    secureMeshAndroidBridgeSource.includes("private fun authorizeAction") &&
    secureMeshAndroidBridgeSource.includes('request.optBoolean("authorize", false)') &&
    secureMeshAndroidBridgeSource.includes("interactionAuthorized = allowPrompt") &&
    secureMeshAndroidBridgeSource.includes("authorizeSensitiveAction(") &&
    secureMeshAndroidBridgeSource.includes("hasActiveAuthorizationGrant()") &&
    secureMeshAndroidBridgeSource.includes("NATIVE_EXPECTED_FEATURE_FLAGS = 255") &&
    secureMeshAndroidBridgeSource.includes("product_policy_bindings_implemented_product_messaging_disabled_until_physical_group_evidence") &&
    secureMeshAndroidBridgeSource.includes('"mlsRuntimeReady" to false') &&
    secureMeshAndroidBridgeSource.includes('"unexpectedDiagnosticFeatureFlagsPresent" to') &&
    secureMeshAndroidBridgeSource.includes('"mlsRuntimeFeatureEnabled" to true') &&
    secureMeshAndroidBridgeSource.includes("diagnosticFileNames") &&
    !secureMeshAndroidBridgeSource.includes(".walkTopDown()") &&
    secureMeshAndroidBridgeSource.includes("authenticator.request(params)") &&
    secureMeshAndroidBridgeSource.includes("authenticator.status()") &&
    secureMeshAndroidBridgeSource.includes("authenticator.onActivityResult(requestCode, resultCode)") &&
    secureMeshAndroidBridgeSource.includes("secretStoreBridge: SecureMeshAndroidSecretStore") &&
    secureMeshAndroidBridgeSource.includes("val response = try {") &&
    secureMeshAndroidBridgeSource.includes("secretStore.invokeWithAuthorizedCustody") &&
    secureMeshAndroidBridgeSource.includes("filesDir.absolutePath") &&
    secureMeshAndroidBridgeSource.includes("authenticator.consumeAuthorizationGrant()") &&
    !secureMeshAndroidBridgeSource.includes("requestTextWithMobileRelaySecretOverrides") &&
    !secureMeshAndroidBridgeSource.includes("captureMobileRelaySecretsFromNativeResponse") &&
    !secureMeshAndroidBridgeSource.includes("fun secureMeshAndroidSecretStoreSet") &&
    !secureMeshAndroidBridgeSource.includes("ANDROID_MOBILE_RELAY_SECRET_STORE_KEY_ALIAS") &&
    secureMeshAndroidSecretStoreSource.includes("class SecureMeshAndroidSecretStore") &&
    secureMeshAndroidSecretStoreSource.includes("MOBILE_RELAY_STORE_CONTRACT") &&
    secureMeshAndroidSecretStoreSource.includes('"rawJsonSecretOverridesUsed" to false') &&
    secureMeshAndroidSecretStoreSource.includes('"jniCallbacksCarryDecryptedSecretBytesInProcess" to true') &&
    secureMeshAndroidSecretStoreSource.includes('"statusProbeSideEffectFree" to true') &&
    !secureMeshAndroidSecretStoreSource.includes('overrides.put("mobileRelayE2ee"') &&
    !secureMeshAndroidSecretStoreSource.includes('overrides.put("pcToken"') &&
    !secureMeshAndroidSecretStoreSource.includes('overrides.put("mobileToken"') &&
    !secureMeshAndroidSecretStoreSource.includes('overrides.put("pairedDevices"') &&
    secureMeshAndroidSecretStoreSource.includes("android-mobile-relay-secrets") &&
    secureMeshAndroidSecretStoreSource.includes("mobileRelaySecretStoreStatus") &&
    secureMeshAndroidSecretStoreSource.includes('"signingKeyBase64url"') &&
    secureMeshAndroidSecretStoreSource.includes('"signedPrekeyPrivateKeyBase64url"') &&
    secureMeshAndroidSecretStoreSource.includes('"oneTimePrekeyPrivateKeyBase64url"') &&
    secureMeshAndroidSecretStoreSource.includes("setUserAuthenticationRequired(true)") &&
    secureMeshAndroidSecretStoreSource.includes("setUserAuthenticationParameters") &&
    secureMeshAndroidSecretStoreSource.includes("AUTH_DEVICE_CREDENTIAL") &&
    secureMeshAndroidSecretStoreSource.includes("AUTH_BIOMETRIC_STRONG") &&
    secureMeshAndroidSecretStoreSource.includes("authorizationGrantIsActive") &&
    secureMeshAndroidSecretStoreSource.includes("requireAuthorization") &&
    secureMeshAndroidSecretStoreSource.includes("prepareMobileRelaySelection") &&
    secureMeshAndroidSecretStoreSource.includes("requireMobileRelaySelection") &&
    secureMeshAndroidSecretStoreSource.includes("SecureMeshAndroidCustodySelection.MemoryOnly") &&
    secureMeshAndroidSecretStoreSource.includes("secureMeshAndroidCapabilityProbeJson") &&
    secureMeshAndroidCapabilitySource.includes("SecureMeshAndroidCapabilityMeasurement") &&
    secureMeshAndroidCapabilitySource.includes('"custody.os_secure_store"') &&
    secureMeshAndroidCapabilitySource.includes('"custody.strongbox"') &&
    secureMeshAndroidCapabilitySource.includes("re_pair_rekey_after_restart") &&
    secureMeshAndroidCapabilityProbeSource.includes("class SecureMeshAndroidCapabilityProbe") &&
    secureMeshAndroidCapabilityProbeSource.includes("SECURITY_LEVEL_UNKNOWN_SECURE") &&
    secureMeshAndroidKeyPolicySource.includes("SecureMeshAndroidKeyPolicyStrategy") &&
    secureMeshAndroidKeyPolicySource.includes("STRONGBOX_UNAVAILABLE") &&
    secureMeshAndroidAdaptiveCustodyTestSource.includes("noLockScreenRejectsPersistentKeyStoreAndRequiresMemoryOnlyCustody") &&
    secureMeshAndroidAdaptiveCustodyTestSource.includes("strongBoxUnavailableSelectsNextSafeKeyStoreCandidate") &&
    !secureMeshAndroidBridgeSource.includes("contentKeyBase64url") &&
    !secureMeshAndroidBridgeSource.includes("includeBodyBase64url") &&
    secureMeshAndroidUserAuthenticatorSource.includes("class SecureMeshAndroidUserAuthenticator") &&
    secureMeshAndroidUserAuthenticatorSource.includes("KeyguardManager") &&
    secureMeshAndroidUserAuthenticatorSource.includes("BiometricPrompt") &&
    secureMeshAndroidUserAuthenticatorSource.includes("BIOMETRIC_STRONG") &&
    secureMeshAndroidUserAuthenticatorSource.includes("DEVICE_CREDENTIAL") &&
    secureMeshAndroidUserAuthenticatorSource.includes("SystemClock.elapsedRealtime()") &&
    secureMeshAndroidUserAuthenticatorSource.includes("authorizationGrantExtendedByDispatch") &&
    secureMeshAndroidUserAuthenticatorSource.includes("mayStartAuthenticationPrompt") &&
    secureMeshAndroidAuthorizationPolicyTestSource.includes("unknownActionsFailClosed") &&
    secureMeshAndroidAuthorizationPolicyTestSource.includes("relayAndKeyActionsRequireAuthentication") &&
    secureMeshAndroidManifestSource.includes("android.permission.USE_BIOMETRIC") &&
    secureMeshAndroidManifestSource.includes('android:allowBackup="false"') &&
    secureMeshAndroidManifestSource.includes('android:dataExtractionRules="@xml/backup_rules"') &&
    secureMeshAndroidManifestSource.includes('android:fullBackupContent="@xml/backup_rules_legacy"') &&
    secureMeshAndroidBackupRulesSource.includes('<cloud-backup>') &&
    secureMeshAndroidBackupRulesSource.includes('<device-transfer>') &&
    secureMeshAndroidBackupRulesSource.includes('<exclude domain="root" path="." />') &&
    secureMeshAndroidBackupRulesSource.includes('<exclude domain="device_root" path="." />') &&
    !secureMeshAndroidManifestSource.includes("ReleaseAcceptanceReceiver") &&
    !secureMeshAndroidManifestSource.includes("land.lico.licoup.RELEASE_ACCEPTANCE") &&
    secureMeshAndroidDebugManifestSource.includes("ReleaseAcceptanceReceiver") &&
    secureMeshAndroidDebugManifestSource.includes("android.permission.DUMP") &&
    secureMeshAndroidBuildSource.includes('"mainActivityClass"] = "land.lico.licoup.MainActivity"') &&
    secureMeshAndroidBuildSource.includes('"mainActivityClass"] = "land.lico.licoup.DebugMainActivity"') &&
    !secureMeshAndroidBridgeSource.includes("ReleaseAcceptanceChannel") &&
    secureMeshAndroidDebugAcceptanceSource.includes("ReleaseAcceptanceChannel.evaluate") &&
    secureMeshAndroidDebugAcceptanceSource.includes("ReleaseAcceptanceDebugCodec") &&
    secureMeshAndroidUserAuthenticatorSource.includes("createConfirmDeviceCredentialIntent") &&
    secureMeshAndroidUserAuthenticatorSource.includes("physicalUserPresenceRequired") &&
    secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptAvailable") &&
    secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptStarted") &&
    secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptCompleted") &&
    secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptResultCodePresent") &&
    secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptResultCode") &&
    secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptResult") &&
    secureMeshAndroidUserAuthenticatorSource.includes("systemCredentialPromptReusedFromPendingRequest") &&
    secureMeshAndroidUserAuthenticatorSource.includes("pendingLatch") &&
    secureMeshAndroidUserAuthenticatorSource.includes("userActionRequired") &&
      secureMeshAndroidUserAuthenticatorSource.includes("credentialEntrySurface") &&
      secureMeshAndroidUserAuthenticatorSource.includes("android_system_credential_prompt") &&
      secureMeshAndroidUserAuthenticatorSource.includes("systemAuthenticationOnly") &&
      secureMeshAndroidUserAuthenticatorSource.includes("appLockScreenCredentialCollection") &&
      secureMeshAndroidUserAuthenticatorSource.includes("appCredentialPromptUsed") &&
      secureMeshAndroidUserAuthenticatorSource.includes("appPasswordPromptUsed") &&
    secureMeshAndroidUserAuthenticatorSource.includes("keyMaterialHandledByAuthenticationFlow") &&
    secureMeshAndroidBridgeSource.includes("bodyRedacted") &&
    !secureMeshAndroidSecretStoreSource.includes("setUserAuthenticationRequired(false)") &&
    secureMeshAndroidBridgeBoundaryTestSource.includes("mainActivityKeepsOnlyLifecycleAndJniBindings") &&
    secureMeshAndroidSecretStoreBoundaryTestSource.includes("jniSecretStoreIsABoundedFacade"),
    "Android Secure Mesh must keep optional system prompting in its authenticator, select strongest-compatible KeyStore policy from independent facts, and use process-memory custody only when safe KeyStore generation is unavailable"
  );
  assert(!secureMeshAndroidBridgeSource.includes("ChaCha20-Poly1305") &&
    !secureMeshAndroidBridgeSource.includes("HmacSHA256") &&
    !secureMeshAndroidBridgeSource.includes("SecretKeySpec(derivedKey") &&
    !secureMeshAndroidBridgeSource.includes("contentKeyBase64url") &&
    !secureMeshAndroidBridgeSource.includes("includeBodyBase64url"),
    "Android Secure Mesh must not expose raw payload keys or plaintext body export through native actions"
  );
  for (const forbiddenToken of [
    "lockScreenPassword",
    "screenLockPassword",
    "devicePassword",
      "deviceCredentialPassword",
      "devicePasswordInput",
      "userEnteredPassword",
      "appLockPassword",
        ".put(\"appCredentialPromptUsed\", true)",
        ".put(\"appPasswordPromptUsed\", true)",
        ".put(\"appLockScreenCredentialCollection\", true)",
        "\"appCredentialPromptUsed\" to true",
        "\"appPasswordPromptUsed\" to true",
        "\"appLockScreenCredentialCollection\" to true",
        "appCredentialPromptUsed = true",
        "appPasswordPromptUsed = true",
        "appLockScreenCredentialCollection = true",
      ]) {
    assert(!secureMeshAndroidAuthBoundarySource.includes(forbiddenToken),
      `Android platform auth files must not collect lock-screen credentials in-app via ${forbiddenToken}`);
  }
  const androidPairingVerifierSource = await readText(
    "apps/desktop/android/app/src/test/kotlin/land/lico/licoup/SecureMeshAndroidAdaptiveCustodyTest.kt"
  );
  const androidHostileVerifierSource = await readText(
    "apps/desktop/android/app/src/test/kotlin/land/lico/licoup/SecureMeshAndroidAuthorizationPolicyTest.kt"
  );
  assert(secureMeshAndroidDebugAcceptanceSource.includes("safeStatusKeys") &&
    secureMeshAndroidDebugAcceptanceSource.includes('"allPrivateKeysInSelectedCustody"') &&
    !secureMeshAndroidBridgeSource.includes("safeAdbStatusKeys") &&
    !secureMeshAndroidBridgeSource.includes("externalFilesDir") &&
    androidPairingVerifierSource.includes("noLockScreenRejectsPersistentKeyStoreAndRequiresMemoryOnlyCustody") &&
    androidPairingVerifierSource.includes("memoryOnlyStoreCopiesAndClearsProcessBuffers") &&
    androidPairingVerifierSource.includes("re_pair_rekey_after_restart") &&
    androidHostileVerifierSource.includes("relayAndKeyActionsRequireAuthentication") &&
    androidHostileVerifierSource.includes("mayStartAuthenticationPrompt") &&
    androidHostileVerifierSource.includes("unknownActionsFailClosed"),
    "Android native custody tests must verify fail-closed authentication, memory clearing, and restart re-pair/rekey without exposing secret values"
  );
}
