#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";
import { findAndroidAdbTool } from "./lib/android-apk-facts.mjs";
import { stableReadFile } from "./lib/client-release-artifact-digest.mjs";
import { minimalReleaseToolEnvironment } from "./lib/release-tool-environment.mjs";
import {
  ANDROID_RELEASE_BUILD_PARAMETERS,
  androidReleaseBuildParametersReady,
  validateAndroidReleaseBuildRequest,
} from "./lib/android-release-build-policy.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const manifest = JSON.parse(stableReadFile(
  path.join(repoRoot, "tools/android-release-toolchain.json"),
  { maxBytes: 1024 * 1024 },
).toString("utf8"));
const workflow = stableReadFile(
  path.join(repoRoot, ".github/workflows/client-release.yml"),
  { maxBytes: 2 * 1024 * 1024 },
).toString("utf8");
const ciWorkflow = stableReadFile(
  path.join(repoRoot, ".github/workflows/client-ci.yml"),
  { maxBytes: 2 * 1024 * 1024 },
).toString("utf8");
const sourceVerify = stableReadFile(
  path.join(repoRoot, "tools/run-client-source-verify.mjs"),
  { maxBytes: 2 * 1024 * 1024 },
).toString("utf8");
const androidBuilder = stableReadFile(
  path.join(repoRoot, "apps/desktop/scripts/build-android-apk.mjs"),
  { maxBytes: 2 * 1024 * 1024 },
).toString("utf8");
const androidGradle = stableReadFile(
  path.join(repoRoot, "apps/desktop/android/app/build.gradle.kts"),
  { maxBytes: 2 * 1024 * 1024 },
).toString("utf8");
const androidManifest = stableReadFile(
  path.join(repoRoot, "apps/desktop/android/app/src/main/AndroidManifest.xml"),
  { maxBytes: 1024 * 1024 },
).toString("utf8");
const acceptanceIngress = stableReadFile(
  path.join(repoRoot,
    "apps/desktop/android/app/src/main/kotlin/com/liko/arc/ReleaseAcceptanceIngress.kt"),
  { maxBytes: 2 * 1024 * 1024 },
).toString("utf8");
const mainActivity = stableReadFile(
  path.join(repoRoot,
    "apps/desktop/android/app/src/main/kotlin/com/liko/arc/MainActivity.kt"),
  { maxBytes: 8 * 1024 * 1024 },
).toString("utf8");
const acceptanceBinding = stableReadFile(
  path.join(repoRoot, "tools/scripts/lib/android-release-acceptance-binding.mjs"),
  { maxBytes: 2 * 1024 * 1024 },
).toString("utf8");
const requiredDigests = [
  "adb",
  "aapt2",
  "apksigner",
  "apksignerJar",
  "zipalign",
  "java",
];
if (manifest.schemaVersion !== "licolite.android-release-toolchain-allowlist.v1" ||
  !manifest.platforms?.["darwin-arm64"] ||
  !requiredDigests.every((name) =>
    /^sha256:[a-f0-9]{64}$/u.test(
      String(manifest.platforms["darwin-arm64"].digests?.[name] || ""),
    ))) {
  throw new Error("Android release toolchain allowlist is incomplete");
}
const androidJob = workflow.split(/\n  android-arm64:/u)[1]?.split(/\n  publish:/u)[0] || "";
if (!androidJob.includes("runs-on: [self-hosted, macOS, ARM64, lico-release, android]") ||
  androidJob.includes("runs-on: ubuntu")) {
  throw new Error("Android release workflow is not pinned to an approved host class");
}
if (!androidJob.includes("LICO_CLIENT_RELEASE_TARGETS: android-arm64") ||
  !androidJob.includes("LICO_ANDROID_TARGET_PLATFORM: android-arm64") ||
  androidJob.indexOf("Build same-source macOS relay CLI prerequisite") < 0 ||
  androidJob.indexOf("Build same-source macOS relay CLI prerequisite") >
    androidJob.indexOf("Verify Android GitHub Release acceptance") ||
  !androidJob.includes("run: npm run client:verify:github-release")) {
  throw new Error("Android GitHub Release acceptance is not bound to same-source prerequisites");
}
const macosJob = workflow.split(/\n  macos:/u)[1]?.split(/\n  linux-arm64:/u)[0] || "";
const linuxJob = workflow.split(/\n  linux-arm64:/u)[1]?.split(/\n  android-arm64:/u)[0] || "";
const publishJob = workflow.split(/\n  publish:/u)[1] || "";
if (!macosJob.includes("LICO_CLIENT_RELEASE_TARGETS: macos-arm64") ||
  !macosJob.includes("Verify macOS GitHub Release acceptance") ||
  !macosJob.includes("run: npm run client:verify:github-release") ||
  !linuxJob.includes("LICO_CLIENT_RELEASE_TARGETS: linux-glibc-arm64") ||
  !linuxJob.includes("Verify Linux GitHub Release acceptance") ||
  !linuxJob.includes("run: npm run client:verify:github-release") ||
  workflow.includes("windows_x64:") ||
  workflow.includes("\n  windows-x64:")) {
  throw new Error("GitHub Release jobs are not bound to selected-target acceptance");
}
const uploadPolicyReady =
  workflow.includes("permissions:\n  contents: read") &&
  (workflow.match(/contents: write/gu) || []).length === 2 &&
  workflow.includes('gh release create "$RELEASE_TAG"') &&
  workflow.includes('gh release edit "$RELEASE_TAG"') &&
  (workflow.match(/gh release upload/gu) || []).length === 1 &&
  publishJob.includes("client-consumer-verification-manifest.mjs") &&
  publishJob.includes("LicoArc-consumer-verification.json") &&
  !publishJob.includes("build/release-assets/*") &&
  publishJob.includes("client-release-remote-asset-set.mjs") &&
  publishJob.includes(".assets | map({name, size, digest})") &&
  !macosJob.includes("GH_TOKEN:") &&
  !linuxJob.includes("GH_TOKEN:") &&
  !androidJob.includes("GH_TOKEN:") &&
  !workflow.includes("run: npm run client:verify\n") &&
  (workflow.match(/run: npm run client:verify:source/gu) || []).length === 3 &&
  workflow.includes("persist-credentials: false") &&
  !workflow.includes("--generate-notes") &&
  !workflow.includes("yes |") &&
  workflow.includes("Prepare ephemeral local integrity identity") &&
  !workflow.includes("LICO_MACOS_SIGNING_IDENTITY") &&
  !workflow.includes("LICO_MACOS_NOTARY_") &&
  androidJob.includes("build/apps/desktop/android/release/LicoArc-android-arm64.apk") &&
  androidJob.includes("build/apps/desktop/android/release/LicoArc-android-arm64.apk.sha256") &&
  androidJob.includes("build/apps/desktop/android/release/lico-github-artifact.pem") &&
  !androidJob.includes("build/apps/desktop/android/release/build-manifest.json") &&
  !/path:\s*build\/apps\/desktop\/android\/release\/\s*$/mu.test(androidJob) &&
  macosJob.indexOf("Prepare ephemeral local integrity identity") <
    macosJob.indexOf("run: npm run client:install:macos") &&
  macosJob.indexOf("run: npm run client:install:macos") <
    macosJob.indexOf("run: npm run client:archive:macos-github-release") &&
  macosJob.includes("build/apps/desktop/distribution/macos/LicoArc-macos-arm64.zip") &&
  macosJob.includes("build/apps/desktop/distribution/macos/LicoArc-macos-arm64.zip.sha256") &&
  !macosJob.includes("build/apps/desktop/runnable/macos/release/LicoArc-macos-arm64.zip") &&
  !/path:\s*build\/apps\/desktop\/runnable\/macos\/release\/\s*$/mu.test(macosJob) &&
  linuxJob.includes("build/apps/desktop/distribution/linux-arm64/LicoArc-linux-arm64.tar.gz") &&
  linuxJob.includes("build/apps/desktop/distribution/linux-arm64/LicoArc-linux-arm64.tar.gz.sha256") &&
  linuxJob.includes("build/apps/desktop/distribution/linux-arm64/LicoArc-linux-arm64.tar.gz.sig") &&
  linuxJob.includes("build/apps/desktop/distribution/linux-arm64/linux-release-verification-key.pem") &&
  !linuxJob.includes("build/apps/desktop/distribution/linux-arm64/manifest.json") &&
  !/path:\s*build\/apps\/desktop\/distribution\/linux-arm64\/\s*$/mu.test(linuxJob);
if (!uploadPolicyReady) {
  throw new Error("GitHub Release upload policy exposes more than consumer verification artifacts");
}
for (const forbidden of [
  "client:verify:secure-mesh-physical-device-matrix",
  "client:verify:secure-mesh-physical-evidence-manifest",
  "client:verify:secure-mesh-e2ee-evidence",
  "client:verify:product-line-security",
  "client:verify:android-physical-install-launch",
]) {
  if (sourceVerify.includes(forbidden)) {
    throw new Error("GitHub source gate consumes product-line or physical evidence");
  }
}
const pinnedCargoAudit = "cargo install cargo-audit --version 0.22.2 --locked";
if (!ciWorkflow.includes(pinnedCargoAudit) ||
  (workflow.match(/cargo install cargo-audit --version 0\.22\.2 --locked/gu) || [])
    .length !== 3) {
  throw new Error("Client CI release jobs do not install the pinned cargo-audit tool");
}
if (!androidBuilder.includes("path.isAbsolute(keystorePath)") ||
  !androidGradle.includes("releaseStoreFile?.isAbsolute == true") ||
  !androidGradle.includes("releaseStoreFile!!.canonicalFile")) {
  throw new Error("Android release signing path is not canonicalized fail-closed");
}
for (const request of [
  { mode: "release", passthrough: ["--target", "lib/alternate.dart"] },
  { mode: "release", passthrough: ["--unknown-release-switch"] },
  { mode: "release", targetPlatformEnvironment: "android-x64" },
]) {
  let rejected = false;
  try {
    validateAndroidReleaseBuildRequest(request);
  } catch {
    rejected = true;
  }
  if (!rejected) throw new Error("Android release accepted a noncanonical argument");
}
validateAndroidReleaseBuildRequest({
  mode: "release",
  passthrough: [],
  targetPlatformEnvironment: "android-arm64",
});
if (!androidReleaseBuildParametersReady({ ...ANDROID_RELEASE_BUILD_PARAMETERS }) ||
  !androidBuilder.includes("ANDROID_RELEASE_BUILD_PARAMETERS.entrypoint") ||
  !androidBuilder.includes("buildParameters: options.mode === \"release\"")) {
  throw new Error("Android canonical release parameters are not manifest-bound");
}
if (androidBuilder.indexOf("assertReleaseSigning(options);") >
  androidBuilder.indexOf("clearInvocationOutputs(options);")) {
  throw new Error("Android release signing preflight runs after output mutation");
}
const dependencyPreparationIndex = androidBuilder.indexOf("prepareFlutterDependencies(env);");
const pluginPruningIndex = androidBuilder.indexOf("pruneAndroidDevOnlyPluginsForRelease(options);");
const sourceDigestIndex = androidBuilder.indexOf(
  "const sourceStateDigest = clientSourceStateDigest(workspaceRoot, clientSourceRoots);",
);
const buildIndex = androidBuilder.indexOf("runFlutterBuild(options, env);");
if (dependencyPreparationIndex < 0 || pluginPruningIndex < dependencyPreparationIndex ||
  sourceDigestIndex < pluginPruningIndex || buildIndex < sourceDigestIndex) {
  throw new Error("Android source digest is not captured after build preparation");
}
if ((androidBuilder.match(/runFlutterBuild\(options, env\);/gu) || []).length !== 2 ||
  !androidBuilder.includes("cleanupLocalBuild(options, { force: true });") ||
  !androidBuilder.includes("assertAndroidApkPayloadFactsEqual(firstFacts, second.facts);") ||
  !androidBuilder.includes("firstPayloadFacts.digest !== secondPayloadFacts.digest") ||
  !androidBuilder.includes("reproducibility?.finalArtifactDigest === stagedFacts.artifactDigest") ||
  !androidBuilder.includes("reproducibility?.reproducibleUnsignedPayload === true") ||
  !androidBuilder.includes("buildCount: 2")) {
  throw new Error("Android release builder does not prove two clean same-source payload builds");
}
if (!androidManifest.includes('android:name=".ReleaseAcceptanceReceiver"') ||
  !androidManifest.includes('android:permission="android.permission.DUMP"') ||
  !acceptanceIngress.includes("class ReleaseAcceptanceReceiver : BroadcastReceiver()") ||
  !acceptanceIngress.includes('const val ACTION = "com.liko.arc.RELEASE_ACCEPTANCE"') ||
  !mainActivity.includes("?: consumeReleaseAcceptanceIngress()") ||
  !mainActivity.includes("pendingReleaseAcceptanceIntent = consumeReleaseAcceptanceIngress()") ||
  mainActivity.includes("handleSecureMeshAdbIntent(intent)") ||
  mainActivity.includes("consumeReleaseClosureChallenge(intent)") ||
  !acceptanceBinding.includes('"shell",\n    "am",\n    "broadcast"')) {
  throw new Error("Android release acceptance ingress is not shell-permission isolated");
}
const hostId = `${process.platform}-${process.arch}`;
if (manifest.platforms[hostId]) {
  findAndroidAdbTool(repoRoot, { requireApprovedToolchain: true });
}
const sanitizedEnvironment = minimalReleaseToolEnvironment({
  HOME: "/fixture-home",
  JAVA_TOOL_OPTIONS: "-javaagent:fixture",
  _JAVA_OPTIONS: "-javaagent:fixture",
  JDK_JAVA_OPTIONS: "-javaagent:fixture",
  DYLD_INSERT_LIBRARIES: "fixture",
  LD_PRELOAD: "fixture",
}, { JAVA_HOME: "/fixture-java", PATH: "/fixture-bin" });
if (sanitizedEnvironment.HOME !== "/fixture-home" ||
  sanitizedEnvironment.JAVA_HOME !== "/fixture-java" ||
  sanitizedEnvironment.PATH !== "/fixture-bin" ||
  [
    "JAVA_TOOL_OPTIONS",
    "_JAVA_OPTIONS",
    "JDK_JAVA_OPTIONS",
    "DYLD_INSERT_LIBRARIES",
    "LD_PRELOAD",
  ].some((name) => Object.hasOwn(sanitizedEnvironment, name))) {
  throw new Error("Android release tool environment is injectable");
}
console.log(JSON.stringify({
  ok: true,
  approvedHostClassCovered: true,
  explicitAndroidReleaseTargetSelected: true,
  sameSourceRelayCliPrerequisiteBound: true,
  pinnedCargoAuditInstalled: true,
  toolDigestAllowlistReady: true,
  environmentInjectionRejected: true,
  absoluteSigningPathRequired: true,
  signingPreflightBeforeOutputMutation: true,
  shellPermissionAcceptanceIngressRequired: true,
  unknownReleaseArgumentsRejected: true,
  externalEntrypointRejected: true,
  canonicalBuildParametersManifestBound: true,
  privatePathsIncluded: false,
}));
