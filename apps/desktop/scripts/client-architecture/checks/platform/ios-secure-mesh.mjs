export async function checkIosSecureMesh(context) {
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
    sourceLineCount,
  } = context;
  const secureMeshIosBridgeSource = await readJoinedText([
    "apps/desktop/ios/Runner/SecureMeshIosBridge.swift",
    "apps/desktop/ios/Runner/SecureMeshIosBridge+SecretStore.swift",
    "apps/desktop/ios/Runner/SecureMeshIosBridge+LocalAuth.swift"
  ]);
  const secureMeshIosBridgeHeaderSource = await readText("apps/desktop/ios/Runner/Runner-Bridging-Header.h");
  const secureMeshIosFfiSource = await readText("crates/lico-client-native/src/ffi/ios_ffi.rs");
  const iosXcodeProjectSource = await readText("apps/desktop/ios/Runner.xcodeproj/project.pbxproj");
  const iosRunnerSchemeSource = await readText(
    "apps/desktop/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme"
  );
  const iosNativeBuildScriptSource = await readText(
    "apps/desktop/ios/scripts/build-secure-mesh-native.sh"
  );
  const iosPermissionNormalizerSource = await readText(
    "apps/desktop/ios/scripts/normalize-ios-artifact-permissions.sh"
  );
  const iosRelayIntegrationTestSource = await readText("apps/desktop/integration_test/mobile_relay_ios_e2e_test.dart");
  const iosRelayVerifierSource = iosRelayIntegrationTestSource;
  assert(secureMeshIosBridgeSource.includes("native_c_abi_in_process_secret_callback") &&
    secureMeshIosBridgeSource.includes("rust_secure_mesh_secret_store_handle_v1") &&
    secureMeshIosBridgeSource.includes("app.licoarc.mobile-relay.secret-store.v2") &&
    !secureMeshIosBridgeSource.includes("app.licoarc.mobile-relay.secret-store.v1") &&
    secureMeshIosBridgeSource.includes("lico_secure_mesh_json_with_secret_store") &&
      secureMeshIosBridgeSource.includes("LicoSecureMeshSecretStoreCallbacks") &&
      secureMeshIosBridgeSource.includes("SecureMeshIosSecretStoreCallbackContext") &&
      secureMeshIosBridgeSource.includes("kSecUseAuthenticationContext") &&
      secureMeshIosBridgeSource.includes("callbackSecretReadCount") &&
      secureMeshIosBridgeSource.includes("iosProductionCallbackAuth") &&
      secureMeshIosBridgeSource.includes("iosCallbackReadsUseSharedLAContext") &&
      secureMeshIosBridgeSource.includes("iosSingleSystemAuthorizationContextVerified") &&
      secureMeshIosBridgeSource.includes("iosCallbackAuthContextAttachedToAllReads") &&
      secureMeshIosBridgeSource.includes("iosSecretStoreSetCallback") &&
    secureMeshIosBridgeSource.includes("iosSecretStoreGetCallback") &&
    secureMeshIosBridgeSource.includes("iosSecretStoreDeleteCallback") &&
    secureMeshIosBridgeSource.includes('"mobileRelayE2eeSecretStore": false') &&
    secureMeshIosBridgeSource.includes('"rustSecretStoreSelectable": false') &&
    secureMeshIosBridgeSource.includes('"rawJsonSecretOverridesUsed": false') &&
    secureMeshIosBridgeSource.includes("SecItemUpdate") &&
    secureMeshIosBridgeSource.includes("updateStatus == errSecItemNotFound") &&
    secureMeshIosBridgeSource.includes("addStatus == errSecDuplicateItem") &&
    secureMeshIosBridgeSource.includes("LICO_SECURE_MESH_SECRET_GET_NOT_FOUND") &&
    secureMeshIosBridgeSource.includes("LICO_SECURE_MESH_SECRET_GET_ERROR") &&
    secureMeshIosBridgeSource.includes("mobileRelaySecretStoreBackend") &&
    secureMeshIosBridgeSource.includes("ios-keychain") &&
    secureMeshIosBridgeHeaderSource.includes("LicoSecureMeshSecretStoreCallbacks") &&
    secureMeshIosBridgeHeaderSource.includes("lico_secure_mesh_json_with_secret_store") &&
    secureMeshIosFfiSource.includes("struct IosCallbackSecretStore") &&
    secureMeshIosFfiSource.includes("impl SecureMeshSecretStore for IosCallbackSecretStore") &&
    secureMeshIosFfiSource.includes("dispatch_json_with_files_dir_and_pairwise_secret_store") &&
    secureMeshIosFfiSource.includes("ios_callback_secret_store_round_trips_opaque_handles") &&
    secureMeshIosFfiSource.includes("ios_callback_secret_store_propagates_read_errors") &&
    !secureMeshIosBridgeSource.includes('params["secretOverrides"]') &&
    !secureMeshIosBridgeSource.includes('params["secretOverrideTransport"]') &&
    secureMeshIosBridgeSource.includes('"signingKeyBase64url"') &&
    secureMeshIosBridgeSource.includes('"signedPrekeyPrivateKeyBase64url"') &&
    secureMeshIosBridgeSource.includes('"oneTimePrekeyPrivateKeyBase64url"') &&
    secureMeshIosBridgeSource.includes('"pairingSecretBase64url"') &&
    secureMeshIosBridgeSource.includes('"pairingSecret"'),
    "SecureMeshIosBridge must use the callback secret-store C ABI, atomic Keychain updates, strict found/not-found/error reads, and fail-closed capability projection without raw JSON secret overrides"
  );
  assert(iosRelayVerifierSource.includes("SecureMeshIosBridge") &&
    iosRelayVerifierSource.includes("mobile.relay.pairing.claim") &&
    iosRelayVerifierSource.includes("mobile.relay.pairing.status") &&
    iosRelayVerifierSource.includes("mobile.relay.commands.createSecure") &&
    iosRelayVerifierSource.includes("mobile.relay.commands.resultReplayProof") &&
      iosRelayVerifierSource.includes("LICO_IOS_MOBILE_RELAY_E2E_SUMMARY") &&
      iosRelayVerifierSource.includes("iosProductionCallbackAuth") &&
      iosRelayVerifierSource.includes("iosCallbackReadsUseSharedLAContext") &&
      iosRelayVerifierSource.includes("iosSingleSystemAuthorizationContextVerified") &&
      iosRelayVerifierSource.includes("iosCallbackAuthContextAttachedToAllReads") &&
      iosRelayVerifierSource.includes("appPasswordPromptUsedPresent") &&
      iosRelayVerifierSource.includes("appCredentialPromptUsedPresent") &&
      iosRelayVerifierSource.includes("keyMaterialExportedPresent") &&
      !iosRelayVerifierSource.includes("configuredGatewayHost") &&
    !iosRelayVerifierSource.includes("deviceGatewayHost") &&
    iosRelayIntegrationTestSource.includes("IntegrationTestWidgetsFlutterBinding") &&
    iosRelayIntegrationTestSource.includes("SecureMeshIosBridge") &&
    iosRelayIntegrationTestSource.includes("mobile.relay.e2ee.status") &&
    iosRelayIntegrationTestSource.includes("mobile.relay.commands.createSecure") &&
      iosRelayIntegrationTestSource.includes("mobile.relay.commands.resultSecure") &&
      iosRelayIntegrationTestSource.includes("iosProductionCallbackAuth") &&
      iosRelayIntegrationTestSource.includes("callbackSecretReadCount") &&
      iosRelayIntegrationTestSource.includes("appPasswordPromptUsedPresent") &&
      iosRelayIntegrationTestSource.includes("allPrivateKeysBoundToPlatform") &&
    iosRelayIntegrationTestSource.includes("portableConfigPrivateKeyPresent") &&
    iosRelayIntegrationTestSource.includes("iOS Keychain"),
    "iOS real-device Mobile Relay verifier must drive the Keychain bridge via Flutter integration tests, assert encrypted command/result flow, and avoid printing local gateway/device identifiers"
  );
  assert(iosRunnerSchemeSource.includes("scripts/build-secure-mesh-native.sh") &&
    iosRunnerSchemeSource.includes("scripts/normalize-ios-artifact-permissions.sh") &&
    iosNativeBuildScriptSource.includes("NATIVE_ARCH_ACTUAL") &&
    iosNativeBuildScriptSource.includes("undefined_arch") &&
    iosNativeBuildScriptSource.includes("aarch64-apple-ios-sim") &&
    iosNativeBuildScriptSource.includes("x86_64-apple-ios") &&
    iosNativeBuildScriptSource.includes("SDKROOT=\"$(xcrun --sdk macosx --show-sdk-path)\"") &&
    iosPermissionNormalizerSource.includes("/usr/bin/find -P") &&
    iosPermissionNormalizerSource.includes("/bin/chmod go-w") &&
    !iosXcodeProjectSource.includes("Build Secure Mesh iOS Native") &&
    iosXcodeProjectSource.includes("SecureMeshIosBridge+SecretStore.swift in Sources") &&
    iosXcodeProjectSource.includes("SecureMeshIosBridge+LocalAuth.swift in Sources"),
    "iOS Secure Mesh scheme actions must build all requested Rust targets before Xcode links, isolate host links from the iOS SDKROOT, normalize bundle permissions without following symlinks, and compile split bridge extension files"
  );
}
