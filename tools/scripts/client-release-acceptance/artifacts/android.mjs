import { existsSync } from "node:fs";
import path from "node:path";
import {
  resolveContainedExistingPath,
  sha256File,
} from "../../lib/client-release-artifact-digest.mjs";
import { inspectAndroidApkFacts } from "../../lib/android-apk-facts.mjs";
import { androidReleaseBuildParametersReady } from "../../lib/android-release-build-policy.mjs";
import { repoRoot, SHA256 } from "../constants.mjs";
import { sanitizeArtifactBinding } from "../sanitize-binding.mjs";
import { readJson, requireValue, text } from "../util.mjs";
import { verifyArtifactReceipt } from "./receipt.mjs";

export function verifyAndroidArtifact(target, spec, clientVersion, receiptContext) {
  const productVersion = clientVersion.productVersion;
  const artifactPath = path.join(repoRoot, spec.ref);
  if (!existsSync(artifactPath)) {
    return sanitizeArtifactBinding({ targetId: target.id, artifactKind: spec.artifactKind });
  }
  const safeArtifactPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"), artifactPath, { expectedKind: "file" },
  );
  const facts = inspectAndroidApkFacts(repoRoot, safeArtifactPath, {
    requireApprovedToolchain: true,
  });
  const buildManifestPath = resolveContainedExistingPath(
    path.dirname(safeArtifactPath),
    path.join(path.dirname(safeArtifactPath), "build-manifest.json"),
    { expectedKind: "file" },
  );
  const manifest = readJson(buildManifestPath);
  const artifactDigest = facts.artifactDigest;
  const receipt = verifyArtifactReceipt(
    receiptContext, spec, target.id, productVersion, clientVersion.buildNumber, artifactDigest,
  );
  const targetReady = facts.packageName === text(spec.packageName) &&
    facts.debuggable === false &&
    JSON.stringify(facts.abis) === JSON.stringify([spec.requiredArchitecture]) &&
    facts.signerCount === 1 && facts.zipAligned === true &&
    facts.signatureSchemes.some((scheme) => ["v2", "v3", "v4"].includes(scheme)) &&
    manifest.schemaVersion === "licolite.client-android.apk-build-manifest.v3" &&
    manifest.targetId === target.id && manifest.mode === "release" &&
    androidReleaseBuildParametersReady(manifest.buildParameters) &&
    manifest.sourceStateDigest === receiptContext.payload?.sourceStateDigest &&
    manifest.packageName === facts.packageName &&
    manifest.debuggable === false &&
    JSON.stringify(manifest.abis) === JSON.stringify(facts.abis) &&
    manifest.launchableActivity === facts.launchableActivity &&
    manifest.signerCount === facts.signerCount &&
    JSON.stringify(manifest.signatureSchemes) === JSON.stringify(facts.signatureSchemes) &&
    manifest.zipAligned === true && manifest.signingKind === "local-install-keystore" &&
    manifest.signerIdentityVerified === true &&
    manifest.signingPolicySatisfied === true &&
    facts.nativeSecureMeshLibrary?.path ===
      "lib/arm64-v8a/liblico_client_native.so" &&
    facts.nativeSecureMeshLibrary?.regular === true &&
    facts.nativeSecureMeshLibrary?.unique === true &&
    facts.nativeSecureMeshLibrary?.size > 0 &&
    SHA256.test(text(facts.nativeSecureMeshLibrary?.contentDigest)) &&
    JSON.stringify(manifest.nativeSecureMeshLibrary) ===
      JSON.stringify(facts.nativeSecureMeshLibrary) &&
    manifest.nonBlockingDistributionGuidance?.blocking === false &&
    manifest.artifact?.digest === artifactDigest;
  const versionReady = facts.versionName === productVersion &&
    facts.versionCode === String(clientVersion.buildNumber) &&
    manifest.productVersion === productVersion &&
    manifest.buildNumber === clientVersion.buildNumber &&
    manifest.versionName === facts.versionName &&
    manifest.versionCode === facts.versionCode;
  const runtimeExecutableDigest = text(
    facts.nativeSecureMeshLibrary?.contentDigest,
  );
  const runtimeDigestReady = SHA256.test(runtimeExecutableDigest) &&
    receipt.runtimeExecutableDigest === runtimeExecutableDigest;
  return sanitizeArtifactBinding({
    targetId: target.id,
    productVersion,
    artifactKind: spec.artifactKind,
    artifactDigest,
    versionReady,
    targetReady,
    consumerIntegritySignatureReady:
      receipt.consumerIntegritySignatureReady,
    publicVerificationMaterialReady:
      receipt.publicVerificationMaterialReady,
    consumerVerificationReady: receipt.consumerVerificationReady,
    platformSecurityReady: receipt.platformSecurityReady,
    consumerIntegritySignatureKind:
      receipt.consumerIntegritySignatureKind,
    ...receipt,
    runtimeExecutableDigest,
    ready: versionReady && targetReady && receipt.consumerVerificationReady &&
      runtimeDigestReady && receipt.installReceiptReady &&
      receipt.receiptProvenanceReady
  });
}
