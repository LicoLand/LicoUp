import path from "node:path";
import { statSync } from "node:fs";
import { androidReleaseBuildParametersReady } from "../../lib/android-release-build-policy.mjs";
import {
  inspectAndroidApkFacts,
  ANDROID_APK_RESOURCE_LIMITS,
} from "../../lib/android-apk-facts.mjs";
import {
  resolveContainedExistingPath,
  sha256File as stableSha256File,
  stableSnapshotFile,
  stableReadFile,
} from "../../lib/client-release-artifact-digest.mjs";
import { clientSourceStateDigest } from "../../lib/client-source-state-digest.mjs";
import { clientSourceRoots, repoRoot } from "../constants.mjs";
import { parseJson } from "../util/json.mjs";
import { clientVersionManifest } from "../version.mjs";

export function physicalReleaseApkReady(apk) {
  return apk?.mode === "release" && apk?.debuggable === false &&
    apk?.signingKind === "local-install-keystore";
}

export function findDefaultApk() {
  return path.join(repoRoot, "build/apps/desktop/android/release/app-release.apk");
}

export function inspectApk(configuredApk, workRoot) {
  const artifactRoot = path.join(repoRoot, "build/apps/desktop/android");
  const requestedPath = configuredApk
    ? path.resolve(repoRoot, configuredApk)
    : findDefaultApk();
  const apkPath = resolveContainedExistingPath(artifactRoot, requestedPath, {
    expectedKind: "file"
  });
  const snapshotPath = stableSnapshotFile(apkPath, workRoot, "source.apk", {
    maxBytes: ANDROID_APK_RESOURCE_LIMITS.maxApkBytes,
  });
  const facts = inspectAndroidApkFacts(repoRoot, snapshotPath, {
    requireApprovedToolchain: true,
  });
  const manifestPath = resolveContainedExistingPath(
    path.dirname(apkPath),
    path.join(path.dirname(apkPath), "build-manifest.json"),
    { expectedKind: "file" }
  );
  const manifest = parseJson(stableReadFile(manifestPath).toString("utf8"));
  const currentSourceStateDigest = clientSourceStateDigest(repoRoot, clientSourceRoots);
  const currentVersion = clientVersionManifest();
  const expectedMode = facts.debuggable ? "debug" : "release";
  const expectedSigningKind = facts.debuggable
    ? "local-debug"
    : "local-install-keystore";
  if (
    manifest.schemaVersion !== "licolite.client-android.apk-build-manifest.v3" ||
    manifest.mode !== expectedMode ||
    manifest.targetId !== "android-arm64" ||
    (expectedMode === "release" &&
      !androidReleaseBuildParametersReady(manifest.buildParameters)) ||
    manifest.sourceStateDigest !== currentSourceStateDigest ||
    manifest.productVersion !== currentVersion.productVersion ||
    manifest.buildNumber !== currentVersion.buildNumber ||
    manifest.packageName !== facts.packageName ||
    manifest.versionCode !== facts.versionCode ||
    manifest.versionName !== facts.versionName ||
    manifest.debuggable !== facts.debuggable ||
    JSON.stringify(manifest.abis) !== JSON.stringify(facts.abis) ||
    manifest.launchableActivity !== facts.launchableActivity ||
    manifest.signerCount !== facts.signerCount ||
    JSON.stringify(manifest.signatureSchemes) !== JSON.stringify(facts.signatureSchemes) ||
    manifest.zipAligned !== facts.zipAligned ||
    manifest.signerIdentityVerified !== true ||
    manifest.signingPolicySatisfied !== true ||
    JSON.stringify(manifest.nativeSecureMeshLibrary) !==
      JSON.stringify(facts.nativeSecureMeshLibrary) ||
    manifest.signingKind !== expectedSigningKind ||
    manifest.artifact?.file !== path.basename(apkPath) ||
    manifest.artifact?.digest !== facts.artifactDigest ||
    manifest.nonBlockingDistributionGuidance?.blocking !== false
  ) {
    throw new Error("Android APK build manifest is not bound to binary facts");
  }
  return {
    ok: true,
    mode: expectedMode,
    byteSize: statSync(snapshotPath).size,
    sha256: facts.artifactDigest,
    path: snapshotPath,
    hasNativeSecureMeshLibrary:
      facts.nativeSecureMeshLibrary?.path ===
        "lib/arm64-v8a/liblico_client_native.so" &&
      facts.nativeSecureMeshLibrary?.regular === true &&
      facts.nativeSecureMeshLibrary?.unique === true &&
      facts.nativeSecureMeshLibrary?.size > 0,
    nativeSecureMeshAbi: facts.abis.length === 1 ? facts.abis[0] : "",
    inspectedWithUnzip: false,
    binaryManifestInspected: true,
    sourceStateDigest: manifest.sourceStateDigest,
    productVersion: manifest.productVersion,
    buildNumber: manifest.buildNumber,
    buildManifestDigest: stableSha256File(manifestPath, {
      maxBytes: 16 * 1024 * 1024,
    }),
    sourceStateMatchesCurrent: true,
    manifestArtifactMatched: true,
    signingKind: manifest.signingKind,
    signatureVerified: true,
    signerIdentityVerified: true,
    signingPolicySatisfied: true,
    packageName: facts.packageName,
    versionCode: facts.versionCode,
    versionName: facts.versionName,
    debuggable: facts.debuggable,
    abis: facts.abis,
    launchableActivity: facts.launchableActivity,
    facts
  };
}
