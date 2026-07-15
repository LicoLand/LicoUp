#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import {
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
  stableReadFile,
  stableReadFileSnapshot,
} from "./lib/client-release-artifact-digest.mjs";
import {
  inspectBoundedMacosCodePolicy,
} from "./lib/macos-code-signature.mjs";
import {
  createReleaseClosureChallenge,
  createReleaseInvocationNonce,
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseClosureStartedAt,
  requiredReleaseInvocationNonce,
} from "./lib/release-closure-challenge.mjs";
import {
  atomicWriteReportJson,
  removeContainedReportIfExists,
} from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const verifier = "tools/scripts/client-secure-mesh-macos-capabilities.mjs";
const schemaVersion = "licolite.secure-mesh.macos-adaptive-capabilities-receipt.v3";
const reportRef = "build/reports/secure-mesh-macos-capabilities.json";
const builtAppRef = "build/apps/desktop/runnable/macos/release/Arc.app";
const builtApp = path.join(repoRoot, builtAppRef);
const installedApp = "/Applications/Arc.app";
const capabilityProofRef =
  "build/reports/secure-mesh-macos-keychain-user-presence-proof.json";
const packageManifestRef =
  "build/apps/desktop/runnable/macos/release/package-metadata/lico-client/packaging-modules.json";
const packageManifestPath = path.join(repoRoot, packageManifestRef);
const releaseEntitlementsRef = "apps/desktop/macos/Runner/Release.entitlements";
const releaseEntitlementsPath = path.join(repoRoot, releaseEntitlementsRef);
const clientVersionPath = path.join(repoRoot, "tools/client-version.json");
const sourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;
const sha256Pattern = /^sha256:[a-f0-9]{64}$/u;

function fail(code) {
  throw new Error(code);
}

function requireValue(condition, code) {
  if (!condition) fail(code);
}

function text(value) {
  return String(value || "").trim();
}

function readJsonStable(filePath) {
  return JSON.parse(stableReadFile(filePath, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function run(command, args, options = {}) {
  return spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
    timeout: 30_000,
    maxBuffer: 16 * 1024 * 1024,
    ...options,
  });
}

function requireSuccess(result, code) {
  requireValue(result.status === 0, code);
  return result;
}

function plistValue(appPath, key) {
  const result = run("/usr/libexec/PlistBuddy", [
    "-c",
    `Print :${key}`,
    path.join(appPath, "Contents/Info.plist"),
  ]);
  requireSuccess(result, "macos_bundle_plist_value_missing");
  return text(result.stdout);
}

function wait(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function parseProcessRecords(executablePath) {
  const escapedExecutable = executablePath.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const lookup = run("/usr/bin/pgrep", ["-f", `^${escapedExecutable}(?: |$)`], {
    timeout: 5_000,
  });
  if (lookup.status === 1) return [];
  requireSuccess(lookup, "macos_process_lookup_unavailable");
  const pids = [...new Set(String(lookup.stdout || "")
    .split(/\r?\n/u)
    .map((value) => Number(value.trim()))
    .filter((value) => Number.isInteger(value) && value > 0))]
    .slice(0, 64);
  const records = [];
  for (const pid of pids) {
    const result = run("/bin/ps", [
      "-ww",
      "-p",
      String(pid),
      "-o",
      "lstart=",
      "-o",
      "command=",
    ], { timeout: 5_000 });
    if (result.status !== 0) continue;
    const line = String(result.stdout || "").trim();
    const match = line.match(
      /^([A-Za-z]{3}\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+)$/u,
    );
    if (!match) continue;
    const command = match[2];
    if (command !== executablePath && !command.startsWith(`${executablePath} `)) continue;
    const startedAtMs = Date.parse(match[1]);
    if (!Number.isFinite(startedAtMs)) continue;
    records.push({
      pid,
      startedAtMs,
      command,
    });
  }
  return records;
}

function terminateExistingInstalledApp(executablePath) {
  const before = parseProcessRecords(executablePath);
  if (before.length === 0) return new Set();
  run("/usr/bin/osascript", [
    "-e",
    'tell application id "com.lico.client" to quit',
  ], { timeout: 5_000 });
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    if (parseProcessRecords(executablePath).length === 0) {
      return new Set(before.map((record) => record.pid));
    }
    wait(250);
  }
  fail("macos_previous_app_instance_did_not_terminate");
}

function launchInstalledApp({
  executablePath,
  challenge,
  invocationNonce,
  closureStartedAtMs,
}) {
  const oldPids = terminateExistingInstalledApp(executablePath);
  const invocationStartedAtMs = Date.now();
  const open = run("/usr/bin/open", [
    "-n",
    "-g",
    installedApp,
    "--args",
    "--lico-release-closure-challenge",
    challenge,
    "--lico-release-invocation-nonce",
    invocationNonce,
  ]);
  requireSuccess(open, "macos_installed_app_launch_failed");
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const record = parseProcessRecords(executablePath).find((candidate) =>
      !oldPids.has(candidate.pid) &&
      candidate.startedAtMs >= invocationStartedAtMs - 5_000 &&
      candidate.startedAtMs >= closureStartedAtMs - 5_000 &&
      candidate.command.includes(`--lico-release-closure-challenge ${challenge}`) &&
      candidate.command.includes(`--lico-release-invocation-nonce ${invocationNonce}`)
    );
    if (record) {
      const stableUntil = Date.now() + 2_000;
      while (Date.now() < stableUntil) {
        wait(250);
        const stillRunning = parseProcessRecords(executablePath).find((candidate) =>
          candidate.pid === record.pid &&
          candidate.startedAtMs === record.startedAtMs &&
          candidate.command === record.command
        );
        requireValue(stillRunning, "macos_launched_process_not_stable");
      }
      return Object.freeze({
        newProcessReady: true,
        startedAfterInvocation: true,
        executableWithinInstalledBundle: true,
        closureChallengeBound: true,
        invocationNonceBound: true,
        stableProcessWindowReady: true,
      });
    }
    wait(250);
  }
  fail("macos_launched_process_binding_not_observed");
}

function sidecarSmoke(appPath) {
  const sidecar = resolveContainedExistingPath(
    appPath,
    path.join(appPath, "Contents/MacOS/lico-client"),
    { expectedKind: "file" },
  );
  const result = run(sidecar, [
    "targets",
    "scan",
    "--include-accessible-environments",
    "false",
    "--include-history-model-catalog",
    "false",
  ]);
  if (result.status !== 0) return false;
  try {
    const decoded = JSON.parse(result.stdout);
    return decoded?.ok === true && Array.isArray(decoded.candidates);
  } catch {
    return false;
  }
}

function materializeCapabilityProof() {
  removeContainedReportIfExists(repoRoot, capabilityProofRef);
  const result = run(process.execPath, [
    "tools/scripts/client-secure-mesh-macos-keychain-user-presence-proof.mjs",
  ], { timeout: 90_000 });
  requireSuccess(result, "macos_exact_capability_proof_failed");
  const proofPath = resolveContainedExistingPath(
    repoRoot,
    path.join(repoRoot, capabilityProofRef),
    { expectedKind: "file" },
  );
  const snapshot = stableReadFileSnapshot(proofPath, {
    maxBytes: 16 * 1024 * 1024,
  });
  const report = JSON.parse(snapshot.bytes.toString("utf8"));
  requireValue(report?.ok === true && report?.redacted === true,
    "macos_exact_capability_proof_not_ready");
  return {
    report,
    digest: sha256Buffer(snapshot.bytes),
    dependency: {
      id: "macos-user-presence-proof",
      ref: capabilityProofRef,
      digest: sha256Buffer(snapshot.bytes),
    },
  };
}

function capabilityProofDependencyReady(dependency) {
  return dependency?.id === "macos-user-presence-proof" &&
    dependency?.ref === capabilityProofRef &&
    sha256Pattern.test(text(dependency?.digest));
}

function capabilityProofDependencyStable(dependency) {
  return capabilityProofDependencyStableAtRoot(repoRoot, dependency);
}

function capabilityProofDependencyStableAtRoot(root, dependency) {
  if (!capabilityProofDependencyReady(dependency)) return false;
  try {
    const proofPath = resolveContainedExistingPath(
      path.join(root, "build"),
      path.join(root, dependency.ref),
      { expectedKind: "file" },
    );
    return sha256File(proofPath, { maxBytes: 16 * 1024 * 1024 }) ===
      dependency.digest;
  } catch {
    return false;
  }
}

function containsPrivateValue(value) {
  if (typeof value === "string") {
    return (
      /(?:^|["'\s])\/(?:Users|home)\//u.test(value) ||
      /^[A-Za-z]:\\/u.test(value) ||
      /-----BEGIN [A-Z ]*PRIVATE KEY-----/u.test(value) ||
      /\b(?:password|passphrase|secret value|device serial)\s*[:=]/iu.test(value)
    );
  }
  if (Array.isArray(value)) return value.some(containsPrivateValue);
  if (value && typeof value === "object") {
    return Object.values(value).some(containsPrivateValue);
  }
  return false;
}

function artifactSecurityStateStable(before, after) {
  return before?.artifactDigest === after?.artifactDigest &&
    before?.signatureKind === after?.signatureKind &&
    before?.signatureVerified === true && after?.signatureVerified === true &&
    before?.hardenedRuntime === true && after?.hardenedRuntime === true &&
    before?.entitlementsMatch === true && after?.entitlementsMatch === true &&
    before?.entitlementsDigest === after?.entitlementsDigest &&
    before?.nestedCodeMinimalEntitlements === true &&
    after?.nestedCodeMinimalEntitlements === true;
}

function artifactSecurityState(artifactDigest, signature, nestedReady) {
  return Object.freeze({
    artifactDigest,
    signatureKind: signature.signatureKind,
    signatureVerified: signature.verified === true,
    hardenedRuntime: signature.hardenedRuntime === true,
    entitlementsMatch: signature.entitlementsMatch === true,
    entitlementsDigest: signature.entitlementsDigest,
    nestedCodeMinimalEntitlements: nestedReady === true,
  });
}

function nestedCodePolicyReady(policy) {
  return policy?.nestedSignatures?.length > 0 &&
    policy.nestedSignatures.every(({ signature: nestedSignature }) => {
    return nestedSignature.verified === true &&
      nestedSignature.signatureKind === "local-identity-codesign" &&
      nestedSignature.hardenedRuntime === true &&
      nestedSignature.entitlementsEmpty === true;
  });
}

function validateReport(report) {
  const receipt = report.receipts?.[0];
  const claims = report.distributionClaims || {};
  const digests = [
    report.sourceStateDigest,
    report.closureChallengeDigest,
    report.invocationNonceDigest,
    report.buildManifestDigest,
    report.capabilityProofDigest,
    report.dependencies?.[0]?.digest,
    receipt?.artifactDigest,
    receipt?.runtimeExecutableDigest,
    receipt?.signatureMetadataDigest,
    receipt?.entitlementsDigest,
  ];
  return (
    report.schemaVersion === schemaVersion &&
    report.verifier === verifier &&
    Number.isFinite(Date.parse(text(report.generatedAt))) &&
    report.platform === "macos" &&
    report.redacted === true &&
    report.reportLeakScan === true &&
    report.rawRuntimeOutputIncluded === false &&
    report.rawPrivateMaterialIncluded === false &&
    report.nonBlockingDistributionGuidance?.blocking === false &&
    Array.isArray(report.dependencies) && report.dependencies.length === 1 &&
    capabilityProofDependencyReady(report.dependencies[0]) &&
    digests.every((digest) => sha256Pattern.test(text(digest))) &&
    receipt?.targetId === "macos-arm64" &&
    receipt?.artifactKind === "macos-app-bundle" &&
    receipt?.signatureKind === "local-identity-codesign" &&
    receipt?.platformLocalSignatureReady === true &&
    receipt?.hardenedRuntime === true &&
    receipt?.nestedCodeMinimalEntitlements === true &&
    receipt?.entitlementsMatch === true &&
    receipt?.installedArtifactMatched === true &&
    receipt?.installReceiptReady === true &&
    receipt?.nonBlockingDistributionGuidance?.blocking === false &&
    receipt?.launchReady === true &&
    receipt?.newProcessReady === true &&
    receipt?.startedAfterInvocation === true &&
    receipt?.executableWithinInstalledBundle === true &&
    receipt?.closureChallengeBound === true &&
    receipt?.invocationNonceBound === true &&
    receipt?.stableProcessWindowReady === true &&
    receipt?.postLaunchArtifactStable === true &&
    receipt?.smokeReady === true &&
    receipt?.capabilityProofReady === true &&
    !containsPrivateValue(report)
  );
}

function selfTest() {
  const digest = `sha256:${"a".repeat(64)}`;
  const fixture = {
    schemaVersion,
    verifier,
    generatedAt: new Date().toISOString(),
    platform: "macos",
    redacted: true,
    reportLeakScan: true,
    rawRuntimeOutputIncluded: false,
    rawPrivateMaterialIncluded: false,
    sourceStateDigest: digest,
    closureChallengeDigest: digest,
    invocationNonceDigest: digest,
    buildManifestDigest: digest,
    capabilityProofDigest: digest,
    dependencies: [{
      id: "macos-user-presence-proof",
      ref: capabilityProofRef,
      digest,
    }],
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      notarizationStatus: "not-configured",
      updateChannelStatus: "not-configured",
    },
    receipts: [{
      targetId: "macos-arm64",
      artifactKind: "macos-app-bundle",
      artifactDigest: digest,
      runtimeExecutableDigest: digest,
      signatureMetadataDigest: digest,
      entitlementsDigest: digest,
      signatureKind: "local-identity-codesign",
      platformLocalSignatureReady: true,
      hardenedRuntime: true,
      nestedCodeMinimalEntitlements: true,
      entitlementsMatch: true,
      installedArtifactMatched: true,
      installReceiptReady: true,
      nonBlockingDistributionGuidance: {
        blocking: false,
        storeListingStatus: "not-configured",
        platformSigningStatus: "not-configured",
        notarizationStatus: "not-configured",
        updateChannelStatus: "not-configured",
      },
      launchReady: true,
      newProcessReady: true,
      startedAfterInvocation: true,
      executableWithinInstalledBundle: true,
      closureChallengeBound: true,
      invocationNonceBound: true,
      stableProcessWindowReady: true,
      postLaunchArtifactStable: true,
      smokeReady: true,
      capabilityProofReady: true,
    }],
  };
  requireValue(validateReport(fixture), "macos_receipt_positive_self_test_failed");
  for (const [name, mutate] of [
    ["ad_hoc_signature", (value) => {
      value.receipts[0].signatureKind = "local-ad-hoc-codesign";
    }],
    ["wrong_entitlements", (value) => {
      value.receipts[0].entitlementsMatch = false;
    }],
    ["missing_hardened_runtime", (value) => {
      value.receipts[0].hardenedRuntime = false;
    }],
    ["nested_entitlements_overgrant", (value) => {
      value.receipts[0].nestedCodeMinimalEntitlements = false;
    }],
    ["old_process", (value) => {
      value.receipts[0].newProcessReady = false;
    }],
    ["unstable_process", (value) => {
      value.receipts[0].stableProcessWindowReady = false;
    }],
    ["post_launch_swap", (value) => {
      value.receipts[0].postLaunchArtifactStable = false;
    }],
    ["wrong_executable", (value) => {
      value.receipts[0].executableWithinInstalledBundle = false;
    }],
    ["missing_challenge", (value) => {
      value.receipts[0].closureChallengeBound = false;
    }],
    ["blocking_distribution_guidance", (value) => {
      value.nonBlockingDistributionGuidance.blocking = true;
    }],
    ["capability_dependency_digest_missing", (value) => {
      value.dependencies[0].digest = "";
    }],
  ]) {
    const candidate = structuredClone(fixture);
    mutate(candidate);
    requireValue(!validateReport(candidate), `macos_self_test_accepted_${name}`);
  }
  const artifactState = {
    artifactDigest: digest,
    signatureKind: "local-identity-codesign",
    signatureVerified: true,
    hardenedRuntime: true,
    entitlementsMatch: true,
    entitlementsDigest: digest,
    nestedCodeMinimalEntitlements: true,
  };
  requireValue(artifactSecurityStateStable(artifactState, { ...artifactState }),
    "macos_stable_artifact_state_self_test_failed");
  requireValue(!artifactSecurityStateStable(artifactState, {
    ...artifactState,
    artifactDigest: `sha256:${"b".repeat(64)}`,
  }), "macos_during_launch_swap_self_test_failed");
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "lico-macos-proof-dependency-"));
  try {
    const dependencyPath = path.join(
      temporaryRoot,
      "build/reports/secure-mesh-macos-keychain-user-presence-proof.json",
    );
    mkdirSync(path.dirname(dependencyPath), { recursive: true, mode: 0o700 });
    writeFileSync(dependencyPath, "before", { mode: 0o600 });
    const dependency = {
      id: "macos-user-presence-proof",
      ref: capabilityProofRef,
      digest: sha256File(dependencyPath),
    };
    requireValue(capabilityProofDependencyStableAtRoot(temporaryRoot, dependency),
      "macos_capability_dependency_positive_self_test_failed");
    writeFileSync(dependencyPath, "after", { mode: 0o600 });
    requireValue(!capabilityProofDependencyStableAtRoot(temporaryRoot, dependency),
      "macos_capability_dependency_tamper_self_test_failed");
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
  console.log(JSON.stringify({ ok: true, mode: "self-test", caseCount: 15 }));
}

function main() {
  requireValue(process.platform === "darwin", "macos_platform_required");
  removeContainedReportIfExists(repoRoot, reportRef);
  const inheritedClosure = text(process.env.LICO_CLIENT_RELEASE_CLOSURE_CHALLENGE);
  const challenge = inheritedClosure
    ? requiredReleaseClosureChallenge()
    : createReleaseClosureChallenge();
  const invocationNonce = inheritedClosure
    ? requiredReleaseInvocationNonce()
    : createReleaseInvocationNonce();
  const closureStartedAt = inheritedClosure
    ? requiredReleaseClosureStartedAt()
    : { value: new Date().toISOString(), milliseconds: Date.now() };
  const closureChallengeDigest = releaseClosureChallengeDigest(challenge);
  const invocationNonceDigest = releaseInvocationNonceDigest(invocationNonce);
  const built = resolveContainedExistingPath(repoRoot, builtApp, {
    expectedKind: "directory",
  });
  const installed = resolveContainedExistingPath("/Applications", installedApp, {
    expectedKind: "directory",
  });
  const manifestPath = resolveContainedExistingPath(repoRoot, packageManifestPath, {
    expectedKind: "file",
  });
  const entitlementsPath = resolveContainedExistingPath(repoRoot, releaseEntitlementsPath, {
    expectedKind: "file",
  });
  const packageManifestSnapshot = stableReadFileSnapshot(manifestPath, {
    maxBytes: 2 * 1024 * 1024,
  });
  const packageManifest = JSON.parse(packageManifestSnapshot.bytes.toString("utf8"));
  requireValue(
    packageManifest?.platform === "macos" &&
      packageManifest?.mode === "release" &&
      packageManifest?.signing?.signingKind === "local-identity-codesign" &&
      packageManifest?.signing?.localInstallIdentity === true &&
      packageManifest?.signing?.entitlementsFile === releaseEntitlementsRef &&
      packageManifest?.signing?.entitlementProfile === "release" &&
      packageManifest?.signing?.productionEntitlementsRequested === false &&
      packageManifest?.signing?.nonBlockingDistributionGuidance?.blocking === false &&
      packageManifest?.signing?.hardenedRuntime === true &&
      packageManifest?.signing?.nestedCodeMinimalEntitlements === true,
    "macos_package_manifest_policy_mismatch",
  );
  const currentSourceStateDigest = clientSourceStateDigest(repoRoot, sourceRoots);
  requireValue(packageManifest.sourceStateDigest === currentSourceStateDigest,
    "macos_artifact_source_state_stale");
  const clientVersion = readJsonStable(clientVersionPath);
  requireValue(text(clientVersion.productVersion) &&
    Number.isInteger(clientVersion.buildNumber) && clientVersion.buildNumber > 0,
  "client_version_manifest_invalid");
  const signatureResources = resolveContainedExistingPath(
    built,
    path.join(built, "Contents/_CodeSignature/CodeResources"),
    { expectedKind: "file" },
  );
  const executableName = plistValue(installed, "CFBundleExecutable");
  const initialInspectionDeadlineMs = Date.now() + 240_000;
  const builtPolicy = inspectBoundedMacosCodePolicy(
    built,
    executableName,
    entitlementsPath,
    { deadlineMs: initialInspectionDeadlineMs },
  );
  const installedPolicy = inspectBoundedMacosCodePolicy(
    installed,
    executableName,
    entitlementsPath,
    { deadlineMs: initialInspectionDeadlineMs },
  );
  const builtDigest = builtPolicy.artifactDigest;
  const installedDigest = installedPolicy.artifactDigest;
  const nestedCodeMinimalEntitlements =
    builtPolicy.nestedCodePaths.length === installedPolicy.nestedCodePaths.length &&
    nestedCodePolicyReady(builtPolicy) && nestedCodePolicyReady(installedPolicy);
  const builtSignature = builtPolicy.signature;
  const installedSignature = installedPolicy.signature;
  const signaturesMatch = builtSignature.signatureKind === installedSignature.signatureKind &&
    builtSignature.entitlementsDigest === installedSignature.entitlementsDigest;
  const signatureKind = signaturesMatch ? builtSignature.signatureKind : "unknown";
  const entitlementsMatch = builtSignature.entitlementsMatch === true &&
    installedSignature.entitlementsMatch === true && signaturesMatch;
  const platformLocalSignatureReady = builtSignature.verified === true &&
    installedSignature.verified === true &&
    builtSignature.hardenedRuntime === true &&
    installedSignature.hardenedRuntime === true &&
    signatureKind === "local-identity-codesign" && entitlementsMatch &&
    nestedCodeMinimalEntitlements;
  const installedArtifactMatched = builtDigest === installedDigest;
  const installedExecutable = resolveContainedExistingPath(
    installed,
    path.join(installed, "Contents/MacOS", executableName),
    { expectedKind: "file" },
  );
  const launch = launchInstalledApp({
    executablePath: installedExecutable,
    challenge,
    invocationNonce,
    closureStartedAtMs: closureStartedAt.milliseconds,
  });
  const smokeReady = sidecarSmoke(installed);
  const capabilityProof = materializeCapabilityProof();
  const postInspectionDeadlineMs = Date.now() + 240_000;
  const builtPolicyAfter = inspectBoundedMacosCodePolicy(
    built,
    executableName,
    entitlementsPath,
    { deadlineMs: postInspectionDeadlineMs },
  );
  const installedPolicyAfter = inspectBoundedMacosCodePolicy(
    installed,
    executableName,
    entitlementsPath,
    { deadlineMs: postInspectionDeadlineMs },
  );
  const builtDigestAfter = builtPolicyAfter.artifactDigest;
  const installedDigestAfter = installedPolicyAfter.artifactDigest;
  const builtSignatureAfter = builtPolicyAfter.signature;
  const installedSignatureAfter = installedPolicyAfter.signature;
  const builtNestedPolicyAfter =
    builtPolicyAfter.nestedCodePaths.length === builtPolicy.nestedCodePaths.length &&
    nestedCodePolicyReady(builtPolicyAfter);
  const installedNestedPolicyAfter =
    installedPolicyAfter.nestedCodePaths.length === installedPolicy.nestedCodePaths.length &&
    nestedCodePolicyReady(installedPolicyAfter);
  const postLaunchArtifactStable =
    artifactSecurityStateStable(
      artifactSecurityState(builtDigest, builtSignature, nestedCodeMinimalEntitlements),
      artifactSecurityState(builtDigestAfter, builtSignatureAfter, builtNestedPolicyAfter),
    ) &&
    artifactSecurityStateStable(
      artifactSecurityState(installedDigest, installedSignature, nestedCodeMinimalEntitlements),
      artifactSecurityState(
        installedDigestAfter,
        installedSignatureAfter,
        installedNestedPolicyAfter,
      ),
    ) && builtDigestAfter === installedDigestAfter;
  requireValue(postLaunchArtifactStable, "macos_artifact_changed_during_launch");
  requireValue(clientSourceStateDigest(repoRoot, sourceRoots) === currentSourceStateDigest,
    "macos_source_changed_during_receipt");
  requireValue(sha256File(manifestPath) === sha256Buffer(packageManifestSnapshot.bytes),
    "macos_package_manifest_changed_during_receipt");
  requireValue(capabilityProofDependencyStable(capabilityProof.dependency),
    "macos_capability_child_proof_changed_during_receipt");
  const appVersion = plistValue(installed, "CFBundleShortVersionString");
  const appBuildNumber = plistValue(installed, "CFBundleVersion");
  const expectedAppVersion = text(clientVersion.productVersion).split("-", 1)[0];
  requireValue(appVersion === expectedAppVersion &&
    appBuildNumber === String(clientVersion.buildNumber),
  "macos_installed_version_mismatch");
  const signatureMetadataDigest = sha256Buffer(Buffer.from(canonicalJson({
    signingKind: signatureKind,
    entitlementProfile: packageManifest.signing.entitlementProfile,
    entitlementsDigest: installedSignature.entitlementsDigest,
    codeResourcesDigest: sha256File(signatureResources),
  }), "utf8"));
  const receipt = {
    targetId: process.arch === "arm64" ? "macos-arm64" : "macos-x64",
    productVersion: text(clientVersion.productVersion),
    buildNumber: clientVersion.buildNumber,
    appVersion,
    appBuildNumber,
    artifactKind: "macos-app-bundle",
    artifactDigest: builtDigest,
    runtimeExecutableDigest: sha256File(resolveContainedExistingPath(
      installed,
      path.join(installed, "Contents/MacOS/lico-client"),
      { expectedKind: "file" },
    ), { maxBytes: 512 * 1024 * 1024 }),
    signatureMetadataDigest,
    signatureKind,
    platformLocalSignatureReady,
    hardenedRuntime: builtSignature.hardenedRuntime === true &&
      installedSignature.hardenedRuntime === true,
    nestedCodeMinimalEntitlements,
    entitlementsMatch,
    entitlementsDigest: installedSignature.entitlementsDigest,
    installedArtifactMatched,
    installReceiptReady: platformLocalSignatureReady && installedArtifactMatched,
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      notarizationStatus: "not-configured",
      updateChannelStatus: "not-configured",
    },
    launchReady: Object.values(launch).every((value) => value === true),
    ...launch,
    postLaunchArtifactStable,
    smokeReady,
    capabilityProofReady: capabilityProof.report.ok === true,
  };
  const report = {
    schemaVersion,
    verifier,
    generatedAt: new Date().toISOString(),
    platform: "macos",
    redacted: true,
    reportLeakScan: true,
    rawRuntimeOutputIncluded: false,
    rawPrivateMaterialIncluded: false,
    sourceStateDigest: currentSourceStateDigest,
    closureChallengeDigest,
    invocationNonceDigest,
    buildManifestDigest: sha256Buffer(packageManifestSnapshot.bytes),
    capabilityProofDigest: capabilityProof.digest,
    dependencies: [capabilityProof.dependency],
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      notarizationStatus: "not-configured",
      updateChannelStatus: "not-configured",
    },
    receipts: [receipt],
  };
  report.ok = validateReport(report);
  atomicWriteReportJson(repoRoot, reportRef, report);
  console.log(JSON.stringify({
    ok: report.ok,
    platform: report.platform,
    signatureKind: receipt.signatureKind,
    platformLocalSignatureReady: receipt.platformLocalSignatureReady,
    installReceiptReady: receipt.installReceiptReady,
    launchReady: receipt.launchReady,
    smokeReady: receipt.smokeReady,
    capabilityProofReady: receipt.capabilityProofReady,
  }));
  if (!report.ok) process.exitCode = 1;
}

try {
  if (process.argv.slice(2).includes("--self-test")) selfTest();
  else main();
} catch {
  console.error(JSON.stringify({ ok: false, error: "macos_receipt_failed" }));
  process.exitCode = 1;
}
