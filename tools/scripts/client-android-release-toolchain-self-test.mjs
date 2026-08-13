#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";
import { validateClientGateTopology } from "./client-gate.mjs";
import {
  CLIENT_GATE_LANES,
  CLIENT_RELEASE_TARGETS,
} from "./client-gate-policy.mjs";
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
const publisher = stableReadFile(
  path.join(repoRoot, "tools/scripts/client-github-release-publish.mjs"),
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
const androidDebugManifest = stableReadFile(
  path.join(repoRoot, "apps/desktop/android/app/src/debug/AndroidManifest.xml"),
  { maxBytes: 1024 * 1024 },
).toString("utf8");
const acceptanceIngress = stableReadFile(
  path.join(repoRoot,
    "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/ReleaseAcceptanceIngress.kt"),
  { maxBytes: 2 * 1024 * 1024 },
).toString("utf8");
const mainActivity = stableReadFile(
  path.join(repoRoot,
    "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/MainActivity.kt"),
  { maxBytes: 8 * 1024 * 1024 },
).toString("utf8");
const backupRules = stableReadFile(
  path.join(repoRoot, "apps/desktop/android/app/src/main/res/xml/backup_rules.xml"),
  { maxBytes: 1024 * 1024 },
).toString("utf8");
const legacyBackupRules = stableReadFile(
  path.join(repoRoot, "apps/desktop/android/app/src/main/res/xml/backup_rules_legacy.xml"),
  { maxBytes: 1024 * 1024 },
).toString("utf8");
const acceptanceBinding = stableReadFile(
  path.join(repoRoot, "tools/scripts/lib/android-release-acceptance-binding.mjs"),
  { maxBytes: 2 * 1024 * 1024 },
).toString("utf8");

function jobBlock(source, jobId) {
  const match = new RegExp(`^  ${jobId}:\\s*$`, "mu").exec(source);
  if (!match) throw new Error(`workflow job is missing: ${jobId}`);
  const remainder = source.slice(match.index + match[0].length);
  const next = remainder.search(/\n  [a-z0-9][a-z0-9-]*:\s*(?:\n|$)/u);
  return next < 0
    ? source.slice(match.index)
    : source.slice(match.index, match.index + match[0].length + next);
}
const requiredDigests = [
  "adb",
  "aapt2",
  "apksigner",
  "apksignerJar",
  "zipalign",
  "java",
];
if (manifest.schemaVersion !== "licomesh.android-release-toolchain-allowlist.v1" ||
  !manifest.platforms?.["darwin-arm64"] ||
  !requiredDigests.every((name) =>
    /^sha256:[a-f0-9]{64}$/u.test(
      String(manifest.platforms["darwin-arm64"].digests?.[name] || ""),
    ))) {
  throw new Error("Android release toolchain allowlist is incomplete");
}
validateClientGateTopology();
const prepareJob = jobBlock(workflow, "prepare");
const publishJob = jobBlock(workflow, "publish");
if (!workflow.includes("One or more comma-separated exact package targets") ||
  !workflow.includes("client-release-workflow-binding.mjs") ||
  !workflow.includes("--mode matrix --targets \"$TARGETS\"") ||
  prepareJob.includes("LICO_CLIENT_RELEASE_TARGETS:") ||
  !prepareJob.includes("matrix.target == 'android-direct-arm64-v8a'") ||
  !prepareJob.includes("client:release:build -- --target \"$TARGET\"") ||
  !prepareJob.includes("client:release:verify -- --target \"$TARGET\"") ||
  !publishJob.includes("--targets \"${{ inputs.targets }}\"") ||
  !publishJob.includes("Publish selected package set")) {
  throw new Error("GitHub Release workflow is not bound to exact one-or-many package targets");
}
const uploadPolicyReady =
  workflow.includes("permissions:\n  contents: read") &&
  (workflow.match(/contents: write/gu) || []).length === 1 &&
  publisher.includes('"release",\n      "create"') &&
  publisher.includes('"release", "edit"') &&
  publisher.includes('"release",\n      "upload"') &&
  publisher.includes("client-consumer-verification-manifest.mjs") &&
  publisher.includes("LicoUp-consumer-verification.json") &&
  publisher.includes("client-release-remote-asset-set.mjs") &&
  publisher.includes(".assets | map({name, size, digest})") &&
  publisher.includes("COPYFILE_EXCL") &&
  publishJob.includes("client-github-release-publish.mjs") &&
  publishJob.includes("persist-credentials: false") &&
  !prepareJob.includes("GH_TOKEN:") &&
  !workflow.includes("npm run client:gate:") &&
  !workflow.includes("--generate-notes") &&
  !workflow.includes("yes |") &&
  !workflow.includes("Import stable LicoUp Release identity") &&
  !workflow.includes("Materialize governed macOS platform-channel inputs") &&
  !workflow.includes("LICO_MACOS_RELEASE_CERTIFICATE_P12") &&
  !workflow.includes("LICO_MACOS_PROVISIONING_PROFILE_BASE64") &&
  !workflow.includes("LICO_MACOS_NOTARY_KEY_BASE64") &&
  !workflow.includes("licoup-notary-key.p8") &&
  prepareJob.includes("build/releases/${{ needs.source.outputs.version }}/${{ matrix.target }}/*");
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
  if (CLIENT_GATE_LANES.source.includes(forbidden)) {
    throw new Error("GitHub source gate consumes product-line or physical evidence");
  }
}
const pinnedCargoAudit = "cargo install cargo-audit --version 0.22.2 --locked";
const ciSourceJob = jobBlock(ciWorkflow, "source");
const ciDependencyJob = jobBlock(ciWorkflow, "dependencies");
if (
  ciSourceJob.includes(pinnedCargoAudit) ||
  !ciDependencyJob.includes(pinnedCargoAudit) ||
  workflow.includes(pinnedCargoAudit) ||
  prepareJob.includes(pinnedCargoAudit)
) {
  throw new Error("Pinned cargo-audit must remain isolated to dependency policy jobs");
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
if (androidManifest.includes("ReleaseAcceptanceReceiver") ||
  androidManifest.includes("land.lico.licoup.RELEASE_ACCEPTANCE") ||
  !androidManifest.includes('android:allowBackup="false"') ||
  !androidManifest.includes('android:dataExtractionRules="@xml/backup_rules"') ||
  !androidManifest.includes('android:fullBackupContent="@xml/backup_rules_legacy"') ||
  !backupRules.includes("<cloud-backup>") ||
  !backupRules.includes("<device-transfer>") ||
  !backupRules.includes('<exclude domain="device_root" path="." />') ||
  !legacyBackupRules.includes('<exclude domain="root" path="." />') ||
  !androidDebugManifest.includes('android:name=".ReleaseAcceptanceReceiver"') ||
  !androidDebugManifest.includes('android:permission="android.permission.DUMP"') ||
  !acceptanceIngress.includes("class ReleaseAcceptanceReceiver : BroadcastReceiver()") ||
  !acceptanceIngress.includes('const val ACTION = "land.lico.licoup.RELEASE_ACCEPTANCE"') ||
  mainActivity.includes("ReleaseAcceptance") ||
  !mainActivity.includes("onLocalVerificationCreate()") ||
  !androidGradle.includes("verifyReleaseAcceptanceIsolation") ||
  !androidGradle.includes('dependsOn("processReleaseMainManifest", "compileReleaseKotlin")') ||
  !androidGradle.includes('it.extension == "class"') ||
  !acceptanceBinding.includes('"shell",\n    "am",\n    "broadcast"')) {
  throw new Error("Android debug acceptance ingress is not isolated from release artifacts");
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
  oneOrManyExactPackageTargetsReady: true,
  pinnedDependencyAuditIsolated: true,
  toolDigestAllowlistReady: true,
  environmentInjectionRejected: true,
  absoluteSigningPathRequired: true,
  signingPreflightBeforeOutputMutation: true,
  debugAcceptanceIngressReleaseIsolationReady: true,
  unknownReleaseArgumentsRejected: true,
  externalEntrypointRejected: true,
  canonicalBuildParametersManifestBound: true,
  privatePathsIncluded: false,
}));
