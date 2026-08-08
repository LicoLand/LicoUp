import { signerIdentityDigestByFacts } from "./limits.mjs";
import { requireValue } from "./require.mjs";

export function assertAndroidApkFactsEqual(expected, actual) {
  return assertAndroidApkFactsMatch(expected, actual, true);
}


export function assertAndroidApkPayloadFactsEqual(expected, actual) {
  return assertAndroidApkFactsMatch(expected, actual, false);
}


export function assertAndroidApkFactsMatch(expected, actual, compareArtifactDigest) {
  for (const field of [
    ...(compareArtifactDigest ? ["artifactDigest"] : []),
    "packageName",
    "versionCode",
    "versionName",
    "debuggable",
    "launchableActivity",
    "signerCount",
    "zipAligned",
  ]) {
    requireValue(expected?.[field] === actual?.[field],
      "Android APK installed facts do not match the source artifact");
  }
  requireValue(
    signerIdentityDigestByFacts.has(expected) &&
      signerIdentityDigestByFacts.get(expected) === signerIdentityDigestByFacts.get(actual),
    "Android APK installed signing identity does not match the source artifact",
  );
  requireValue(JSON.stringify(expected?.abis) === JSON.stringify(actual?.abis),
    "Android APK installed ABI facts do not match the source artifact");
  requireValue(JSON.stringify(expected?.signatureSchemes) ===
    JSON.stringify(actual?.signatureSchemes),
  "Android APK signature schemes do not match the source artifact");
  requireValue(JSON.stringify(expected?.nativeSecureMeshLibrary) ===
    JSON.stringify(actual?.nativeSecureMeshLibrary),
  "Android APK native secure-mesh library facts do not match the source artifact");
  return true;
}


export function androidApkSignerIdentityKeyId(facts) {
  const digest = signerIdentityDigestByFacts.get(facts);
  requireValue(/^sha256:[a-f0-9]{64}$/u.test(String(digest || "")),
    "Android APK signer certificate digest is unavailable");
  return digest;
}
