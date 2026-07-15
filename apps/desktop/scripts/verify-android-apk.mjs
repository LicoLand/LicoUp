#!/usr/bin/env node

import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { inspectAndroidApkFacts } from "../../../tools/scripts/lib/android-apk-facts.mjs";
import {
  resolveContainedExistingPath,
  sha256File,
  stableReadFile,
} from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import {
  atomicWriteReportJson,
  removeContainedReportIfExists,
} from "../../../tools/scripts/lib/safe-report-io.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "../../../tools/scripts/lib/client-source-state-digest.mjs";
import { androidReleaseBuildParametersReady } from "../../../tools/scripts/lib/android-release-build-policy.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const androidOutputRoot = path.join(workspaceRoot, "build/apps/desktop/android");
const releaseRoot = path.join(androidOutputRoot, "release");
const clientSourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function main() {
  removeContainedReportIfExists(androidOutputRoot, "release/distribution-manifest.json");
  const buildManifestPath = resolveContainedExistingPath(
    releaseRoot,
    path.join(releaseRoot, "build-manifest.json"),
    { expectedKind: "file" },
  );
  const buildManifest = JSON.parse(stableReadFile(buildManifestPath).toString("utf8"));
  const clientVersion = JSON.parse(stableReadFile(
    path.join(workspaceRoot, "tools/client-version.json"),
  ).toString("utf8"));
  requireValue(
    buildManifest?.schemaVersion === "licolite.client-android.apk-build-manifest.v3" &&
      buildManifest.mode === "release" &&
      buildManifest.targetId === "android-arm64" &&
      androidReleaseBuildParametersReady(buildManifest.buildParameters) &&
      buildManifest.signingKind === "local-install-keystore" &&
      buildManifest.debuggable === false &&
      buildManifest.packageName === "com.liko.arc" &&
      buildManifest.productVersion === clientVersion.productVersion &&
      buildManifest.buildNumber === clientVersion.buildNumber &&
      buildManifest.versionName === clientVersion.productVersion &&
      buildManifest.versionCode === String(clientVersion.buildNumber) &&
      JSON.stringify(buildManifest.abis) === JSON.stringify(["arm64-v8a"]) &&
      buildManifest.signerIdentityVerified === true &&
      buildManifest.signingPolicySatisfied === true &&
      buildManifest.artifact?.file === "app-release.apk" &&
      buildManifest.sourceStateDigest ===
        clientSourceStateDigest(workspaceRoot, clientSourceRoots),
    "Android APK build manifest is invalid",
  );
  const artifactPath = resolveContainedExistingPath(
    releaseRoot,
    path.join(releaseRoot, String(buildManifest.artifact?.file || "")),
    { expectedKind: "file" },
  );
  const facts = inspectAndroidApkFacts(workspaceRoot, artifactPath, {
    requireApprovedToolchain: true,
  });
  requireValue(
    facts.artifactDigest === buildManifest.artifact?.digest &&
      facts.packageName === buildManifest.packageName &&
      facts.versionCode === buildManifest.versionCode &&
      facts.versionName === buildManifest.versionName &&
      facts.debuggable === buildManifest.debuggable &&
      JSON.stringify(facts.abis) === JSON.stringify(buildManifest.abis) &&
      facts.launchableActivity === buildManifest.launchableActivity &&
      facts.signerCount === buildManifest.signerCount &&
      JSON.stringify(facts.signatureSchemes) ===
        JSON.stringify(buildManifest.signatureSchemes) &&
      facts.zipAligned === buildManifest.zipAligned &&
      JSON.stringify(facts.nativeSecureMeshLibrary) ===
        JSON.stringify(buildManifest.nativeSecureMeshLibrary),
    "Android APK facts do not match the build manifest",
  );
  const report = {
    schemaVersion: "licolite.client-android.distribution-manifest.v3",
    generatedAt: new Date().toISOString(),
    targetId: "android-arm64",
    platform: "android",
    architecture: "arm64",
    productVersion: buildManifest.productVersion,
    buildNumber: buildManifest.buildNumber,
    packageName: facts.packageName,
    versionCode: facts.versionCode,
    versionName: facts.versionName,
    debuggable: facts.debuggable,
    abis: facts.abis,
    launchableActivity: facts.launchableActivity,
    artifactDigest: facts.artifactDigest,
    signerCount: facts.signerCount,
    signatureSchemes: facts.signatureSchemes,
    zipAligned: facts.zipAligned,
    signerIdentityVerified: true,
    signingPolicySatisfied:
      facts.signerCount === 1 &&
      facts.signatureSchemes.some((scheme) => ["v2", "v3", "v4"].includes(scheme)) &&
      facts.zipAligned === true,
    nativeSecureMeshLibrary: facts.nativeSecureMeshLibrary,
    buildManifestDigest: sha256File(buildManifestPath),
    signingKind: "local-install-keystore",
    artifactReady: true,
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      publicDownloadStatus: "not-configured",
      updateChannelStatus: "not-configured",
      rollbackChannelStatus: "not-configured",
    },
    redacted: true,
  };
  atomicWriteReportJson(androidOutputRoot, "release/distribution-manifest.json", report);
  console.log(JSON.stringify({
    ok: true,
    targetId: report.targetId,
    artifactReady: true,
    privatePathsIncluded: false,
  }));
}

try {
  main();
} catch {
  console.error(JSON.stringify({
    ok: false,
    reason: "android_apk_verification_failed",
    privatePathsIncluded: false,
  }));
  process.exitCode = 1;
}
