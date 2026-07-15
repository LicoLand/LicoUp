#!/usr/bin/env node
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  clientAndroidProjectCacheRoot,
  seedClientGradleHome,
  withClientToolchainEnv
} from "../../../tools/scripts/client-toolchain-env.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "../../../tools/scripts/lib/client-source-state-digest.mjs";
import {
  androidApkReproduciblePayloadFacts,
  androidApkSignerIdentityKeyId,
  assertAndroidApkFactsEqual,
  assertAndroidApkPayloadFactsEqual,
  inspectAndroidApkFacts,
} from "../../../tools/scripts/lib/android-apk-facts.mjs";
import { stableSnapshotFile } from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import { atomicWriteReportJson } from "../../../tools/scripts/lib/safe-report-io.mjs";
import {
  ANDROID_RELEASE_BUILD_PARAMETERS,
  validateAndroidReleaseBuildRequest,
} from "../../../tools/scripts/lib/android-release-build-policy.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const flutterClientRoot = path.join(workspaceRoot, "apps", "desktop");
const outputRoot = path.join(workspaceRoot, "build", "apps", "desktop", "android");
const localFlutterBuildRoot = path.join(flutterClientRoot, "build");
const localAndroidBuildRoot = path.join(flutterClientRoot, "android", "build");
const clientSourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;

function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    mode: "debug",
    keepLocalBuild: defaultKeepLocalBuild(),
    passthrough: []
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--mode" && next) {
      options.mode = normalizeMode(next);
      index += 1;
    } else if (["--debug", "--profile", "--release"].includes(arg)) {
      options.mode = normalizeMode(arg.slice(2));
    } else if (arg === "--keep-local-build" || arg === "--keep-flutter-build-cache") {
      options.keepLocalBuild = true;
    } else if (arg === "--clean-local-build" || arg === "--clean-flutter-build-cache") {
      options.keepLocalBuild = false;
    } else {
      options.passthrough.push(arg);
    }
  }
  return options;
}

function defaultKeepLocalBuild() {
  if (process.env.LICO_CLEAN_FLUTTER_BUILD_CACHE === "1") {
    return false;
  }
  return process.env.LICO_KEEP_FLUTTER_BUILD_CACHE !== "0";
}

function normalizeMode(value) {
  const normalized = String(value || "").toLowerCase();
  if (["debug", "profile", "release"].includes(normalized)) {
    return normalized;
  }
  throw new Error(`Unsupported Android build mode: ${value}`);
}

function assertReleaseSigning(options) {
  if (options.mode !== "release") {
    return;
  }
  const required = [
    "LICO_ANDROID_KEYSTORE_PATH",
    "LICO_ANDROID_KEYSTORE_PASSWORD",
    "LICO_ANDROID_KEY_ALIAS",
    "LICO_ANDROID_KEY_PASSWORD"
  ];
  const missing = required.filter((name) => !String(process.env[name] || "").trim());
  if (missing.length > 0) {
    throw new Error(
      `Android release signing is required; missing protected CI environment fields: ${missing.join(", ")}`
    );
  }
  const keystorePath = String(process.env.LICO_ANDROID_KEYSTORE_PATH);
  if (!path.isAbsolute(keystorePath)) {
    throw new Error("Android release keystore path must be absolute.");
  }
  if (!existsSync(keystorePath)) {
    throw new Error("Android release keystore file is missing.");
  }
}

function hasOption(args, name) {
  return args.some((arg) => arg === name || arg.startsWith(`${name}=`));
}

function runFlutter(args, env) {
  execFileSync("flutter", args, {
    cwd: flutterClientRoot,
    stdio: "inherit",
    env
  });
}

function prepareFlutterDependencies(env) {
  try {
    runFlutter(["pub", "get", "--enforce-lockfile", "--offline"], env);
  } catch {
    throw new Error(
      "Flutter dependencies are missing from the local Pub cache. Run `npm run client:get` once, then retry the Android build."
    );
  }
}

function pruneAndroidDevOnlyPluginsForRelease(options) {
  if (options.mode === "debug") {
    return;
  }
  const pluginDependenciesPath = path.join(flutterClientRoot, ".flutter-plugins-dependencies");
  if (existsSync(pluginDependenciesPath)) {
    const parsed = JSON.parse(readFileSync(pluginDependenciesPath, "utf8"));
    const androidPlugins = Array.isArray(parsed.plugins?.android) ? parsed.plugins.android : [];
    const filteredAndroidPlugins = androidPlugins.filter((plugin) => !(
      plugin?.name === "integration_test" && plugin?.dev_dependency === true
    ));
    if (filteredAndroidPlugins.length !== androidPlugins.length) {
      parsed.plugins.android = filteredAndroidPlugins;
      writeFileSync(pluginDependenciesPath, `${JSON.stringify(parsed)}\n`, "utf8");
    }
  }
  const registrantPath = path.join(
    flutterClientRoot,
    "android",
    "app",
    "src",
    "main",
    "java",
    "io",
    "flutter",
    "plugins",
    "GeneratedPluginRegistrant.java"
  );
  if (!existsSync(registrantPath)) {
    return;
  }
  const source = readFileSync(registrantPath, "utf8");
  const pruned = source.replace(
    /\n    try \{\n      flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\n    \} catch \(Exception e\) \{\n      Log\.e\(TAG, "Error registering plugin integration_test, dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin", e\);\n    \}\n/u,
    "\n"
  );
  if (pruned !== source) {
    writeFileSync(registrantPath, pruned, "utf8");
  }
}

function runFlutterBuild(options, env) {
  const args = options.mode === "release"
    ? [
        "build",
        "apk",
        "--release",
        "--target-platform",
        ANDROID_RELEASE_BUILD_PARAMETERS.targetPlatform,
        "--target",
        ANDROID_RELEASE_BUILD_PARAMETERS.entrypoint,
      ]
    : ["build", "apk", `--${options.mode}`, ...options.passthrough];
  if (options.mode !== "release" && !hasOption(args, "--target-platform")) {
    args.push("--target-platform", "android-arm64");
  }
  if (!hasOption(args, "--android-project-cache-dir")) {
    const androidProjectCache = clientAndroidProjectCacheRoot();
    mkdirSync(androidProjectCache, { recursive: true });
    args.push("--android-project-cache-dir", androidProjectCache);
  }
  if (!hasOption(args, "--no-pub") && !hasOption(args, "--pub")) {
    args.push("--no-pub");
  }
  runFlutter(args, env);
}

function collectApks(directory, files = []) {
  if (!existsSync(directory)) {
    return files;
  }
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const child = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      collectApks(child, files);
    } else if (entry.isFile() && entry.name.endsWith(".apk")) {
      files.push(child);
    }
  }
  return files;
}

function clearInvocationOutputs(options) {
  for (const directory of [
    path.join(localFlutterBuildRoot, "app", "outputs", "flutter-apk"),
    path.join(localFlutterBuildRoot, "app", "outputs", "apk"),
    outputRoot
  ]) {
    rmSync(directory, { recursive: true, force: true });
  }
}

function inspectProducedApks(options) {
  const sourceRoots = [
    path.join(localFlutterBuildRoot, "app", "outputs", "flutter-apk"),
    path.join(localFlutterBuildRoot, "app", "outputs", "apk")
  ];
  const producedApks = [
    ...new Set(sourceRoots.flatMap((sourceRoot) => collectApks(sourceRoot)).map((apk) => path.resolve(apk)))
  ];
  if (producedApks.length === 0) {
    throw new Error("Android build did not produce a current-invocation APK.");
  }

  const producedFacts = producedApks.map((apk) => ({
    apk,
    facts: inspectAndroidApkFacts(workspaceRoot, apk, {
      requireApprovedToolchain: options.mode === "release",
    })
  }));
  const canonical = producedFacts.find(({ apk }) =>
    apk.includes(`${path.sep}outputs${path.sep}flutter-apk${path.sep}`)
  ) || producedFacts[0];
  for (const produced of producedFacts) {
    assertAndroidApkFactsEqual(canonical.facts, produced.facts);
  }
  return canonical;
}

function stageApks(options, sourceStateDigest, reproducibility = null) {
  const version = JSON.parse(
    readFileSync(path.join(workspaceRoot, "tools", "client-version.json"), "utf8")
  );
  const canonical = inspectProducedApks(options);
  const apkFacts = canonical.facts;
  const expectedDebuggable = options.mode === "debug";
  if (
    apkFacts.packageName !== "com.liko.arc" ||
    apkFacts.versionName !== version.productVersion ||
    apkFacts.versionCode !== String(version.buildNumber) ||
    apkFacts.debuggable !== expectedDebuggable ||
    JSON.stringify(apkFacts.abis) !== JSON.stringify(["arm64-v8a"])
  ) {
    throw new Error("Android APK binary manifest facts do not match the selected build.");
  }

  const outputDir = path.join(outputRoot, options.mode);
  mkdirSync(outputDir, { recursive: true });
  const artifactName = `app-${options.mode}.apk`;
  const target = stableSnapshotFile(canonical.apk, outputDir, artifactName);
  const stagedFacts = inspectAndroidApkFacts(workspaceRoot, target, {
    requireApprovedToolchain: options.mode === "release",
  });
  assertAndroidApkFactsEqual(apkFacts, stagedFacts);

  const manifestRef = `${options.mode}/build-manifest.json`;
  const manifest = {
      schemaVersion: "licolite.client-android.apk-build-manifest.v3",
      generatedAt: new Date().toISOString(),
      mode: options.mode,
      targetId: "android-arm64",
      buildParameters: options.mode === "release"
        ? { ...ANDROID_RELEASE_BUILD_PARAMETERS }
        : {
            flutterMode: options.mode,
            targetPlatform: "android-arm64",
            entrypoint: "lib/main.dart",
            splitPerAbi: false,
            obfuscate: false,
            pubResolution: "locked-offline-preflight",
          },
      sourceStateDigest,
      productVersion: version.productVersion,
      buildNumber: version.buildNumber,
      packageName: stagedFacts.packageName,
      versionCode: stagedFacts.versionCode,
      versionName: stagedFacts.versionName,
      debuggable: stagedFacts.debuggable,
      abis: stagedFacts.abis,
      launchableActivity: stagedFacts.launchableActivity,
      signingKind: options.mode === "release"
        ? "local-install-keystore"
        : "local-debug",
      signerCount: stagedFacts.signerCount,
      publicVerificationKeyId: androidApkSignerIdentityKeyId(stagedFacts),
      signatureSchemes: stagedFacts.signatureSchemes,
      zipAligned: stagedFacts.zipAligned,
      signerIdentityVerified: true,
      signingPolicySatisfied:
        stagedFacts.signerCount === 1 &&
        stagedFacts.signatureSchemes.some((scheme) =>
          ["v2", "v3", "v4"].includes(scheme),
        ) &&
        stagedFacts.zipAligned === true,
      nativeSecureMeshLibrary: stagedFacts.nativeSecureMeshLibrary,
      nonBlockingDistributionGuidance: {
        blocking: false,
        storeListingStatus: "not-configured",
        platformSigningStatus: "not-configured",
        publicDownloadStatus: "not-configured",
        updateChannelStatus: "not-configured",
        rollbackChannelStatus: "not-configured",
      },
      artifact: {
        file: artifactName,
        digest: stagedFacts.artifactDigest
      },
      reproducibility: options.mode === "release"
        ? {
            buildCount: 2,
            cleanBuilds: true,
            sameSourceState: reproducibility?.sourceStateDigest === sourceStateDigest,
            sameFinalArtifactDigest:
              reproducibility?.finalArtifactDigest === stagedFacts.artifactDigest,
            reproducibleUnsignedPayload:
              reproducibility?.reproducibleUnsignedPayload === true,
            stableSigningBlockSize:
              reproducibility?.stableSigningBlockSize === true,
            signingBlockVariationExpected:
              reproducibility?.signingBlockVariationExpected === true,
            binaryFactsEqual: reproducibility?.binaryFactsEqual === true,
            ready:
              reproducibility?.sourceStateDigest === sourceStateDigest &&
              reproducibility?.finalArtifactDigest === stagedFacts.artifactDigest &&
              reproducibility?.reproducibleUnsignedPayload === true &&
              reproducibility?.stableSigningBlockSize === true &&
              reproducibility?.binaryFactsEqual === true,
          }
        : {
            buildCount: 1,
            cleanBuilds: false,
            sameSourceState: true,
            sameFinalArtifactDigest: true,
            reproducibleUnsignedPayload: true,
            stableSigningBlockSize: true,
            signingBlockVariationExpected: false,
            binaryFactsEqual: true,
            ready: true,
          },
    };
  if (manifest.reproducibility.ready !== true) {
    throw new Error("Android release APK was not reproducible across two clean builds.");
  }
  atomicWriteReportJson(outputRoot, manifestRef, manifest);
  return { mode: options.mode, artifactCount: 1, manifestRef, manifest, facts: stagedFacts };
}

function cleanupLocalBuild(options, { force = false } = {}) {
  if (options.keepLocalBuild && !force) {
    return;
  }
  rmSync(localFlutterBuildRoot, { recursive: true, force: true });
  rmSync(localAndroidBuildRoot, { recursive: true, force: true });
}

function main() {
  const options = parseArgs();
  validateAndroidReleaseBuildRequest({
    mode: options.mode,
    passthrough: options.passthrough,
    targetPlatformEnvironment: process.env.LICO_ANDROID_TARGET_PLATFORM,
  });
  assertReleaseSigning(options);
  clearInvocationOutputs(options);
  cleanupLocalBuild(options);
  const env = withClientToolchainEnv();
  prepareFlutterDependencies(env);
  pruneAndroidDevOnlyPluginsForRelease(options);
  const sourceStateDigest = clientSourceStateDigest(workspaceRoot, clientSourceRoots);
  seedClientGradleHome(env, { log: (message) => console.log(message) });
  let reproducibility = null;
  let reproducibilityRoot = "";
  let result;
  try {
    runFlutterBuild(options, env);
    const sourceStateDigestAfterFirstBuild = clientSourceStateDigest(
      workspaceRoot,
      clientSourceRoots,
    );
    if (sourceStateDigestAfterFirstBuild !== sourceStateDigest) {
      throw new Error("Client source changed during the Android build; rebuild from a stable source state.");
    }
    if (options.mode === "release") {
      const first = inspectProducedApks(options);
      reproducibilityRoot = mkdtempSync(
        path.join(tmpdir(), "lico-android-reproducibility-"),
      );
      const firstSnapshot = stableSnapshotFile(
        first.apk,
        reproducibilityRoot,
        "first.apk",
      );
      const firstFacts = inspectAndroidApkFacts(workspaceRoot, firstSnapshot, {
        requireApprovedToolchain: true,
      });
      const firstPayloadFacts = androidApkReproduciblePayloadFacts(firstSnapshot);
      assertAndroidApkFactsEqual(first.facts, firstFacts);
      cleanupLocalBuild(options, { force: true });
      runFlutterBuild(options, env);
      const second = inspectProducedApks(options);
      const secondPayloadFacts = androidApkReproduciblePayloadFacts(second.apk);
      assertAndroidApkPayloadFactsEqual(firstFacts, second.facts);
      if (firstPayloadFacts.digest !== secondPayloadFacts.digest ||
        firstPayloadFacts.unsignedPayloadBytes !== secondPayloadFacts.unsignedPayloadBytes ||
        firstPayloadFacts.signingBlockSize !== secondPayloadFacts.signingBlockSize) {
        throw new Error("Android release APK unsigned payload was not reproducible.");
      }
      reproducibility = {
        sourceStateDigest,
        finalArtifactDigest: second.facts.artifactDigest,
        reproducibleUnsignedPayload: true,
        stableSigningBlockSize: true,
        signingBlockVariationExpected:
          firstFacts.artifactDigest !== second.facts.artifactDigest,
        binaryFactsEqual: true,
      };
    }
    const sourceStateDigestAfterBuild = clientSourceStateDigest(
      workspaceRoot,
      clientSourceRoots,
    );
    if (sourceStateDigestAfterBuild !== sourceStateDigest) {
      throw new Error("Client source changed during the Android build; rebuild from a stable source state.");
    }
    result = stageApks(options, sourceStateDigest, reproducibility);
  } finally {
    if (reproducibilityRoot) {
      rmSync(reproducibilityRoot, { recursive: true, force: true });
    }
    cleanupLocalBuild(options);
  }
  console.log(JSON.stringify({
    ok: true,
    mode: result.mode,
    targetId: result.manifest.targetId,
    artifactCount: result.artifactCount,
    buildManifest: result.manifestRef,
    privatePathsIncluded: false
  }));
}

try {
  main();
} catch (error) {
  console.error(JSON.stringify({
    ok: false,
    reason: "android_apk_build_failed",
    privatePathsIncluded: false
  }));
  process.exitCode = 1;
}
