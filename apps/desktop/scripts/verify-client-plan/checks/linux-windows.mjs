export async function checkLinuxWindows({ assert, files }) {
  const { readJson, readSourceBundle, readText } = files;
const physicalEvidenceManifest = await readText(
  "tools/scripts/client-secure-mesh-physical-evidence-manifest.mjs",
);
const physicalEvidenceConfig = await readText(
  "tools/scripts/config/secure-mesh-physical-evidence.json",
);
const linuxPackageUpdateProof =
  await readText("tools/scripts/client-secure-mesh-linux-package-update-proof.mjs");
const macosUserPresenceProof = await readSourceBundle(
  "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
  "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof",
  ".mjs",
);
const linuxAdaptiveCustodyProof =
  await readText("tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs");
const linuxVmPackageReceipt = await readSourceBundle(
  "tools/scripts/client-secure-mesh-linux-vm-package-receipt.mjs",
  "tools/scripts/client-secure-mesh-linux-vm-package-receipt",
  ".mjs",
);
const linuxNodeMatrix = await readSourceBundle(
  "tools/scripts/client-secure-mesh-linux-node-matrix.mjs",
  "tools/scripts/client-secure-mesh-linux-node-matrix",
  ".mjs",
);
const linuxNodeLifecycle =
  await readText("tools/scripts/lib/secure-mesh-linux-node.mjs");
const linuxEvidenceSchema = await readSourceBundle(
  "tools/scripts/lib/secure-mesh-linux-evidence.mjs",
  "tools/scripts/lib/secure-mesh-linux-evidence",
  ".mjs",
);
const linuxNodeDockerfile =
  await readText("apps/desktop/docker/secure-mesh-node.Dockerfile");
const releaseCliProof =
  await readText("tools/scripts/client-secure-mesh-release-cli-proof.mjs");
for (const [source, relativePath, tokens] of [
  [
    linuxVmPackageReceipt,
    "tools/scripts/client-secure-mesh-linux-vm-package-receipt.mjs",
    [
      "validateLinuxVmPackageReceipt",
      "expectedSourceDigest",
      "installedFromArchive",
      "signatureVerified",
      "publicKeyFingerprint",
      "x11_virtual_display",
      "exactCapabilitySchema"
    ]
  ],
  [
    linuxNodeMatrix,
    "tools/scripts/client-secure-mesh-linux-node-matrix.mjs",
    [
      "LinuxClientNode",
      "validateLinuxNodeMatrixReport",
      "publicOperationsOnly",
      "noSharedSecretVolume",
      "restartRequiresRePairRekey",
      "exchangeSecureCommand"
    ]
  ],
  [
    linuxNodeLifecycle,
    "tools/scripts/lib/secure-mesh-linux-node.mjs",
    [
      "--read-only",
      "--tmpfs",
      "portableDataDir",
      "restartRpc",
      "rpcStopped",
      "this.removed"
    ]
  ],
  [
    linuxEvidenceSchema,
    "tools/scripts/lib/secure-mesh-linux-evidence.mjs",
    [
      "validateCapabilityReport",
      "reportLeakScan",
      "runtimeIdentityIncluded",
      "dbusOrObjectDataIncluded",
      "rawPlaintextIncluded",
      "rawCiphertextIncluded",
      "rawSecretsIncluded"
    ]
  ],
  [
    linuxNodeDockerfile,
    "apps/desktop/docker/secure-mesh-node.Dockerfile",
    ["USER 65534:65534", "COPY client ${CLIENT_ROOT}", "WORKDIR ${CLIENT_ROOT}", "lico-client"]
  ]
]) {
  for (const token of tokens) {
    assert(source.includes(token), `${relativePath} must preserve Linux product proof token ${token}`);
  }
}
for (const [source, relativePath, tokens] of [
  [
    linuxPackageUpdateProof,
    "tools/scripts/client-secure-mesh-linux-package-update-proof.mjs",
    [
      "loadSecureMeshPhysicalEvidenceConfig",
      "physicalEvidenceConfig",
      "physicalReportRefs",
      "defaultReportPath = physicalReportRefs.ubuntuLinuxPackageUpdateProof"
    ]
  ],
  [
    macosUserPresenceProof,
    "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
    [
      "loadSecureMeshPhysicalEvidenceConfig",
      "physicalEvidenceConfig",
      "physicalReportRefs",
      "defaultReportPath: physicalReportRefs.macosUserPresenceProof"
    ]
  ],
  [
    linuxAdaptiveCustodyProof,
    "tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs",
    [
      "loadSecureMeshPhysicalEvidenceConfig",
      "physicalEvidenceConfig",
      "physicalReportRefs",
      "defaultReportPath = physicalReportRefs.ubuntuLinuxAdaptiveCustodyProof"
    ]
  ],
  [
    releaseCliProof,
    "tools/scripts/client-secure-mesh-release-cli-proof.mjs",
    [
      "loadSecureMeshPhysicalEvidenceConfig",
      "physicalEvidenceConfig",
      "physicalReportRefs",
      "defaultReleaseCliReportPath",
      "physicalReportRefs.macosReleaseCliProof",
      "physicalReportRefs.ubuntuReleaseCliProof"
    ]
  ]
]) {
  for (const token of tokens) {
    assert(source.includes(token),
      `${relativePath} must derive default report refs from physical evidence config token ${token}`);
  }
}
for (const [source, relativePath, token] of [
  [
    linuxPackageUpdateProof,
    "tools/scripts/client-secure-mesh-linux-package-update-proof.mjs",
    "const defaultReportPath = \"build/reports/secure-mesh-linux-package-update-proof.json\""
  ],
  [
    macosUserPresenceProof,
    "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
    "const defaultReportPath = \"build/reports/secure-mesh-macos-keychain-user-presence-proof.json\""
  ],
  [
    linuxAdaptiveCustodyProof,
    "tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs",
    "const defaultReportPath = \"build/reports/secure-mesh-linux-adaptive-custody-proof.json\""
  ],
  [
    releaseCliProof,
    "tools/scripts/client-secure-mesh-release-cli-proof.mjs",
    "const defaultReportPath = \"build/reports/secure-mesh-release-cli-proof.json\""
  ]
]) {
  assert(!source.includes(token),
    `${relativePath} must load configured default report ref instead of hardcoding ${token}`);
}
for (const token of [
  "appPasswordPromptUsed",
  "payload.appCredentialPromptUsed !== true",
  "payload.appPasswordPromptUsed !== true",
  "singleAuthorizationContextCreated",
  "singleAuthorizationContextSharedByOperations",
  "promptBudgetSatisfied",
  "zeroBackgroundPrompts",
  "noAutomaticAuthorizationRetry",
  "interactiveWorkflowSelected",
  "interactiveAuthorizationSucceeded",
  "interactiveAuthorizationAttemptCount = 1",
  "options.interactive === true",
  "kSecUseAuthenticationContext",
  "maximumInteractiveAuthorizationAttemptsPerProof: 1",
  "reduceCapabilityFacts",
  "validateCapabilityReport",
  "standardKeychainAvailable",
  "dataProtectionKeychainAvailable",
  "userPresenceOperationSupported",
  "secureEnclaveOperationSupported",
  "falseEnhancementClaimRejected"
]) {
  assert(macosUserPresenceProof.includes(token),
    `macOS user-presence proof must keep single system authorization diagnostic token ${token}`);
}
assert(!/const\s+reportRefs\s*=\s*Object\.freeze/u.test(physicalEvidenceManifest),
  "physical evidence manifest must load report refs from config instead of hardcoding them");
for (const token of [
  "loadSecureMeshPhysicalEvidenceConfig",
  "physicalEvidenceConfig",
  "relayMockCoverage",
  "androidPlatformCryptoCoverage",
  "relayProtocolMockReady",
  "androidPlatformCryptoAcceptanceReady",
  "physicalEvidenceChainReady",
  "releaseEvidenceReady",
  "reportLeakScan"
]) {
  assert(physicalEvidenceManifest.includes(token),
    `physical evidence manifest must keep current client evidence token ${token}`);
}
const windowsImplementation =
  await readText("tools/scripts/client-secure-mesh-windows-implementation.mjs");
const windowsImplementationConfig =
  await readText("tools/scripts/config/secure-mesh-windows-implementation.json");
const windowsImplementationConfigJson =
  await readJson("tools/scripts/config/secure-mesh-windows-implementation.json");
const windowsImplementationConfigHelper =
  await readText("tools/scripts/lib/secure-mesh-windows-implementation-config.mjs");
for (const token of [
  "loadSecureMeshWindowsImplementationConfig",
  "loadSecureMeshPhysicalEvidenceConfig",
  "windowsImplementationConfig",
  "physicalEvidenceConfig",
  "physicalReportRefs",
  "reportPath = physicalReportRefs.windowsImplementation",
  "sourceChecks = Object.freeze(windowsImplementationConfig.sourceChecks)",
  "physicalEvidenceConfig"
]) {
  assert(windowsImplementation.includes(token),
    `Windows implementation must keep configured physical evidence ref token ${token}`);
}
assert(!windowsImplementation.includes("const sourceChecks = Object.freeze(["),
  "Windows implementation must load source checks from config instead of hardcoding inline arrays");
for (const token of [
  "licomesh.secure-mesh.windows-implementation-config.v1",
  "sourceChecks",
  "windows-x64-builder-is-target-bound-and-arm64-fails-closed",
  "windows-pe-verifier-parses-machine-type",
  "windows-bundle-verifier-binds-source-digest-and-pe-facts",
  "windows-native-secret-store-stays-unverified-and-fail-closed",
  "windows-native-smoke-proves-secret-lifecycle-and-redaction",
  "windows-file-security-uses-owner-only-native-acl"
]) {
  assert(windowsImplementationConfig.includes(token),
    `Windows implementation config must keep token ${token}`);
}
assert(Array.isArray(windowsImplementationConfigJson.sourceChecks) &&
  windowsImplementationConfigJson.sourceChecks.length >= 5,
  "Windows implementation config must define source checks");
assert(windowsImplementationConfigJson.sourceChecks.every((check) =>
  check.file !== ".github/workflows/client-release.yml"),
"Windows local implementation closure must not depend on GitHub Release channel selection");
for (const token of [
  "loadSecureMeshWindowsImplementationConfig",
  "normalizeSafeSourceRef",
  "normalizeSourceChecks",
  "assertNoLeak",
  "source checks must have unique ids"
]) {
  assert(windowsImplementationConfigHelper.includes(token),
    `Windows implementation config helper must keep safety token ${token}`);
}
assert(!windowsImplementation.includes(
  "const reportPath = \"build/reports/secure-mesh-windows-implementation.json\""
), "Windows implementation must load configured evidence ref instead of hardcoding its report path");

}
