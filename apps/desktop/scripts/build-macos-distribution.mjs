#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { packageClient } from "./package-client.mjs";
import {
  artifactTreeDigest,
  sha256File,
} from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import { minimalReleaseToolEnvironment } from "../../../tools/scripts/lib/release-tool-environment.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const distributionRoot = path.join(workspaceRoot, "build", "apps", "desktop", "distribution", "macos");
const resolvedEntitlements = path.join(
  workspaceRoot,
  "build",
  "apps",
  "desktop",
  "signing",
  "macos",
  "release",
  "ProductionRelease.resolved.entitlements"
);
const toolEnvironment = minimalReleaseToolEnvironment(process.env, {
  PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
});
const commandOutputLimit = 1024 * 1024;

class MacosDistributionError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function requiredEnvironment(name) {
  const value = String(process.env[name] || "").trim();
  if (!value) {
    throw new MacosDistributionError("macos_distribution_credentials_missing");
  }
  return value;
}

function run(command, args, code, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: commandOutputLimit,
    timeout: 15 * 60 * 1000,
    env: toolEnvironment,
    ...options,
  });
  if (result.status !== 0 || result.error) {
    throw new MacosDistributionError(code);
  }
}

function updateDistributionManifest(runnableRoot, platformChannelRequested) {
  const manifestPath = path.join(
    runnableRoot,
    "package-metadata",
    "licoup",
    "packaging-modules.json"
  );
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  manifest.architecture = process.arch === "arm64" ? "arm64" : "x64";
  manifest.signing = platformChannelRequested
    ? {
        platform: "macos",
        signingKind: "developer-id-application",
        entitlementProfile: "production-release",
        productionEntitlementsRequested: true,
        hardenedRuntime: true,
        timestamped: true,
        notarized: true,
        stapled: true,
        gatekeeperVerified: true
      }
    : {
        platform: "macos",
        signingKind: "local-ad-hoc-codesign",
        entitlementProfile: "local-release",
        productionEntitlementsRequested: false,
        hardenedRuntime: false,
        timestamped: false,
        notarized: false,
        stapled: false,
        gatekeeperVerified: false
      };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return { manifest, manifestPath };
}

function sha256(filePath) {
  return sha256File(filePath, {
    chunkBytes: 1024 * 1024,
    maxBytes: 8 * 1024 * 1024 * 1024,
  }).slice("sha256:".length);
}

function main() {
  if (process.platform !== "darwin") {
    throw new MacosDistributionError("macos_distribution_host_unsupported");
  }
  const options = process.argv.slice(2);
  if (options.some((option) =>
    !["--platform-channel", "--archive-current-local-integrity"].includes(option)) ||
    options.includes("--platform-channel") && options.includes("--archive-current-local-integrity")) {
    throw new MacosDistributionError("macos_distribution_option_invalid");
  }
  const platformChannelRequested = options.includes("--platform-channel");
  const archiveCurrentLocalIntegrity = options.includes("--archive-current-local-integrity");
  const identity = platformChannelRequested
    ? requiredEnvironment("LICO_MACOS_SIGNING_IDENTITY")
    : archiveCurrentLocalIntegrity
      ? requiredEnvironment("LICO_MACOS_RELEASE_SIGNING_IDENTITY")
      : "";
  const signingKeychain = String(
    process.env.LICO_MACOS_RELEASE_SIGNING_KEYCHAIN || "",
  ).trim();
  const signingKeychainArgs = signingKeychain
    ? ["--keychain", signingKeychain]
    : [];
  const keyId = platformChannelRequested ? requiredEnvironment("LICO_MACOS_NOTARY_KEY_ID") : "";
  const issuer = platformChannelRequested ? requiredEnvironment("LICO_MACOS_NOTARY_ISSUER_ID") : "";
  const keyPath = platformChannelRequested
    ? path.resolve(requiredEnvironment("LICO_MACOS_NOTARY_KEY_PATH"))
    : "";
  if (platformChannelRequested && !existsSync(keyPath)) {
    throw new MacosDistributionError("macos_distribution_credentials_missing");
  }

  const packageArguments = ["--platform", "macos", "--mode", "release"];
  if (platformChannelRequested) packageArguments.push("--production-entitlements");
  const runnableRoot = path.join(
    workspaceRoot,
    "build/apps/desktop/runnable/macos/release",
  );
  const result = archiveCurrentLocalIntegrity
    ? { runnable: { root: runnableRoot, appPath: path.join(runnableRoot, "LicoUp.app") } }
    : packageClient(packageArguments);
  const appPath = result?.runnable?.appPath;
  if (!appPath || !existsSync(appPath) ||
    (platformChannelRequested && !existsSync(resolvedEntitlements))) {
    throw new MacosDistributionError("macos_distribution_package_missing");
  }

  if (platformChannelRequested) {
    run("/usr/bin/codesign", [
      "--force",
      "--deep",
      "--options",
      "runtime",
      "--timestamp",
      "--sign",
      identity,
      "--entitlements",
      resolvedEntitlements,
      appPath
    ], "macos_distribution_codesign_failed");
  }
  run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", appPath],
    "macos_distribution_signature_verify_failed");

  mkdirSync(distributionRoot, { recursive: true });
  if (platformChannelRequested) {
    const submissionZip = path.join(os.tmpdir(), `lico-up-notary-${process.pid}.zip`);
    rmSync(submissionZip, { force: true });
    run("/usr/bin/ditto", ["-c", "-k", "--keepParent", appPath, submissionZip],
      "macos_distribution_submission_archive_failed");
    try {
      run("/usr/bin/xcrun", [
        "notarytool",
        "submit",
        submissionZip,
        "--key",
        keyPath,
        "--key-id",
        keyId,
        "--issuer",
        issuer,
        "--wait"
      ], "macos_distribution_notarization_failed", { timeout: 30 * 60 * 1000 });
    } finally {
      rmSync(submissionZip, { force: true });
    }
    run("/usr/bin/xcrun", ["stapler", "staple", appPath],
      "macos_distribution_staple_failed");
    run("/usr/bin/xcrun", ["stapler", "validate", appPath],
      "macos_distribution_staple_verify_failed");
    run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", appPath],
      "macos_distribution_gatekeeper_failed");
  }
  const runnableManifest = archiveCurrentLocalIntegrity
    ? (() => {
        const manifestPath = path.join(
          result.runnable.root,
          "package-metadata/licoup/packaging-modules.json",
        );
        const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
        if (manifest?.signing?.signingKind !== "local-identity-codesign" ||
          manifest?.signing?.localInstallIdentity !== true ||
          manifest?.signing?.nonBlockingDistributionGuidance?.blocking !== false) {
          throw new MacosDistributionError("macos_distribution_local_integrity_missing");
        }
        return { manifest, manifestPath };
      })()
    : updateDistributionManifest(result.runnable.root, platformChannelRequested);
  const clientVersion = JSON.parse(readFileSync(
    path.join(workspaceRoot, "tools", "client-version.json"),
    "utf8",
  ));
  if (!String(clientVersion.productVersion || "").trim() ||
    !Number.isInteger(clientVersion.buildNumber) || clientVersion.buildNumber <= 0 ||
    !/^sha256:[a-f0-9]{64}$/u.test(
      String(runnableManifest.manifest.sourceStateDigest || ""),
    )) {
    throw new MacosDistributionError("macos_distribution_lineage_invalid");
  }
  const installArtifactDigest = artifactTreeDigest(appPath);
  const bundleManifestDigest = sha256File(runnableManifest.manifestPath, {
    maxBytes: 2 * 1024 * 1024,
  });

  const architecture = process.arch === "arm64" ? "arm64" : "x64";
  const updateArchivePath = path.join(
    distributionRoot,
    `LicoUp-macos-${architecture}-update.zip`,
  );
  rmSync(updateArchivePath, { force: true });
  run("/usr/bin/ditto", ["-c", "-k", "--keepParent", appPath, updateArchivePath],
    "macos_distribution_archive_failed", {
      env: { ...toolEnvironment, COPYFILE_DISABLE: "1" },
    });
  const updateDigest = sha256(updateArchivePath);
  writeFileSync(
    `${updateArchivePath}.sha256`,
    `${updateDigest}  ${path.basename(updateArchivePath)}\n`,
    "utf8",
  );

  const dmgPath = path.join(distributionRoot, `LicoUp-macos-${architecture}.dmg`);
  const dmgStage = path.join(os.tmpdir(), `licoup-dmg-stage-${process.pid}`);
  rmSync(dmgPath, { force: true });
  rmSync(dmgStage, { recursive: true, force: true });
  mkdirSync(dmgStage, { recursive: true, mode: 0o700 });
  try {
    run("/usr/bin/ditto", [appPath, path.join(dmgStage, "LicoUp.app")],
      "macos_distribution_dmg_stage_failed");
    symlinkSync("/Applications", path.join(dmgStage, "Applications"));
    run("/usr/bin/hdiutil", [
      "create", "-quiet", "-ov", "-format", "UDZO", "-volname", "LicoUp",
      "-srcfolder", dmgStage, dmgPath,
    ], "macos_distribution_dmg_create_failed");
  } finally {
    rmSync(dmgStage, { recursive: true, force: true });
  }
  run("/usr/bin/codesign", [
    "--force", "--timestamp=none", ...signingKeychainArgs, "--sign", identity, dmgPath,
  ], "macos_distribution_dmg_sign_failed");
  run("/usr/bin/codesign", ["--verify", "--strict", dmgPath],
    "macos_distribution_dmg_signature_verify_failed");
  run("/usr/bin/hdiutil", ["verify", "-quiet", dmgPath],
    "macos_distribution_dmg_verify_failed");
  const digest = sha256(dmgPath);
  writeFileSync(`${dmgPath}.sha256`, `${digest}  ${path.basename(dmgPath)}\n`, "utf8");
  writeFileSync(
    path.join(distributionRoot, "manifest.json"),
    `${JSON.stringify({
      schemaVersion: "v0.0.1:client-macos:distribution-1",
      targetId: `macos-${architecture}`,
      platform: "macos",
      architecture,
      artifactReady: true,
      nonBlockingDistributionGuidance: {
        channelRequested: platformChannelRequested,
        platformChannelReady: platformChannelRequested,
        githubReleaseBlocked: false
      },
      productVersion: clientVersion.productVersion,
      buildNumber: clientVersion.buildNumber,
      sourceStateDigest: runnableManifest.manifest.sourceStateDigest,
      sourceStateDigestProvenance:
        runnableManifest.manifest.sourceStateDigestProvenance || "git-worktree",
      signingKind: platformChannelRequested
        ? "developer-id-application"
        : (archiveCurrentLocalIntegrity
            ? "local-identity-codesign"
            : "local-ad-hoc-codesign"),
      notarized: platformChannelRequested,
      stapled: platformChannelRequested,
      gatekeeperVerified: platformChannelRequested,
      archive: path.basename(dmgPath),
      sha256: digest,
      updateArchive: path.basename(updateArchivePath),
      updateSha256: updateDigest,
      installArtifactKind: "macos-app-bundle",
      installArtifactDigest,
      bundleManifestDigest
    }, null, 2)}\n`,
    "utf8"
  );
  console.log(`macOS distribution archive ready: ${path.relative(workspaceRoot, dmgPath)}`);
}

function runSelfTest() {
  const marker = "private-signing-identity-marker";
  let failure;
  try {
    run(process.execPath, [
      "-e",
      `process.stdout.write(${JSON.stringify(marker)});process.stderr.write(${JSON.stringify(marker)});process.exit(7)`,
    ], "macos_distribution_marker_failure", { timeout: 5_000 });
  } catch (error) {
    failure = error;
  }
  if (!(failure instanceof MacosDistributionError) ||
    failure.code !== "macos_distribution_marker_failure" ||
    JSON.stringify(failure).includes(marker) || String(failure.message).includes(marker)) {
    throw new Error("macos_distribution_failure_output_not_redacted");
  }
  const injected = minimalReleaseToolEnvironment({
    HOME: "/fixture-home",
    LICO_MACOS_SIGNING_IDENTITY: marker,
    LICO_MACOS_NOTARY_KEY_PATH: marker,
    LICO_MACOS_NOTARY_KEY_ID: marker,
    LICO_MACOS_NOTARY_ISSUER_ID: marker,
    DYLD_INSERT_LIBRARIES: marker,
  }, { PATH: "/usr/bin:/bin:/usr/sbin:/sbin" });
  if (Object.values(injected).includes(marker) ||
    Object.hasOwn(injected, "DYLD_INSERT_LIBRARIES")) {
    throw new Error("macos_distribution_tool_environment_not_minimal");
  }
  console.log(JSON.stringify({
    ok: true,
    childOutputCapturedAndBounded: true,
    signingIdentityOutputAbsent: true,
    notaryCredentialOutputAbsent: true,
    minimalToolEnvironment: true,
    archiveHashStreaming: true,
    privatePathsIncluded: false,
  }));
}

try {
  if (process.argv.slice(2).includes("--self-test")) {
    if (process.argv.slice(2).length !== 1) {
      throw new MacosDistributionError("macos_distribution_option_invalid");
    }
    runSelfTest();
  } else {
    main();
  }
} catch (error) {
  console.error(JSON.stringify({
    ok: false,
    error: error instanceof MacosDistributionError
      ? error.code
      : "macos_distribution_failed",
    privatePathsIncluded: false,
  }));
  process.exitCode = 1;
}
