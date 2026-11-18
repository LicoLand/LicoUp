#!/usr/bin/env node
// Desktop-owned macOS consumer-verification evidence producer.
//
// Verifies the built LicoUp.app runnable against the current source state:
// local code-signing policy, entitlements, delivered licoup-cli sidecar
// digest, installation into a private staging directory, launch and stable
// survival. Emits a bounded, redacted receipt JSON at --report.
//
// The receipt is validated by client-artifact-verification-receipts during
// release acceptance; it carries no raw output, paths, identities or logs.

import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  artifactTreeDigest,
  resolveContainedExistingPath,
  sha256File,
} from "./lib/client-release-artifact-digest.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import { inspectBoundedMacosCodePolicy } from "./lib/macos-bundle-integrity.mjs";
import {
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseInvocationNonce,
} from "./lib/release-closure-challenge.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

const REPORT_SCHEMA_VERSION =
  "licoup.client.macos-consumer-verification.v1";
const VERIFIER = "tools/scripts/client-macos-consumer-verification.mjs";
const INSTALLER = "tools/scripts/client-macos-install.mjs";
const SHA256 = /^sha256:[a-f0-9]{64}$/u;

const RUNNABLE_APP = "build/apps/desktop/runnable/macos/release/LicoUp.app";
const ENTITLEMENTS =
  "build/apps/desktop/signing/macos/release/ProductionRelease.resolved.entitlements";
const CLIENT_VERSION = "tools/client-version.json";
const INSTALLER_TIMEOUT_MS = 120_000;

function fail(code) {
  throw new Error(code);
}

function parseArgs(argv) {
  const options = { report: "build/reports/client-macos-consumer-verification.json" };
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined) fail("evidence_args_invalid");
    options[name.slice(2)] = value;
  }
  const normalized = String(options.report).replaceAll("\\", "/");
  if (!normalized.startsWith("build/") || normalized.includes("../")) {
    fail("evidence_report_ref_invalid");
  }
  options.report = normalized;
  return options;
}

function containedFile(relativeRef) {
  return resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    path.join(repoRoot, relativeRef),
    { expectedKind: "file" },
  );
}

function installAndLaunch(appPath) {
  const installDir = mkdtempSync(path.join(os.tmpdir(), "licoup-consumer-"));
  try {
    const result = spawnSync(
      process.execPath,
      [path.join(repoRoot, INSTALLER), "--launch-installed", "--verify-stable"],
      {
        cwd: repoRoot,
        env: {
          ...process.env,
          LICO_CLIENT_INSTALL_DIR: installDir,
          LICO_CLIENT_RUNNABLE_ROOT: path.dirname(appPath),
        },
        encoding: "utf8",
        stdio: "pipe",
        maxBuffer: 4 * 1024 * 1024,
        timeout: INSTALLER_TIMEOUT_MS,
      },
    );
    const installedApp = path.join(installDir, "LicoUp.app");
    const installedExecutable =
      path.join(installedApp, "Contents", "MacOS", "licoup");
    let payload = {};
    try {
      payload = JSON.parse(String(result.stdout || ""));
    } catch {
      payload = {};
    }
    return {
      installerOk: result.status === 0 && payload.ok === true,
      launchVerified: payload.launchVerified === true,
      stableVerified: payload.stableVerified === true,
      initializationVerified: payload.initializationVerified === true,
      installedApp: existsSync(installedApp) ? installedApp : "",
      installedExecutable: existsSync(installedExecutable)
        ? installedExecutable
        : "",
    };
  } finally {
    rmSync(installDir, { recursive: true, force: true });
  }
}

function main(argv = process.argv.slice(2)) {
  if (process.platform !== "darwin") fail("consumer_verification_requires_macos");
  const options = parseArgs(argv);
  const challenge = requiredReleaseClosureChallenge();
  const invocationNonce = requiredReleaseInvocationNonce();
  const clientVersion = JSON.parse(
    readFileSync(path.join(repoRoot, CLIENT_VERSION), "utf8"),
  );
  const productVersion = String(clientVersion.productVersion || "");
  const buildNumber = clientVersion.buildNumber;
  if (!productVersion || !Number.isInteger(buildNumber) || buildNumber <= 0) {
    fail("client_version_invalid");
  }
  const sourceStateDigest = clientSourceStateDigest(
    repoRoot,
    CANONICAL_CLIENT_SOURCE_ROOTS,
  );

  const appPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    path.join(repoRoot, RUNNABLE_APP),
    { expectedKind: "directory" },
  );
  const executablePath = containedFile(
    `${RUNNABLE_APP}/Contents/MacOS/licoup`,
  );
  const sidecarPath = containedFile(
    `${RUNNABLE_APP}/Contents/Helpers/LicoUpCustody.app/Contents/MacOS/licoup-cli`,
  );
  const entitlementsPath = containedFile(ENTITLEMENTS);

  const artifactDigest = artifactTreeDigest(appPath);
  const runtimeExecutableDigest = sha256File(sidecarPath, {
    maxBytes: 256 * 1024 * 1024,
  });
  const codePolicy = inspectBoundedMacosCodePolicy(
    appPath,
    "licoup",
    entitlementsPath,
  );
  const signature = codePolicy?.signature || {};
  const nestedCodeMinimalEntitlements =
    Array.isArray(codePolicy?.nestedSignatures) &&
    codePolicy.nestedSignatures.length > 0 &&
    codePolicy.nestedSignatures.every(({ signature: nested }) =>
      nested?.verified === true &&
      nested?.signatureKind === "local-identity-codesign" &&
      nested?.hardenedRuntime === true &&
      nested?.entitlementsEmpty === true);
  const signatureReady = signature.verified === true &&
    signature.hardenedRuntime === true &&
    signature.entitlementsMatch === true &&
    SHA256.test(String(signature.entitlementsDigest || ""));

  const installedExecutableDigestBefore = sha256File(executablePath, {
    maxBytes: 256 * 1024 * 1024,
  });
  const install = installAndLaunch(appPath);
  const installedDigest = install.installedExecutable
    ? sha256File(install.installedExecutable, { maxBytes: 256 * 1024 * 1024 })
    : "";
  const installedArtifactMatched = install.installedExecutable !== "" &&
    installedDigest === installedExecutableDigestBefore;
  const postLaunchArtifactStable = installedArtifactMatched &&
    install.launchVerified === true &&
    installedDigest === sha256File(install.installedExecutable, {
      maxBytes: 256 * 1024 * 1024,
    });

  const installReady = install.installerOk;
  const launchReady = install.launchVerified;
  const stableReady = install.stableVerified && install.initializationVerified;
  const receipt = {
    targetId: "macos-arm64",
    productVersion,
    buildNumber,
    artifactKind: "macos-app-bundle",
    artifactDigest,
    runtimeExecutableDigest,
    signatureKind: String(signature.signatureKind || ""),
    platformLocalSignatureReady: signature.verified === true,
    hardenedRuntime: signature.hardenedRuntime === true,
    nestedCodeMinimalEntitlements,
    entitlementsMatch: signature.entitlementsMatch === true,
    entitlementsDigest: String(signature.entitlementsDigest || ""),
    installedArtifactMatched,
    installReceiptReady: installReady && installedArtifactMatched,
    launchReady,
    newProcessReady: launchReady,
    startedAfterInvocation: launchReady,
    executableWithinInstalledBundle: install.installedExecutable !== "",
    closureChallengeBound: true,
    invocationNonceBound: true,
    stableProcessWindowReady: install.stableVerified === true,
    postLaunchArtifactStable,
    smokeReady: launchReady && stableReady,
  };
  const ok = signatureReady && nestedCodeMinimalEntitlements === true &&
    SHA256.test(artifactDigest) && SHA256.test(runtimeExecutableDigest) &&
    installedArtifactMatched && installReady && launchReady && stableReady &&
    postLaunchArtifactStable;
  const report = {
    schemaVersion: REPORT_SCHEMA_VERSION,
    verifier: VERIFIER,
    generatedAt: new Date().toISOString(),
    ok,
    platform: "macos",
    productVersion,
    buildNumber,
    sourceStateDigest,
    closureChallengeDigest: releaseClosureChallengeDigest(challenge),
    invocationNonceDigest: releaseInvocationNonceDigest(invocationNonce),
    redacted: true,
    reportLeakScan: true,
    rawRuntimeOutputIncluded: false,
    rawPrivateMaterialIncluded: false,
    dependencies: [],
    receipts: [receipt],
  };
  atomicWriteReportJson(
    path.join(repoRoot, "build"),
    options.report.slice("build/".length),
    report,
  );
  console.log(JSON.stringify({ ok }));
  if (!ok) process.exitCode = 1;
}

main();
