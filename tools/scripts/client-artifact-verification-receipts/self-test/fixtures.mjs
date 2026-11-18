export function fixtureDigest(character) {
  return `sha256:${character.repeat(64)}`;
}

export function fixtureMacos({
  sourceDigest,
  artifactDigest,
  productVersion,
  generatedAt,
  closureChallengeDigest,
  invocationNonceDigest,
}) {
  return {
    schemaVersion: "licoup.client.macos-consumer-verification.v1",
    verifier: "tools/scripts/client-macos-consumer-verification.mjs",
    generatedAt,
    closureChallengeDigest,
    invocationNonceDigest,
    ok: true,
    platform: "macos",
    redacted: true,
    reportLeakScan: true,
    rawRuntimeOutputIncluded: false,
    rawPrivateMaterialIncluded: false,
    sourceStateDigest: sourceDigest,
    dependencies: [],
    receipts: [{
      targetId: "macos-arm64",
      productVersion,
      buildNumber: 7,
      artifactKind: "macos-app-bundle",
      artifactDigest,
      runtimeExecutableDigest: fixtureDigest("4"),
      signatureKind: "local-identity-codesign",
      platformLocalSignatureReady: true,
      hardenedRuntime: true,
      nestedCodeMinimalEntitlements: true,
      entitlementsMatch: true,
      entitlementsDigest: fixtureDigest("e"),
      installedArtifactMatched: true,
      installReceiptReady: true,
      launchReady: true,
      newProcessReady: true,
      startedAfterInvocation: true,
      executableWithinInstalledBundle: true,
      closureChallengeBound: true,
      invocationNonceBound: true,
      stableProcessWindowReady: true,
      postLaunchArtifactStable: true,
      smokeReady: true,
    }],
  };
}

export function fixtureLinux({
  sourceDigest,
  artifactDigest,
  productVersion,
  generatedAt,
  closureChallengeDigest,
  invocationNonceDigest,
}) {
  return {
    schema: "licoup.client.linux-vm-package-receipt",
    schemaVersion: 2,
    producer: "linux-vm-package-receipt",
    generatedAt,
    closureChallengeDigest,
    invocationNonceDigest,
    productVersion,
    buildNumber: 7,
    ok: true,
    target: "ubuntu-linux-arm64",
    sourceBinding: {
      sourceStateDigest: sourceDigest,
      archiveDigest: artifactDigest,
      nativeClientDigest: fixtureDigest("4"),
    },
    package: { validationSignature: true, signatureVerified: true },
    summary: {
      installReceiptReady: true,
      sessionLaunchReady: true,
      smokeReady: true,
      privacyReady: true,
    },
  };
}
