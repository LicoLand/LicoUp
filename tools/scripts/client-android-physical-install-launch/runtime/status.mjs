import {
  summarizeAndroidCapabilityStore,
  validateAndroidCapabilityMeasurements,
  validateAndroidCapabilityProbe
} from "../../lib/secure-mesh-android-capabilities.mjs";
import {
  ANDROID_AUTHENTICATED_PAIRWISE_RUNTIME_STATUS,
  runtimeStatusRelativePath,
} from "../constants.mjs";
import { runAdb, sleep } from "../device/adb.mjs";
import { parseJson } from "../util/json.mjs";
import { hasOwn, objectContainsAnyKeyOrValue } from "../util/paths.mjs";

export function externalRuntimeStatusPath(packageName) {
  return `/sdcard/Android/data/${packageName}/files/secure-mesh/android-runtime-status.json`;
}

export function selectRuntimeStatusOutput(externalText, privateText) {
  if (externalText && privateText && externalText !== privateText) {
    return { ok: false, stdout: "", source: "conflicting-runtime-status" };
  }
  if (externalText) {
    return { ok: true, stdout: externalText, source: "external-app-specific" };
  }
  if (privateText) {
    return { ok: true, stdout: privateText, source: "app-private-run-as" };
  }
  return { ok: false, stdout: "", source: "" };
}

export function readRuntimeStatus(adb, serial, packageName) {
  const external = runAdb(adb, serial, ["shell", "cat", externalRuntimeStatusPath(packageName)], {
    timeoutMs: 5_000
  });
  const privateFile = runAdb(adb, serial, [
    "shell",
    "run-as",
    packageName,
    "cat",
    runtimeStatusRelativePath
  ], { timeoutMs: 5_000 });
  const externalText = external.ok ? String(external.stdout || "").trim() : "";
  const privateText = privateFile.ok ? String(privateFile.stdout || "").trim() : "";
  return selectRuntimeStatusOutput(externalText, privateText);
}

export function removeRuntimeStatusFiles(adb, serial, packageName) {
  runAdb(adb, serial, ["shell", "rm", "-f", externalRuntimeStatusPath(packageName)], { timeoutMs: 5_000 });
  runAdb(adb, serial, [
    "shell",
    "run-as",
    packageName,
    "rm",
    "-f",
    runtimeStatusRelativePath
  ], { timeoutMs: 5_000 });
}

export async function waitForRuntimeStatus(
  adb,
  serial,
  packageName,
  expectedClosureChallengeDigest,
  expectedInvocationNonceDigest,
  timeoutMs
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    const result = readRuntimeStatus(adb, serial, packageName);
    if (result.ok) {
      try {
        const status = parseJson(result.stdout);
        if (status.closureChallengeDigest === expectedClosureChallengeDigest &&
          status.invocationNonceDigest === expectedInvocationNonceDigest &&
          status.runtimeStatusFile?.closureChallengeDigest ===
            expectedClosureChallengeDigest &&
          status.runtimeStatusFile?.invocationNonceDigest ===
            expectedInvocationNonceDigest) {
          return { ...result, freshAfterLaunch: true };
        }
      } catch {
        // Continue polling until this invocation's challenged status appears.
      }
    }
    await sleep(1000);
  }
  return { ok: false, stdout: "", source: "", freshAfterLaunch: false };
}

export function validateRuntimeStatus(
  status,
  expectedClosureChallengeDigest,
  expectedInvocationNonceDigest
) {
  const secureStore = status.secureStore || {};
  const mobileRelaySecretStore = status.mobileRelaySecretStore || {};
  const nativeRuntime = status.nativeRuntime || {};
  const userAuthentication = status.userAuthentication || {};
  const runtimeStatusFile = status.runtimeStatusFile || {};
  const bridge = status.bridge || {};
  let secureCapabilityReport = null;
  let secureMeasurements = null;
  let mobileSummary = null;
  try {
    secureCapabilityReport = validateAndroidCapabilityProbe(
      secureStore.capabilityProbe,
    );
    secureMeasurements = validateAndroidCapabilityMeasurements(
      secureStore.measurements,
    );
    mobileSummary = summarizeAndroidCapabilityStore(mobileRelaySecretStore);
  } catch {
    secureCapabilityReport = null;
    secureMeasurements = null;
    mobileSummary = null;
  }

  const secureCustodyConsistent = secureCapabilityReport !== null &&
    secureMeasurements !== null &&
    secureCapabilityReport.custody?.strategy === secureMeasurements.custodyStrategy &&
    secureCapabilityReport.custody?.restartSemantics ===
      secureMeasurements.restartSemantics;
  const mobileCustodyConsistent = mobileSummary !== null &&
    mobileSummary.custodyStrategy === secureMeasurements?.custodyStrategy &&
    mobileSummary.restartSemantics === secureMeasurements?.restartSemantics &&
    ["enabled", "available", "unavailable", "unverified", "missingMandatory"]
      .every((field) => JSON.stringify(mobileSummary.capabilityReport?.[field]) ===
        JSON.stringify(secureCapabilityReport?.[field]));
  const mobileRelaySecretStoreContractReady = mobileSummary !== null &&
    mobileSummary.ffiBoundary === "jni" &&
    mobileSummary.secretTransport ===
      "jni_callback_in_process_secret_bytes" &&
    mobileSummary.secretStoreContract ===
      "rust_secure_mesh_secret_store_handle_v1" &&
    mobileSummary.secretStoreAccountPrefix === "mobileRelayE2ee" &&
    mobileSummary.secretStoreNamespace === "mobileRelayRuntime" &&
    mobileSummary.sharedRustSecretStoreHandleContract === true;
  const adaptiveAuthorizationReady = mobileSummary !== null &&
    mobileSummary.applicationAuthorizationGrantRequired === true &&
    mobileSummary.statusProbeSideEffectFree === true;
  const freshOneShotAuthorizationPolicyReady =
    userAuthentication.physicalUserPresenceRequired === true &&
    userAuthentication.systemAuthenticationOnly === true &&
    userAuthentication.appLockScreenCredentialCollection === false &&
    userAuthentication.appCredentialPromptUsed === false &&
    userAuthentication.appPasswordPromptUsed === false &&
    userAuthentication.systemCredentialPromptReused === false &&
    userAuthentication.systemCredentialPromptReusedFromPendingRequest === false &&
    userAuthentication.authorizationGrantPersisted === false &&
    userAuthentication.authorizationGrantExtendedByDispatch === false;
  const nativeRuntimeReady =
    nativeRuntime.provider === "licoup-native" &&
    nativeRuntime.library === "liblicoup_native.so" &&
    nativeRuntime.ffiBoundary === "jni" &&
    nativeRuntime.loaded === true &&
    nativeRuntime.selfTestPassed === true &&
    nativeRuntime.featureFlagsComplete === true &&
    nativeRuntime.usesSharedRustCore === true &&
    nativeRuntime.rawJsonSecretsPassedThroughFfi === false &&
    nativeRuntime.secretsPassedThroughFlutterMethodChannel === false &&
    nativeRuntime.jniSecretStoreCallbacksCarryInProcessSecret === true;
  const runtimeStatusRedacted = !objectContainsAnyKeyOrValue(
    status,
    new Set([
      "contentKeyBase64url",
      "includeBodyBase64url",
      "serial",
      "manufacturer",
      "model",
      "deviceId",
      "androidId",
      "keyAlias",
      "attestationChain"
    ])
  ) && nativeRuntime.rawJsonSecretsPassedThroughFfi === false &&
    nativeRuntime.secretsPassedThroughFlutterMethodChannel === false;
  const checks = {
    statusOk: status.ok === true,
    protocolVersion: status.protocolVersion === "licomesh.secure-mesh.v1",
    endpointKind: status.endpointKind === "mobile",
    platform: status.platform === "android",
    bridgeChannel: bridge.methodChannel === "licomesh.secure_mesh.android",
    bridgeMethods: bridge.statusMethod === true &&
      bridge.writeRuntimeStatusMethod === true &&
      bridge.nativeJsonMethod === true &&
      !hasOwn(bridge, "proofMethod"),
    secureCapabilityReport: secureCustodyConsistent &&
      secureCapabilityReport.mandatoryFoundationComplete === true,
    mobileCapabilityReport: mobileCustodyConsistent &&
      mobileSummary.mandatoryFoundationComplete === true,
    mobileRelaySecretStore: mobileRelaySecretStoreContractReady &&
      mobileSummary.rawJsonSecretOverridesUsed === false &&
      mobileSummary.rawJsonSecretOverridesProvenAbsent === true &&
      mobileSummary.portableConfigAuthority === "rust_generation_cas" &&
      mobileSummary.kotlinConfigReadWrite === false &&
      mobileSummary.statusProbeSideEffectFree === true &&
      mobileSummary.androidKeyMaterialExported === false &&
      mobileSummary.decryptedSecretCrossesJniInProcess === true &&
      mobileSummary.getNotFoundSeparatedFromFailure === true,
    adaptiveAuthorization: adaptiveAuthorizationReady,
    freshOneShotAuthorizationPolicy: freshOneShotAuthorizationPolicyReady,
    nativeRuntime: nativeRuntimeReady,
    authenticatedPairwiseRuntime:
      status.pairwiseRuntimeStatus ===
        ANDROID_AUTHENTICATED_PAIRWISE_RUNTIME_STATUS,
    runtimeStatusRedacted,
    runtimeStatusFile:
      runtimeStatusFile.relativePath === runtimeStatusRelativePath &&
      runtimeStatusFile.writtenByAppProcess === true &&
      runtimeStatusFile.closureChallengeDigest === expectedClosureChallengeDigest &&
      runtimeStatusFile.invocationNonceDigest === expectedInvocationNonceDigest,
    closureChallenge:
      status.closureChallengeDigest === expectedClosureChallengeDigest &&
      status.invocationNonceDigest === expectedInvocationNonceDigest,
    productionBlocked: status.productionReady === false,
    noCanaryPlaintext: !String(status.canaryPlaintext || "").trim()
  };
  const missing = Object.entries(checks)
    .filter(([, ok]) => ok !== true)
    .map(([key]) => key);
  const capabilitySummary = mobileSummary || {
    provider: "",
    ffiBoundary: "",
    secretTransport: "",
    secretStoreBackend: "",
    secretStoreContract: "",
    secretStoreAccountPrefix: "",
    secretStoreNamespace: "",
    sharedRustSecretStoreHandleContract: false,
    rawJsonSecretOverridesUsed: false,
    rawJsonSecretOverridesProvenAbsent: false,
    portableConfigAuthority: "",
    kotlinConfigReadWrite: false,
    statusProbeSideEffectFree: false,
    androidKeyMaterialExported: false,
    decryptedSecretCrossesJniInProcess: false,
    getNotFoundSeparatedFromFailure: false,
    applicationAuthorizationGrantRequired: false,
    custodyStrategy: "",
    restartSemantics: "",
    mandatoryFoundationComplete: false,
    enabledCapabilities: [],
    unavailableCapabilities: [],
    unverifiedCapabilities: [],
    userAuthenticationSelected: false,
    deviceCredentialAvailable: false,
    strongBiometricAvailable: false,
    securityLevel: "",
    capabilityReport: null,
    measurements: null
  };
  return {
    ok: missing.length === 0,
    missing,
    nativeRuntimeReady,
    authenticatedPairwiseV2RuntimeReady:
      checks.authenticatedPairwiseRuntime,
    runtimeStatusRedacted,
    androidCustodyReady:
      checks.secureCapabilityReport && checks.mobileCapabilityReport,
    adaptiveAuthorizationReady,
    freshOneShotAuthorizationPolicyReady,
    summary: {
      ok: missing.length === 0,
      protocolVersion: checks.protocolVersion,
      bridgeMethodChannelReady: checks.bridgeChannel && checks.bridgeMethods,
      androidCustodyReady:
        checks.secureCapabilityReport && checks.mobileCapabilityReport,
      adaptiveAuthorizationReady,
      freshOneShotAuthorizationPolicyReady,
      userAuthentication: {
        physicalUserPresenceRequired:
          userAuthentication.physicalUserPresenceRequired === true,
        systemAuthenticationOnly:
          userAuthentication.systemAuthenticationOnly === true,
        appLockScreenCredentialCollection:
          userAuthentication.appLockScreenCredentialCollection === true,
        appCredentialPromptUsed:
          userAuthentication.appCredentialPromptUsed === true,
        appPasswordPromptUsed:
          userAuthentication.appPasswordPromptUsed === true,
        systemCredentialPromptReused:
          userAuthentication.systemCredentialPromptReused === true,
        systemCredentialPromptReusedFromPendingRequest:
          userAuthentication.systemCredentialPromptReusedFromPendingRequest === true,
        authorizationGrantPersisted:
          userAuthentication.authorizationGrantPersisted === true,
        authorizationGrantExtendedByDispatch:
          userAuthentication.authorizationGrantExtendedByDispatch === true,
      },
      privateMaterialExported:
        secureStore.privateMaterialExported === true ||
        capabilitySummary.androidKeyMaterialExported === true,
      nativeRuntimeProvider: nativeRuntime.provider || "",
      nativeRuntimeLoaded: nativeRuntime.loaded === true,
      nativeRuntimeSelfTestPassed: nativeRuntime.selfTestPassed === true,
      nativeRuntimeFeatureFlagsComplete:
        nativeRuntime.featureFlagsComplete === true,
      nativeRuntimeUsesSharedRustCore:
        nativeRuntime.usesSharedRustCore === true,
      rawJsonSecretsPassedThroughFfi:
        nativeRuntime.rawJsonSecretsPassedThroughFfi === true,
      decryptedSecretCrossesJniInProcess:
        nativeRuntime.jniSecretStoreCallbacksCarryInProcessSecret === true,
      authenticatedPairwiseV2RuntimeReady:
        checks.authenticatedPairwiseRuntime,
      runtimeStatusRedacted,
      rawPayloadExportSurfaceAbsent:
        checks.bridgeMethods && runtimeStatusRedacted,
      rawRuntimeStatusIncluded: false,
      rawDeviceIdentifiersIncluded: false,
      mobileRelaySecretStoreContractReady,
      mobileRelaySecretStore: {
        provider: capabilitySummary.provider,
        ffiBoundary: capabilitySummary.ffiBoundary,
        secretTransport: capabilitySummary.secretTransport,
        secretStoreBackend: capabilitySummary.secretStoreBackend,
        secretStoreContract: capabilitySummary.secretStoreContract,
        secretStoreAccountPrefix:
          capabilitySummary.secretStoreAccountPrefix,
        secretStoreNamespace: capabilitySummary.secretStoreNamespace,
        sharedRustSecretStoreHandleContract:
          capabilitySummary.sharedRustSecretStoreHandleContract,
        rawJsonSecretOverridesUsedPresent:
          hasOwn(mobileRelaySecretStore, "rawJsonSecretOverridesUsed"),
        rawJsonSecretOverridesUsed:
          capabilitySummary.rawJsonSecretOverridesUsed,
        rawJsonSecretOverridesProvenAbsent:
          capabilitySummary.rawJsonSecretOverridesProvenAbsent,
        rawJsonSecretOverridesStaticSourceProvenAbsent: false,
        portableConfigAuthority:
          capabilitySummary.portableConfigAuthority,
        kotlinConfigReadWrite: capabilitySummary.kotlinConfigReadWrite,
        statusProbeSideEffectFree:
          capabilitySummary.statusProbeSideEffectFree,
        androidKeyMaterialExported:
          capabilitySummary.androidKeyMaterialExported,
        androidKeyMaterialExportedPresent:
          hasOwn(mobileRelaySecretStore, "androidKeyMaterialExported"),
        decryptedSecretCrossesJniInProcess:
          capabilitySummary.decryptedSecretCrossesJniInProcess,
        getNotFoundSeparatedFromFailure:
          capabilitySummary.getNotFoundSeparatedFromFailure,
        applicationAuthorizationGrantRequired:
          capabilitySummary.applicationAuthorizationGrantRequired,
        custodyStrategy: capabilitySummary.custodyStrategy,
        restartSemantics: capabilitySummary.restartSemantics,
        mandatoryFoundationComplete:
          capabilitySummary.mandatoryFoundationComplete,
        enabledCapabilities: capabilitySummary.enabledCapabilities,
        unavailableCapabilities:
          capabilitySummary.unavailableCapabilities,
        unverifiedCapabilities: capabilitySummary.unverifiedCapabilities,
        userAuthenticationSelected:
          capabilitySummary.userAuthenticationSelected,
        deviceCredentialAvailable:
          capabilitySummary.deviceCredentialAvailable,
        strongBiometricAvailable:
          capabilitySummary.strongBiometricAvailable,
        securityLevel: capabilitySummary.securityLevel,
        capabilityReport: capabilitySummary.capabilityReport,
        measurements: capabilitySummary.measurements,
        missingFields: missing,
        weakProofFields: [],
        missingFieldCount: missing.length,
        weakProofFieldCount: 0,
        implementationStatus:
          String(mobileRelaySecretStore.implementationStatus || "")
      },
      runtimeStatusWrittenByAppProcess:
        runtimeStatusFile.writtenByAppProcess === true,
      closureChallengeBound: checks.closureChallenge && checks.runtimeStatusFile,
      invocationNonceBound: checks.closureChallenge && checks.runtimeStatusFile,
      productionReady: status.productionReady === true,
      missing,
      androidMissingFields: missing,
      androidMissingFieldCount: missing.length,
      androidMissingFieldsAbsent: missing.length === 0,
      androidWeakProofFields: [],
      androidWeakProofFieldCount: 0,
      androidWeakProofFieldsAbsent: true
    }
  };
}
