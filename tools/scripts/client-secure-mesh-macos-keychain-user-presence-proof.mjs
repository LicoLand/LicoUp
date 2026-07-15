#!/usr/bin/env node

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  reduceCapabilityFacts,
  validateCapabilityReport,
} from "./lib/secure-mesh-capability-report.mjs";
import { loadSecureMeshPhysicalEvidenceConfig } from "./lib/secure-mesh-physical-evidence-config.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const physicalEvidenceConfig = await loadSecureMeshPhysicalEvidenceConfig();
const physicalReportRefs = physicalEvidenceConfig.linkedReports;
const defaultReportPath = physicalReportRefs.macosUserPresenceProof;
const reportSchemaVersion = "licolite.secure-mesh.macos-adaptive-custody-proof.v2";

const leakPatterns = Object.freeze([
  ["local_path", /(?:^|["\s])(?:\/Users\/|\/private\/|\/var\/folders\/|\/tmp\/|[A-Za-z]:\\)/u],
  ["bearer", /Bearer\s+(?!\[redacted\])\S+/u],
  ["token", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u],
  ["pem_material", /-----BEGIN|-----END/u],
  ["raw_secret_value", /"(?:privateKeyBase64url|signingKeyBase64url|sessionKey|rootKey|chainKey|messageKey)"\s*:\s*"[^"]{8,}"/u],
]);

const options = parseArgs(process.argv.slice(2));
let tempDir = "";
let configuredReportRef = "";

try {
  configuredReportRef = normalizeReportReference(
    options.report || defaultReportPath,
  );
  if (options.selfTest === true) {
    console.log(JSON.stringify(runPolicySelfTest()));
  } else {
    tempDir = mkdtempSync(path.join(os.tmpdir(), "lico-macos-adaptive-custody-proof-"));
    const report = runProof();
    writeReport(report);
    console.log(JSON.stringify({
      ok: report.ok,
      report: report.report,
      platform: report.platform,
      custodyStrategy: report.capabilityReport.custody?.strategy || "",
      enabledCapabilities: report.capabilityReport.enabled,
      safeOsStoreAvailable: report.summary.safeOsStoreAvailable,
      strongestObservedKeychainConfiguration:
        report.summary.strongestObservedKeychainConfiguration,
      promptBudgetSatisfied: report.summary.promptBudgetSatisfied,
    }, null, 2));
    if (!report.ok) process.exitCode = 1;
  }
} catch (error) {
  if (options.selfTest === true) {
    console.error(JSON.stringify({ ok: false, error: "macos_adaptive_custody_self_test_failed" }));
  } else {
    const report = failureReport(error);
    if (configuredReportRef) writeReport(report);
    console.error(JSON.stringify({
      ok: false,
      report: configuredReportRef || "",
      error: report.failure.code,
    }, null, 2));
  }
  process.exitCode = 1;
} finally {
  if (tempDir) rmSync(tempDir, { recursive: true, force: true });
}

function runProof() {
  if (process.platform !== "darwin") {
    throw new Error("macOS adaptive custody proof requires a macOS host");
  }
  const swiftPath = path.join(tempDir, "MacosAdaptiveCustodyProof.swift");
  writeFileSync(swiftPath, swiftSource(), "utf8");
  const helper = buildSignedSwiftHelper(swiftPath);
  if (!helper.signatureValid || !helper.path) {
    throw new Error(`signed helper unavailable: ${helper.failureCode}`);
  }
  const payload = parseJsonOutput(runSwiftProof(helper).stdout);
  const facts = createCapabilityFacts(payload);
  const capabilityReport = reduceCapabilityFacts(facts);
  const capabilityValidation = validateCapabilityReport(capabilityReport);
  const summary = summarize(payload, helper, capabilityReport, capabilityValidation);

  return {
    schemaVersion: reportSchemaVersion,
    verifier: "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
    generatedAt: new Date().toISOString(),
    report: configuredReportRef,
    platform: "macos",
    artifactKind: "macos-adaptive-custody-capability-proof",
    proofScope: "local_custody_only",
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawRuntimeOutputIncluded: false,
    interactionPolicy: {
      maximumInteractiveAuthorizationAttemptsPerProof: 1,
      backgroundInteractiveAuthorizationAttempts: 0,
      automaticRetryAllowed: false,
    },
    ok: summary.adaptiveCustodyProofReady,
    capabilityFacts: facts,
    capabilityReport,
    observed: observedProjection(payload, helper),
    summary,
  };
}

function summarize(payload, helper, capabilityReport, capabilityValidation) {
  const standardKeychainAvailable = probeSucceeded(payload.standardKeychain);
  const dataProtectionKeychainAvailable = probeSucceeded(payload.dataProtectionKeychain);
  const safeOsStoreAvailable = capabilityReport.custody?.strategy === "os_secure_store";
  const interactiveWorkflowSelected = payload.interactiveWorkflowSelected === true;
  const interactiveAuthorizationAttemptCount = Number(
    payload.interactiveAuthorizationAttemptCount || 0,
  );
  const promptBudgetSatisfied =
    interactiveAuthorizationAttemptCount <= 1 &&
    (interactiveWorkflowSelected || interactiveAuthorizationAttemptCount === 0) &&
    payload.appPasswordPromptUsed !== true &&
    payload.appCredentialPromptUsed !== true &&
    payload.automaticAuthorizationRetryUsed !== true;
  const zeroBackgroundPrompts = interactiveWorkflowSelected ||
    interactiveAuthorizationAttemptCount === 0;
  const protectedItemCreated = payload.userPresence?.itemCreated === true;
  const protectedItemCleaned = !protectedItemCreated ||
    payload.userPresence?.itemDeleted === true;
  const basicItemsCleaned =
    (!payload.standardKeychain?.itemCreated || payload.standardKeychain?.itemDeleted === true) &&
    (!payload.dataProtectionKeychain?.itemCreated ||
      payload.dataProtectionKeychain?.itemDeleted === true);
  const singleAuthorizationContextUsed =
    interactiveAuthorizationAttemptCount === 1 &&
    payload.singleAuthorizationContextCreated === true &&
    payload.singleAuthorizationContextSharedByOperations === true;
  const singleAuthorizationContextPolicySatisfied =
    interactiveAuthorizationAttemptCount === 0 || singleAuthorizationContextUsed;

  return {
    exactCapabilitySetValid: capabilityValidation.ok === true,
    safeOsStoreAvailable,
    standardKeychainAvailable,
    dataProtectionKeychainAvailable,
    strongestObservedKeychainConfiguration: dataProtectionKeychainAvailable
      ? "data_protection_keychain"
      : standardKeychainAvailable
        ? "standard_keychain"
        : "memory_only_ephemeral",
    deviceOnlyAccessibilityObserved:
      payload.standardKeychain?.deviceOnlyAccessibilityObserved === true ||
      payload.dataProtectionKeychain?.deviceOnlyAccessibilityObserved === true,
    localAuthenticationAvailable: payload.localAuthenticationAvailable === true,
    biometricMechanismAvailable: payload.biometricAuthenticationAvailable === true,
    userPresenceOperationSupported: userPresenceOperationSucceeded(payload),
    secureEnclaveOperationSupported: payload.secureEnclaveOperationSucceeded === true,
    interactiveWorkflowSelected,
    interactiveAuthorizationAttemptCount,
    interactiveAuthorizationSucceeded: payload.interactiveAuthorizationSucceeded === true,
    interactiveAuthorizationTimedOut: payload.interactiveAuthorizationTimedOut === true,
    singleAuthorizationContextUsed,
    singleAuthorizationContextPolicySatisfied,
    promptBudgetSatisfied,
    zeroBackgroundPrompts,
    noAutomaticAuthorizationRetry: payload.automaticAuthorizationRetryUsed !== true,
    appPasswordPromptUsed: payload.appPasswordPromptUsed === true,
    appCredentialPromptUsed: payload.appCredentialPromptUsed === true,
    helperSignatureValid: helper.signatureValid === true,
    helperSignatureMode: helper.signatureMode,
    basicItemsCleaned,
    protectedItemCleaned,
    adaptiveCustodyProofReady:
      helper.signatureValid === true &&
      helper.ran === true &&
      safeOsStoreAvailable &&
      capabilityValidation.ok === true &&
      promptBudgetSatisfied &&
      zeroBackgroundPrompts &&
      singleAuthorizationContextPolicySatisfied &&
      basicItemsCleaned &&
      protectedItemCleaned,
  };
}

function observedProjection(payload, helper) {
  return {
    signatureMode: helper.signatureMode,
    signedHelperRan: helper.ran === true,
    signedEntitlementSetApplied: helper.entitlementsApplied === true,
    standardKeychain: sanitizeStoreProbe(payload.standardKeychain),
    dataProtectionKeychain: sanitizeStoreProbe(payload.dataProtectionKeychain),
    userPresence: {
      selectedStore: String(payload.userPresence?.selectedStore || "none"),
      accessControlCreated: payload.userPresence?.accessControlCreated === true,
      itemCreated: payload.userPresence?.itemCreated === true,
      nonInteractiveReadBlocked: payload.userPresence?.nonInteractiveReadBlocked === true,
      authorizedReadSucceeded: payload.userPresence?.authorizedReadSucceeded === true,
      itemDeleted: payload.userPresence?.itemDeleted === true,
    },
    localAuthentication: {
      deviceOwnerAuthenticationAvailable: payload.localAuthenticationAvailable === true,
      biometricMechanismAvailable: payload.biometricAuthenticationAvailable === true,
    },
    secureEnclave: {
      privateKeyOperationSucceeded: payload.secureEnclaveOperationSucceeded === true,
    },
    interaction: {
      workflowSelected: payload.interactiveWorkflowSelected === true,
      authorizationAttemptCount: Number(payload.interactiveAuthorizationAttemptCount || 0),
      authorizationSucceeded: payload.interactiveAuthorizationSucceeded === true,
      authorizationTimedOut: payload.interactiveAuthorizationTimedOut === true,
      automaticRetryUsed: payload.automaticAuthorizationRetryUsed === true,
      singleAuthorizationContextUsed:
        Number(payload.interactiveAuthorizationAttemptCount || 0) === 1 &&
        payload.singleAuthorizationContextSharedByOperations === true,
    },
  };
}

function sanitizeStoreProbe(probe) {
  return {
    itemCreated: probe?.itemCreated === true,
    readMatched: probe?.readMatched === true,
    itemDeleted: probe?.itemDeleted === true,
    deviceOnlyAccessibilityObserved: probe?.deviceOnlyAccessibilityObserved === true,
  };
}

function createCapabilityFacts(payload) {
  const standardReady = probeSucceeded(payload.standardKeychain);
  const dataProtectionReady = probeSucceeded(payload.dataProtectionKeychain);
  const osStoreReady = standardReady || dataProtectionReady;
  const deviceOnlyReady =
    payload.standardKeychain?.deviceOnlyAccessibilityObserved === true ||
    payload.dataProtectionKeychain?.deviceOnlyAccessibilityObserved === true;
  const userPresenceReady = userPresenceOperationSucceeded(payload);
  const secureEnclaveReady = payload.secureEnclaveOperationSucceeded === true;

  return [
    capabilityFact(
      "custody.os_secure_store",
      osStoreReady,
      "macos_keychain_create_read_delete_verified",
      "macos_keychain_operation_unavailable",
    ),
    capabilityFact(
      "custody.software_backed",
      osStoreReady,
      "macos_keychain_software_custody_available",
      "macos_keychain_operation_unavailable",
    ),
    capabilityFact(
      "custody.non_exportable",
      secureEnclaveReady,
      "secure_enclave_private_key_non_exportable_operation_verified",
      "non_exportable_private_key_operation_unverified",
      secureEnclaveReady ? "supported" : "unverified",
    ),
    capabilityFact(
      "custody.device_bound",
      deviceOnlyReady || secureEnclaveReady,
      "this_device_only_or_secure_enclave_verified",
      "device_bound_operation_unverified",
      deviceOnlyReady || secureEnclaveReady ? "supported" : "unverified",
    ),
    capabilityFact(
      "custody.unlocked_device_required",
      deviceOnlyReady,
      "when_unlocked_this_device_only_verified",
      "unlocked_device_constraint_unverified",
      deviceOnlyReady ? "supported" : "unverified",
    ),
    capabilityFact(
      "custody.os_user_presence",
      userPresenceReady,
      "keychain_user_presence_operation_verified",
      payload.localAuthenticationAvailable === true
        ? "user_presence_operation_not_verified"
        : "local_authentication_unavailable",
      userPresenceReady
        ? "supported"
        : payload.localAuthenticationAvailable === true
          ? "unverified"
          : "unsupported",
    ),
    capabilityFact(
      "custody.device_credential",
      userPresenceReady && payload.localAuthenticationAvailable === true,
      "device_owner_authentication_operation_verified",
      payload.localAuthenticationAvailable === true
        ? "device_credential_operation_not_verified"
        : "device_credential_unavailable",
      userPresenceReady
        ? "supported"
        : payload.localAuthenticationAvailable === true
          ? "unverified"
          : "unsupported",
    ),
    capabilityFact(
      "custody.strong_biometric",
      false,
      "strong_biometric_constraint_verified",
      payload.biometricAuthenticationAvailable === true
        ? "biometric_mechanism_available_constraint_not_selected"
        : "strong_biometric_unavailable",
      payload.biometricAuthenticationAvailable === true ? "unverified" : "unsupported",
    ),
    capabilityFact(
      "custody.authentication_validity_window",
      false,
      "authentication_window_verified",
      "one_shot_authorization_no_reuse_window",
      "unsupported",
    ),
    capabilityFact(
      "custody.enrollment_change_invalidation",
      false,
      "enrollment_change_invalidation_verified",
      "biometric_enrollment_constraint_not_selected",
      "unverified",
    ),
    capabilityFact(
      "custody.hardware_backed",
      secureEnclaveReady,
      "secure_enclave_private_key_operation_verified",
      "hardware_backed_operation_unverified",
      secureEnclaveReady ? "supported" : "unverified",
    ),
    capabilityFact(
      "custody.hardware_enforced_user_authentication",
      false,
      "hardware_user_authentication_verified",
      "hardware_user_authentication_not_verified",
      "unverified",
    ),
    capabilityFact("custody.android_keystore", false, "", "platform_not_applicable", "unsupported"),
    capabilityFact(
      "custody.apple_keychain",
      osStoreReady,
      "apple_keychain_operation_verified",
      "apple_keychain_operation_unavailable",
    ),
    capabilityFact("custody.linux_secret_service", false, "", "platform_not_applicable", "unsupported"),
    capabilityFact(
      "custody.data_protection_keychain",
      dataProtectionReady,
      "data_protection_keychain_operation_verified",
      "data_protection_keychain_operation_unavailable",
    ),
    capabilityFact("custody.tee", false, "", "platform_not_applicable", "unsupported"),
    capabilityFact("custody.strongbox", false, "", "platform_not_applicable", "unsupported"),
    capabilityFact(
      "custody.secure_enclave",
      secureEnclaveReady,
      "secure_enclave_private_key_operation_verified",
      "secure_enclave_operation_unavailable",
      secureEnclaveReady ? "supported" : "unsupported",
    ),
  ];
}

function capabilityFact(capability, supported, supportedReason, unavailableReason, stateOverride) {
  const state = stateOverride || (supported ? "supported" : "unsupported");
  return {
    capability,
    state,
    reasonCode: supported ? supportedReason : unavailableReason,
  };
}

function probeSucceeded(probe) {
  return probe?.itemCreated === true &&
    probe?.readMatched === true &&
    probe?.itemDeleted === true &&
    probe?.deviceOnlyAccessibilityObserved === true;
}

function userPresenceOperationSucceeded(payload) {
  const proof = payload.userPresence || {};
  return proof.accessControlCreated === true &&
    proof.itemCreated === true &&
    proof.nonInteractiveReadBlocked === true &&
    proof.authorizedReadSucceeded === true &&
    proof.itemDeleted === true &&
    Number(payload.interactiveAuthorizationAttemptCount || 0) === 1 &&
    payload.interactiveAuthorizationSucceeded === true;
}

function buildSignedSwiftHelper(swiftPath) {
  const bundlePath = path.join(tempDir, "MacosAdaptiveCustodyProof.app");
  const contentsPath = path.join(bundlePath, "Contents");
  const executableDirectory = path.join(contentsPath, "MacOS");
  mkdirSync(executableDirectory, { recursive: true });
  const helperPath = path.join(executableDirectory, "MacosAdaptiveCustodyProof");
  writeFileSync(path.join(contentsPath, "Info.plist"), helperInfoPlist(), "utf8");

  const compile = spawnSync("swiftc", [
    swiftPath,
    "-framework",
    "Foundation",
    "-framework",
    "LocalAuthentication",
    "-framework",
    "Security",
    "-o",
    helperPath,
  ], commandOptions(30_000));
  if (compile.status !== 0) {
    return failedHelper("compile_failed");
  }

  const selectedIdentity = selectCodesignIdentity();
  const signArgs = ["--force", "--sign", selectedIdentity.value, "--timestamp=none"];
  let entitlementsApplied = false;
  const teamIdentifier = resolveTeamIdentifier();
  if (selectedIdentity.value !== "-" && teamIdentifier) {
    const entitlementsPath = path.join(tempDir, "MacosAdaptiveCustodyProof.entitlements");
    writeFileSync(entitlementsPath, helperEntitlements(teamIdentifier), "utf8");
    signArgs.push("--entitlements", entitlementsPath);
    entitlementsApplied = true;
  }
  signArgs.push(bundlePath);
  const sign = spawnSync("codesign", signArgs, commandOptions(15_000));
  if (sign.status !== 0) {
    return failedHelper("codesign_failed", selectedIdentity.kind);
  }
  const verify = spawnSync(
    "codesign",
    ["--verify", "--strict", bundlePath],
    commandOptions(10_000),
  );
  if (verify.status !== 0) {
    return failedHelper("signature_verification_failed", selectedIdentity.kind);
  }
  return {
    path: helperPath,
    signatureValid: true,
    signatureMode: selectedIdentity.kind,
    entitlementsApplied,
    ran: false,
    failureCode: "",
  };
}

function failedHelper(failureCode, signatureMode = "unavailable") {
  return {
    path: "",
    signatureValid: false,
    signatureMode,
    entitlementsApplied: false,
    ran: false,
    failureCode,
  };
}

function selectCodesignIdentity() {
  const configured = String(
    options.signIdentity || process.env.LICO_MACOS_CODESIGN_IDENTITY || "",
  ).trim();
  if (configured) return { value: configured, kind: "configured_development" };
  const discovered = discoverDevelopmentCodesignIdentity();
  if (discovered) return { value: discovered, kind: "automatic_development" };
  return { value: "-", kind: "adhoc" };
}

function discoverDevelopmentCodesignIdentity() {
  const result = spawnSync(
    "security",
    ["find-identity", "-v", "-p", "codesigning"],
    commandOptions(5_000),
  );
  if (result.status !== 0) return "";
  const identities = String(result.stdout || "")
    .split(/\r?\n/u)
    .map((line) => line.match(/^\s*\d+\)\s+[A-F0-9]+\s+"([^"]+)"/u)?.[1] || "")
    .filter(Boolean);
  return identities.find((identity) => identity.startsWith("Apple Development:")) ||
    identities[0] ||
    "";
}

function resolveTeamIdentifier() {
  const configured = String(
    options.teamIdentifier || process.env.LICO_MACOS_DEVELOPMENT_TEAM || "",
  ).trim();
  return /^[A-Z0-9]{10}$/u.test(configured) ? configured : "";
}

function runSwiftProof(helper) {
  const env = { ...process.env };
  if (options.interactive === true) env.LICO_MACOS_USER_PRESENCE_INTERACTIVE = "1";
  const result = spawnSync(helper.path, [], {
    ...commandOptions(options.interactive === true ? 75_000 : 30_000),
    env,
  });
  helper.ran = result.status === 0;
  if (result.status !== 0) {
    throw new Error(`signed macOS adaptive custody helper failed with redacted status ${String(result.status ?? "unknown")}`);
  }
  return result;
}

function commandOptions(timeout) {
  return {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    timeout,
  };
}

function helperEntitlements(teamIdentifier) {
  const bundleIdentifier = "app.licoarc.secure-mesh.macos-adaptive-custody-proof";
  const applicationIdentifier = `${teamIdentifier}.${bundleIdentifier}`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>${applicationIdentifier}</string>
  <key>com.apple.developer.team-identifier</key>
  <string>${teamIdentifier}</string>
  <key>keychain-access-groups</key>
  <array>
    <string>${applicationIdentifier}</string>
  </array>
</dict>
</plist>
`;
}

function helperInfoPlist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>app.licoarc.secure-mesh.macos-adaptive-custody-proof</string>
  <key>CFBundleExecutable</key>
  <string>MacosAdaptiveCustodyProof</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
`;
}

function swiftSource() {
  return String.raw`
import Foundation
import LocalAuthentication
import Security

func randomData() -> Data {
  var bytes = [UInt8](repeating: 0, count: 32)
  _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
  return Data(bytes)
}

let service = "app.licoarc.secure-mesh.macos-adaptive-custody-proof"
let secret = randomData()

func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
  var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account
  ]
  if dataProtection {
    query[kSecUseDataProtectionKeychain as String] = true
  }
  return query
}

func basicStoreProbe(dataProtection: Bool) -> [String: Any] {
  let account = "basic-\(UUID().uuidString)"
  var addQuery = baseQuery(account: account, dataProtection: dataProtection)
  addQuery[kSecValueData as String] = secret
  addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

  var readQuery = baseQuery(account: account, dataProtection: dataProtection)
  readQuery[kSecReturnData as String] = true
  readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
  readQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  var copied: CFTypeRef?
  let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &copied)
  let readMatched = readStatus == errSecSuccess && (copied as? Data) == secret

  var deleteQuery = baseQuery(account: account, dataProtection: dataProtection)
  deleteQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  let deleteStatus = addStatus == errSecSuccess
    ? SecItemDelete(deleteQuery as CFDictionary)
    : errSecItemNotFound
  return [
    "itemCreated": addStatus == errSecSuccess,
    "readMatched": readMatched,
    "itemDeleted": addStatus != errSecSuccess || deleteStatus == errSecSuccess,
    "deviceOnlyAccessibilityObserved": addStatus == errSecSuccess && readMatched
  ]
}

struct PreparedUserPresence {
  let dataProtection: Bool
  let account: String
  let accessControlCreated: Bool
  let addStatus: OSStatus
  let nonInteractiveReadBlocked: Bool
}

func prepareUserPresence(dataProtection: Bool) -> PreparedUserPresence {
  let account = "presence-\(UUID().uuidString)"
  var accessError: Unmanaged<CFError>?
  let access = SecAccessControlCreateWithFlags(
    nil,
    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    .userPresence,
    &accessError
  )
  var addStatus: OSStatus = errSecParam
  if let access {
    var addQuery = baseQuery(account: account, dataProtection: dataProtection)
    addQuery[kSecValueData as String] = secret
    addQuery[kSecAttrAccessControl as String] = access
    addStatus = SecItemAdd(addQuery as CFDictionary, nil)
  }

  let nonInteractiveContext = LAContext()
  nonInteractiveContext.interactionNotAllowed = true
  var readQuery = baseQuery(account: account, dataProtection: dataProtection)
  readQuery[kSecReturnData as String] = true
  readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
  readQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  readQuery[kSecUseAuthenticationContext as String] = nonInteractiveContext
  var copied: CFTypeRef?
  let readStatus = addStatus == errSecSuccess
    ? SecItemCopyMatching(readQuery as CFDictionary, &copied)
    : errSecItemNotFound
  return PreparedUserPresence(
    dataProtection: dataProtection,
    account: account,
    accessControlCreated: access != nil,
    addStatus: addStatus,
    nonInteractiveReadBlocked:
      readStatus == errSecInteractionNotAllowed || readStatus == errSecAuthFailed
  )
}

func completeUserPresence(
  _ prepared: PreparedUserPresence,
  context: LAContext,
  authorized: Bool
) -> [String: Any] {
  var copied: CFTypeRef?
  var readStatus: OSStatus = errSecInteractionNotAllowed
  if authorized && prepared.addStatus == errSecSuccess {
    var readQuery = baseQuery(
      account: prepared.account,
      dataProtection: prepared.dataProtection
    )
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    readQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    readQuery[kSecUseAuthenticationContext as String] = context
    readStatus = SecItemCopyMatching(readQuery as CFDictionary, &copied)
  }
  let readMatched = readStatus == errSecSuccess && (copied as? Data) == secret

  let cleanupContext = LAContext()
  cleanupContext.interactionNotAllowed = true
  var deleteQuery = baseQuery(
    account: prepared.account,
    dataProtection: prepared.dataProtection
  )
  deleteQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  deleteQuery[kSecUseAuthenticationContext as String] = authorized ? context : cleanupContext
  let deleteStatus = prepared.addStatus == errSecSuccess
    ? SecItemDelete(deleteQuery as CFDictionary)
    : errSecItemNotFound
  return [
    "selectedStore": prepared.dataProtection
      ? "data_protection_keychain"
      : "standard_keychain",
    "accessControlCreated": prepared.accessControlCreated,
    "itemCreated": prepared.addStatus == errSecSuccess,
    "nonInteractiveReadBlocked": prepared.nonInteractiveReadBlocked,
    "authorizedReadSucceeded": readMatched,
    "itemDeleted": prepared.addStatus != errSecSuccess || deleteStatus == errSecSuccess
  ]
}

func secureEnclaveOperationProbe() -> Bool {
  var accessError: Unmanaged<CFError>?
  guard let access = SecAccessControlCreateWithFlags(
    nil,
    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    .privateKeyUsage,
    &accessError
  ) else {
    return false
  }
  let attributes: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrKeySizeInBits as String: 256,
    kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
    kSecPrivateKeyAttrs as String: [
      kSecAttrIsPermanent as String: false,
      kSecAttrAccessControl as String: access
    ]
  ]
  var keyError: Unmanaged<CFError>?
  guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError),
        SecKeyCopyPublicKey(privateKey) != nil,
        SecKeyIsAlgorithmSupported(
          privateKey,
          .sign,
          .ecdsaSignatureMessageX962SHA256
        ) else {
    return false
  }
  var signatureError: Unmanaged<CFError>?
  return SecKeyCreateSignature(
    privateKey,
    .ecdsaSignatureMessageX962SHA256,
    randomData() as CFData,
    &signatureError
  ) != nil
}

let context = LAContext()
context.localizedReason = "Authorize Lico Arc Secure Mesh local key access once."
var authError: NSError?
let localAuthenticationAvailable = context.canEvaluatePolicy(
  .deviceOwnerAuthentication,
  error: &authError
)
var biometricError: NSError?
let biometricAuthenticationAvailable = context.canEvaluatePolicy(
  .deviceOwnerAuthenticationWithBiometrics,
  error: &biometricError
)
let interactiveWorkflowSelected =
  ProcessInfo.processInfo.environment["LICO_MACOS_USER_PRESENCE_INTERACTIVE"] == "1"
let standardKeychain = basicStoreProbe(dataProtection: false)
let dataProtectionKeychain = basicStoreProbe(dataProtection: true)

var preparedUserPresence: PreparedUserPresence? = nil
if interactiveWorkflowSelected && localAuthenticationAvailable {
  if dataProtectionKeychain["itemCreated"] as? Bool == true {
    let candidate = prepareUserPresence(dataProtection: true)
    if candidate.addStatus == errSecSuccess {
      preparedUserPresence = candidate
    }
  }
  if preparedUserPresence == nil && standardKeychain["itemCreated"] as? Bool == true {
    let candidate = prepareUserPresence(dataProtection: false)
    if candidate.addStatus == errSecSuccess {
      preparedUserPresence = candidate
    }
  }
}

var interactiveAuthorizationAttemptCount = 0
var interactiveAuthorizationSucceeded = false
var interactiveAuthorizationTimedOut = false
if preparedUserPresence != nil {
  interactiveAuthorizationAttemptCount = 1
  let semaphore = DispatchSemaphore(value: 0)
  context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: context.localizedReason) { success, _ in
    interactiveAuthorizationSucceeded = success
    semaphore.signal()
  }
  interactiveAuthorizationTimedOut = semaphore.wait(timeout: .now() + 60) == .timedOut
  if interactiveAuthorizationTimedOut {
    context.invalidate()
  }
}

let skippedUserPresence: [String: Any] = [
  "selectedStore": "none",
  "accessControlCreated": false,
  "itemCreated": false,
  "nonInteractiveReadBlocked": false,
  "authorizedReadSucceeded": false,
  "itemDeleted": true
]
let userPresence = preparedUserPresence.map {
  completeUserPresence(
    $0,
    context: context,
    authorized: interactiveAuthorizationSucceeded && !interactiveAuthorizationTimedOut
  )
} ?? skippedUserPresence

let payload: [String: Any] = [
  "standardKeychain": standardKeychain,
  "dataProtectionKeychain": dataProtectionKeychain,
  "userPresence": userPresence,
  "localAuthenticationAvailable": localAuthenticationAvailable,
  "biometricAuthenticationAvailable": biometricAuthenticationAvailable,
  "secureEnclaveOperationSucceeded": secureEnclaveOperationProbe(),
  "singleAuthorizationContextCreated": true,
  "singleAuthorizationContextSharedByOperations": preparedUserPresence != nil,
  "interactiveWorkflowSelected": interactiveWorkflowSelected,
  "interactiveAuthorizationAttemptCount": interactiveAuthorizationAttemptCount,
  "interactiveAuthorizationSucceeded": interactiveAuthorizationSucceeded,
  "interactiveAuthorizationTimedOut": interactiveAuthorizationTimedOut,
  "automaticAuthorizationRetryUsed": false,
  "appPasswordPromptUsed": false,
  "appCredentialPromptUsed": false
]

let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
`;
}

function failureReport(error) {
  const capabilityFacts = [];
  const capabilityReport = reduceCapabilityFacts(capabilityFacts);
  validateCapabilityReport(capabilityReport);
  return {
    schemaVersion: reportSchemaVersion,
    verifier: "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
    generatedAt: new Date().toISOString(),
    report: configuredReportRef,
    platform: "macos",
    artifactKind: "macos-adaptive-custody-capability-proof",
    proofScope: "local_custody_only",
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawRuntimeOutputIncluded: false,
    interactionPolicy: {
      maximumInteractiveAuthorizationAttemptsPerProof: 1,
      backgroundInteractiveAuthorizationAttempts: 0,
      automaticRetryAllowed: false,
    },
    ok: false,
    capabilityFacts,
    capabilityReport,
    observed: {},
    summary: {
      exactCapabilitySetValid: true,
      safeOsStoreAvailable: false,
      standardKeychainAvailable: false,
      dataProtectionKeychainAvailable: false,
      strongestObservedKeychainConfiguration: "memory_only_ephemeral",
      promptBudgetSatisfied: false,
      adaptiveCustodyProofReady: false,
    },
    failure: {
      code: "macos_adaptive_custody_proof_failed",
      sanitized: sanitizeError(error),
    },
  };
}

function parseJsonOutput(output) {
  const text = String(output || "");
  const start = text.indexOf("{");
  if (start < 0) throw new Error("signed helper did not return a JSON result");
  return JSON.parse(text.slice(start));
}

function writeReport(report) {
  assertNoLeak(report, "secure mesh macOS adaptive custody proof report");
  atomicWriteReportJson(repoRoot, configuredReportRef, report);
}

function normalizeReportReference(value) {
  const ref = String(value || "").trim().replaceAll("\\", "/");
  if (!ref.startsWith("build/") || path.isAbsolute(ref) || ref.includes("\0") ||
    ref.split("/").some((component) => !component || component === "." || component === "..")) {
    throw new Error("macos_adaptive_custody_report_ref_invalid");
  }
  return ref;
}

function assertNoLeak(value, label) {
  const text = JSON.stringify(value);
  for (const [kind, pattern] of leakPatterns) {
    if (pattern.test(text)) throw new Error(`${label} contains sensitive data: ${kind}`);
  }
}

function sanitizeError(error) {
  return String(error instanceof Error ? error.message : error)
    .replace(/\/Users\/[^/\s"]+/gu, "<user-home>")
    .replace(/\/private\/var\/folders\/[^\s"]+/gu, "<local-temp>")
    .replace(/\/tmp\/[^\s"]+/gu, "<local-temp>")
    .replace(/[A-Za-z]:\\[^\s"]+/gu, "<local-path>")
    .replace(/Bearer\s+\S+/gu, "Bearer [redacted]")
    .replace(/\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]+\b/gu, "[redacted]")
    .slice(0, 500);
}

function parseArgs(args) {
  const booleanOptions = new Set(["interactive", "selfTest"]);
  const parsed = {};
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (!arg.startsWith("--")) continue;
    const [rawKey, inlineValue] = arg.slice(2).split("=", 2);
    const key = rawKey.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    if (inlineValue !== undefined) {
      parsed[key] = inlineValue;
    } else if (booleanOptions.has(key)) {
      parsed[key] = true;
    } else {
      parsed[key] = args[index + 1] ?? "";
      index += 1;
    }
  }
  return parsed;
}

function runPolicySelfTest() {
  const standardOnly = fixturePayload({ standard: true });
  const standardReport = reduceCapabilityFacts(createCapabilityFacts(standardOnly));
  validateCapabilityReport(standardReport);
  if (standardReport.custody?.strategy !== "os_secure_store" ||
      !standardReport.enabled.includes("custody.apple_keychain") ||
      standardReport.enabled.includes("custody.data_protection_keychain")) {
    throw new Error("standard Keychain must remain a valid lower safe exact capability set");
  }

  const stronger = fixturePayload({ standard: true, dataProtection: true, userPresence: true, secureEnclave: true });
  const strongerReport = reduceCapabilityFacts(createCapabilityFacts(stronger));
  validateCapabilityReport(strongerReport);
  for (const capability of [
    "custody.data_protection_keychain",
    "custody.os_user_presence",
    "custody.device_credential",
    "custody.secure_enclave",
  ]) {
    if (!strongerReport.enabled.includes(capability)) {
      throw new Error(`stronger verified capability did not accumulate: ${capability}`);
    }
  }
  if (!standardReport.enabled.every((capability) => strongerReport.enabled.includes(capability))) {
    throw new Error("stronger macOS facts must monotonically accumulate over standard Keychain");
  }

  const falseClaim = structuredClone(standardReport);
  falseClaim.enabled.push("custody.secure_enclave");
  let falseClaimRejected = false;
  try {
    validateCapabilityReport(falseClaim);
  } catch {
    falseClaimRejected = true;
  }
  if (!falseClaimRejected) throw new Error("false Secure Enclave enhancement claim was accepted");

  const source = swiftSource();
  if ((source.match(/context\.evaluatePolicy\(/gu) || []).length !== 1 ||
      !source.includes("interactiveAuthorizationAttemptCount = 1") ||
      !source.includes("automaticAuthorizationRetryUsed") ||
      !source.includes("kSecUseAuthenticationUIFail") ||
      !source.includes("prepareUserPresence(dataProtection: false)")) {
    throw new Error("macOS proof must preserve one-prompt adaptive fallback semantics");
  }

  let leakRejected = false;
  try {
    const privatePathFixture = ["", "Users", "example", "private"].join("/");
    assertNoLeak({ localArtifact: privatePathFixture }, "privacy fixture");
  } catch {
    leakRejected = true;
  }
  if (!leakRejected) throw new Error("macOS proof privacy fixture was accepted");

  let absoluteReportRejected = false;
  try {
    normalizeReportReference(["", "private", "fixture", "proof.json"].join("/"));
  } catch {
    absoluteReportRejected = true;
  }
  if (!absoluteReportRejected) {
    throw new Error("absolute macOS proof output was accepted");
  }

  return {
    ok: true,
    caseCount: 6,
    standardKeychainAccepted: true,
    strongerCapabilitiesAccumulate: true,
    falseEnhancementClaimRejected: true,
    singlePromptFlowEnforced: true,
    privacyFixtureRejected: true,
    absoluteReportRejected: true,
  };
}

function fixturePayload({
  standard = false,
  dataProtection = false,
  userPresence = false,
  secureEnclave = false,
} = {}) {
  const store = (ready) => ({
    itemCreated: ready,
    readMatched: ready,
    itemDeleted: true,
    deviceOnlyAccessibilityObserved: ready,
  });
  return {
    standardKeychain: store(standard),
    dataProtectionKeychain: store(dataProtection),
    userPresence: {
      selectedStore: userPresence
        ? dataProtection ? "data_protection_keychain" : "standard_keychain"
        : "none",
      accessControlCreated: userPresence,
      itemCreated: userPresence,
      nonInteractiveReadBlocked: userPresence,
      authorizedReadSucceeded: userPresence,
      itemDeleted: true,
    },
    localAuthenticationAvailable: userPresence,
    biometricAuthenticationAvailable: false,
    secureEnclaveOperationSucceeded: secureEnclave,
    singleAuthorizationContextCreated: true,
    singleAuthorizationContextSharedByOperations: true,
    interactiveWorkflowSelected: userPresence,
    interactiveAuthorizationAttemptCount: userPresence ? 1 : 0,
    interactiveAuthorizationSucceeded: userPresence,
    interactiveAuthorizationTimedOut: false,
    automaticAuthorizationRetryUsed: false,
    appPasswordPromptUsed: false,
    appCredentialPromptUsed: false,
  };
}
