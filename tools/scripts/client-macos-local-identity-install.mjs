#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  existsSync,
  renameSync,
  rmSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  resolveContainedExistingPath,
  sha256File,
  stableReadFile,
} from "./lib/client-release-artifact-digest.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import {
  inspectBoundedMacosCodePolicy,
  listMacosNestedCodePaths,
} from "./lib/macos-code-signature.mjs";
import {
  atomicWriteReportJson,
  removeContainedReportIfExists,
} from "./lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const producer = "tools/scripts/client-macos-local-identity-install.mjs";
const schemaVersion = "licomesh.client-macos-local-identity-install.v1";
const builtApp = path.join(repoRoot, "build/apps/desktop/runnable/macos/release/LicoUp.app");
const installedApp = "/Applications/LicoUp.app";
const packageManifestPath = path.join(
  repoRoot,
  "build/apps/desktop/runnable/macos/release/package-metadata/licoup/packaging-modules.json",
);
const reportRef = "build/reports/client-macos-local-identity-install.json";
const reportPath = path.join(repoRoot, reportRef);
const releaseEntitlementsRef = "apps/desktop/macos/Runner/Release.entitlements";
const sourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;
const digestPattern = /^sha256:[a-f0-9]{64}$/u;
const canonicalPackagingConfigDigest = sha256File(path.join(
  repoRoot,
  "apps/desktop/packaging.modules.json",
), { maxBytes: 2 * 1024 * 1024 });

function requireValue(condition, reason) {
  if (!condition) throw new Error(reason);
}

function run(command, args, timeout = 120_000) {
  return spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: 16 * 1024 * 1024,
    timeout,
  });
}

function plistValue(appPath, key) {
  const result = run("/usr/libexec/PlistBuddy", [
    "-c",
    `Print :${key}`,
    path.join(appPath, "Contents/Info.plist"),
  ]);
  requireValue(result.status === 0, "macos_bundle_plist_value_missing");
  return String(result.stdout || "").trim();
}

function boundedNestedCodePolicyReady(policy) {
  return policy?.nestedSignatures?.length > 0 &&
    policy.nestedSignatures.every(({ signature }) => {
    return signature.verified === true &&
      signature.signatureKind === "local-identity-codesign" &&
      signature.hardenedRuntime === true &&
      signature.entitlementsEmpty === true;
  });
}

function remainingDeadlineTimeout(deadlineMs) {
  const remaining = Math.floor(deadlineMs - Date.now());
  requireValue(remaining > 0, "macos_identity_signing_deadline_exceeded");
  return Math.min(120_000, remaining);
}

function identityManifest(manifest) {
  return {
    ...manifest,
    signing: {
      platform: "macos",
      signingKind: "local-identity-codesign",
      entitlementsFile: releaseEntitlementsRef,
      entitlementProfile: "release",
      productionEntitlementsRequested: false,
      localInstallIdentity: true,
      timestamped: false,
      nonBlockingDistributionGuidance: {
        blocking: false,
        storeListingStatus: "not-configured",
        platformSigningStatus: "not-configured",
        notarizationStatus: "not-configured",
        updateChannelStatus: "not-configured",
      },
      hardenedRuntime: true,
      nestedCodeMinimalEntitlements: true,
    },
  };
}

function validateIdentityManifest(manifest, sourceStateDigest) {
  const signing = manifest?.signing || {};
  return manifest?.schemaVersion === "v0.0.1:client-desktop:bundle-manifest-2" &&
    manifest?.platform === "macos" && manifest?.mode === "release" &&
    manifest?.sourceStateDigest === sourceStateDigest &&
    manifest?.configPath === "apps/desktop/packaging.modules.json" &&
    manifest?.packagingConfigDigest === canonicalPackagingConfigDigest &&
    signing.platform === "macos" &&
    signing.signingKind === "local-identity-codesign" &&
    signing.entitlementsFile === releaseEntitlementsRef &&
    signing.entitlementProfile === "release" &&
    signing.localInstallIdentity === true &&
    signing.productionEntitlementsRequested === false &&
    signing.timestamped === false &&
    signing.nonBlockingDistributionGuidance?.blocking === false &&
    signing.hardenedRuntime === true &&
    signing.nestedCodeMinimalEntitlements === true;
}

function validateInputPackageManifest(manifest, sourceStateDigest) {
  const signing = manifest?.signing || {};
  return manifest?.schemaVersion === "v0.0.1:client-desktop:bundle-manifest-2" &&
    manifest?.platform === "macos" && manifest?.mode === "release" &&
    manifest?.sourceStateDigest === sourceStateDigest &&
    manifest?.configPath === "apps/desktop/packaging.modules.json" &&
    manifest?.packagingConfigDigest === canonicalPackagingConfigDigest &&
    signing.signingKind === "local-ad-hoc-codesign" &&
    signing.entitlementsFile === releaseEntitlementsRef &&
    signing.entitlementProfile === "release" &&
    signing.productionEntitlementsRequested === false;
}

function replaceInstalledAppWithRollback({
  stagedPath,
  installedPath,
  backupPath,
  operations,
}) {
  const hadExistingInstall = operations.exists(installedPath);
  requireValue(!operations.exists(backupPath), "macos_local_install_backup_collision");
  if (hadExistingInstall) {
    operations.rename(installedPath, backupPath);
  }
  try {
    operations.rename(stagedPath, installedPath);
    requireValue(operations.verify(installedPath), "macos_installed_identity_verification_failed");
  } catch (error) {
    operations.remove(installedPath);
    if (hadExistingInstall && operations.exists(backupPath)) {
      operations.rename(backupPath, installedPath);
    }
    throw error;
  }
  operations.remove(backupPath);
}

function validateReport(report) {
  return report?.schemaVersion === schemaVersion && report?.generatedBy === producer &&
    report?.targetId === "macos-arm64" && report?.artifactKind === "macos-app-bundle" &&
    digestPattern.test(String(report.sourceStateDigest || "")) &&
    digestPattern.test(String(report.artifactDigest || "")) &&
    report.signatureKind === "local-identity-codesign" &&
    report.platformLocalSignatureReady === true && report.entitlementsMatch === true &&
    digestPattern.test(String(report.entitlementsDigest || "")) &&
    report.hardenedRuntime === true &&
    report.nestedCodeMinimalEntitlements === true &&
    report.installReady === true &&
    report.nonBlockingDistributionGuidance?.blocking === false &&
    report.privacy?.redacted === true &&
    report.privacy?.absolutePathsIncluded === false &&
    report.privacy?.signingIdentityIncluded === false &&
    report.privacy?.keyMaterialIncluded === false &&
    report.privacy?.rawLogsIncluded === false;
}

function selfTest() {
  const digest = `sha256:${"a".repeat(64)}`;
  const baseManifest = {
    schemaVersion: "v0.0.1:client-desktop:bundle-manifest-2",
    platform: "macos",
    mode: "release",
    sourceStateDigest: digest,
    configPath: "apps/desktop/packaging.modules.json",
    packagingConfigDigest: canonicalPackagingConfigDigest,
    signing: {
      signingKind: "local-ad-hoc-codesign",
      entitlementsFile: "apps/desktop/macos/Runner/Release.entitlements",
      entitlementProfile: "release",
      productionEntitlementsRequested: false,
    },
  };
  const finalized = identityManifest(baseManifest);
  requireValue(validateIdentityManifest(finalized, digest), "identity_manifest_self_test_failed");
  requireValue(!validateIdentityManifest({
    ...finalized,
    signing: { ...finalized.signing, signingKind: "local-ad-hoc-codesign" },
  }, digest), "adhoc_manifest_self_test_failed");
  requireValue(validateInputPackageManifest(baseManifest, digest),
    "release_entitlements_self_test_failed");
  requireValue(!validateInputPackageManifest({
    ...baseManifest,
    signing: {
      ...baseManifest.signing,
      entitlementsFile: "apps/desktop/macos/Runner/ProductionRelease.entitlements",
      entitlementProfile: "production-release",
      productionEntitlementsRequested: true,
    },
  }, digest),
  "production_entitlements_self_test_failed");
  const receipt = {
    schemaVersion,
    generatedBy: producer,
    targetId: "macos-arm64",
    artifactKind: "macos-app-bundle",
    sourceStateDigest: digest,
    artifactDigest: digest,
    signatureKind: "local-identity-codesign",
    platformLocalSignatureReady: true,
    entitlementsMatch: true,
    entitlementsDigest: digest,
    hardenedRuntime: true,
    nestedCodeMinimalEntitlements: true,
    installReady: true,
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      notarizationStatus: "not-configured",
      updateChannelStatus: "not-configured",
    },
    privacy: {
      redacted: true,
      absolutePathsIncluded: false,
      signingIdentityIncluded: false,
      keyMaterialIncluded: false,
      rawLogsIncluded: false,
    },
  };
  requireValue(validateReport(receipt), "identity_receipt_self_test_failed");
  requireValue(!validateReport({
    ...receipt,
    nonBlockingDistributionGuidance: { blocking: true },
  }), "blocking_distribution_guidance_self_test_failed");
  const virtualFiles = new Map([
    ["installed", "old"],
    ["staged", "new"],
  ]);
  const virtualOperations = {
    exists: (name) => virtualFiles.has(name),
    remove: (name) => virtualFiles.delete(name),
    rename: (from, to) => {
      requireValue(virtualFiles.has(from), "virtual_source_missing");
      const value = virtualFiles.get(from);
      virtualFiles.delete(from);
      virtualFiles.set(to, value);
    },
    verify: (name) => virtualFiles.get(name) === "new",
  };
  replaceInstalledAppWithRollback({
    stagedPath: "staged",
    installedPath: "installed",
    backupPath: "backup",
    operations: virtualOperations,
  });
  requireValue(virtualFiles.get("installed") === "new" && !virtualFiles.has("backup"),
    "atomic_replace_self_test_failed");
  virtualFiles.clear();
  virtualFiles.set("installed", "old");
  virtualFiles.set("staged", "new");
  let injectedFailure = true;
  const rollbackOperations = {
    ...virtualOperations,
    rename: (from, to) => {
      if (from === "staged" && to === "installed" && injectedFailure) {
        injectedFailure = false;
        throw new Error("injected");
      }
      virtualOperations.rename(from, to);
    },
  };
  let rollbackObserved = false;
  try {
    replaceInstalledAppWithRollback({
      stagedPath: "staged",
      installedPath: "installed",
      backupPath: "backup",
      operations: rollbackOperations,
    });
  } catch {
    rollbackObserved = true;
  }
  requireValue(rollbackObserved && virtualFiles.get("installed") === "old" &&
    !virtualFiles.has("backup"), "atomic_rollback_self_test_failed");
  virtualFiles.clear();
  virtualFiles.set("installed", "old");
  virtualFiles.set("staged", "corrupt-new");
  rollbackObserved = false;
  try {
    replaceInstalledAppWithRollback({
      stagedPath: "staged",
      installedPath: "installed",
      backupPath: "backup",
      operations: virtualOperations,
    });
  } catch {
    rollbackObserved = true;
  }
  requireValue(rollbackObserved && virtualFiles.get("installed") === "old" &&
    !virtualFiles.has("backup"), "verification_failure_rollback_self_test_failed");
  requireValue(!validateReport({ ...receipt, entitlementsMatch: false }),
    "entitlements_mismatch_receipt_self_test_failed");
  requireValue(!validateReport({ ...receipt, hardenedRuntime: false }),
    "hardened_runtime_missing_self_test_failed");
  requireValue(!validateReport({ ...receipt, nestedCodeMinimalEntitlements: false }),
    "nested_entitlements_overgrant_self_test_failed");
  console.log(JSON.stringify({ ok: true, caseCount: 11, privatePathsIncluded: false }));
}

function main() {
  if (process.argv.slice(2).includes("--self-test")) {
    selfTest();
    return;
  }
  requireValue(process.platform === "darwin", "macos_identity_install_requires_macos");
  removeContainedReportIfExists(repoRoot, reportRef);
  const identity = String(process.env.LICO_MACOS_LOCAL_SIGNING_IDENTITY || "").trim();
  requireValue(identity, "macos_local_signing_identity_missing");
  requireValue(existsSync(builtApp) && existsSync(packageManifestPath),
    "macos_release_artifact_missing");
  const buildRoot = path.join(repoRoot, "build");
  resolveContainedExistingPath(buildRoot, builtApp, { expectedKind: "directory" });
  resolveContainedExistingPath(buildRoot, packageManifestPath, { expectedKind: "file" });
  const manifest = JSON.parse(stableReadFile(packageManifestPath).toString("utf8"));
  const sourceStateDigest = clientSourceStateDigest(repoRoot, sourceRoots);
  requireValue(validateInputPackageManifest(manifest, sourceStateDigest),
  "macos_release_manifest_source_mismatch");
  const entitlementsRef = String(manifest.signing?.entitlementsFile || "").trim();
  requireValue(entitlementsRef === releaseEntitlementsRef,
    "macos_release_entitlements_ref_invalid");
  const entitlementsPath = path.join(repoRoot, entitlementsRef);
  resolveContainedExistingPath(repoRoot, entitlementsPath, { expectedKind: "file" });

  const mainExecutableName = plistValue(builtApp, "CFBundleExecutable");
  const signingDeadlineMs = Date.now() + 600_000;
  const nestedCodePaths = listMacosNestedCodePaths(builtApp, mainExecutableName, {
    deadlineMs: signingDeadlineMs,
  });
  requireValue(nestedCodePaths.length > 0, "macos_nested_code_inventory_empty");
  for (const nestedPath of nestedCodePaths) {
    const nestedSign = run("/usr/bin/codesign", [
      "--force",
      "--timestamp=none",
      "--options",
      "runtime",
      "--sign",
      identity,
      nestedPath,
    ], remainingDeadlineTimeout(signingDeadlineMs));
    requireValue(nestedSign.status === 0, "macos_nested_code_signing_failed");
  }

  const sign = run("/usr/bin/codesign", [
    "--force",
    "--timestamp=none",
    "--options",
    "runtime",
    "--sign",
    identity,
    "--entitlements",
    entitlementsPath,
    builtApp,
  ], remainingDeadlineTimeout(signingDeadlineMs));
  requireValue(sign.status === 0, "macos_local_identity_signing_failed");
  const builtPolicy = inspectBoundedMacosCodePolicy(
    builtApp,
    mainExecutableName,
    entitlementsPath,
    { deadlineMs: signingDeadlineMs },
  );
  const builtSignature = builtPolicy.signature;
  requireValue(builtSignature.verified &&
    builtSignature.signatureKind === "local-identity-codesign" &&
    builtSignature.hardenedRuntime === true &&
    builtSignature.entitlementsMatch === true &&
    boundedNestedCodePolicyReady(builtPolicy),
    "macos_local_identity_verification_failed");
  const artifactDigest = builtPolicy.artifactDigest;

  const stagedApp = `/Applications/.Arc.local-install-${process.pid}.app`;
  const backupApp = `/Applications/.Arc.local-backup-${process.pid}.app`;
  rmSync(stagedApp, { recursive: true, force: true });
  requireValue(!existsSync(backupApp), "macos_local_install_backup_collision");
  try {
    const copy = run("/usr/bin/ditto", [builtApp, stagedApp]);
    requireValue(copy.status === 0, "macos_local_identity_install_copy_failed");
    replaceInstalledAppWithRollback({
      stagedPath: stagedApp,
      installedPath: installedApp,
      backupPath: backupApp,
      operations: {
        exists: existsSync,
        remove: (target) => rmSync(target, { recursive: true, force: true }),
        rename: renameSync,
        verify: (target) => {
          const targetPolicy = inspectBoundedMacosCodePolicy(
            target,
            mainExecutableName,
            entitlementsPath,
          );
          const signature = targetPolicy.signature;
          return targetPolicy.artifactDigest === artifactDigest &&
            signature.verified &&
            signature.signatureKind === "local-identity-codesign" &&
            signature.hardenedRuntime === true &&
            signature.entitlementsMatch === true &&
            boundedNestedCodePolicyReady(targetPolicy);
        },
      },
    });
  } finally {
    rmSync(stagedApp, { recursive: true, force: true });
  }
  const installedPolicy = inspectBoundedMacosCodePolicy(
    installedApp,
    mainExecutableName,
    entitlementsPath,
  );
  const installedSignature = installedPolicy.signature;
  const installedDigest = installedPolicy.artifactDigest;
  requireValue(installedSignature.verified &&
    installedSignature.signatureKind === "local-identity-codesign" &&
    installedSignature.hardenedRuntime === true &&
    installedSignature.entitlementsMatch === true &&
    boundedNestedCodePolicyReady(installedPolicy) &&
    artifactDigest === installedDigest,
  "macos_installed_identity_artifact_mismatch");

  const finalizedManifest = identityManifest(manifest);
  requireValue(validateIdentityManifest(finalizedManifest, sourceStateDigest),
    "macos_identity_manifest_invalid");
  atomicWriteReportJson(
    buildRoot,
    path.relative(buildRoot, packageManifestPath),
    finalizedManifest,
  );
  const productVersion = String(
    JSON.parse(stableReadFile(path.join(repoRoot, "tools/client-version.json")).toString("utf8")).productVersion || "",
  ).trim();
  requireValue(productVersion, "macos_product_version_missing");
  const report = {
    schemaVersion,
    generatedAt: new Date().toISOString(),
    generatedBy: producer,
    ok: true,
    targetId: "macos-arm64",
    productVersion,
    artifactKind: "macos-app-bundle",
    sourceStateDigest,
    artifactDigest,
    signatureKind: "local-identity-codesign",
    platformLocalSignatureReady: true,
    entitlementsMatch: true,
    entitlementsDigest: installedSignature.entitlementsDigest,
    hardenedRuntime: true,
    nestedCodeMinimalEntitlements: true,
    installReady: true,
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      notarizationStatus: "not-configured",
      updateChannelStatus: "not-configured",
    },
    privacy: {
      redacted: true,
      absolutePathsIncluded: false,
      signingIdentityIncluded: false,
      keyMaterialIncluded: false,
      rawLogsIncluded: false,
    },
  };
  requireValue(validateReport(report), "macos_identity_install_receipt_invalid");
  atomicWriteReportJson(buildRoot, reportRef.replace(/^build\//u, ""), report);
  console.log(JSON.stringify({
    ok: true,
    targetId: report.targetId,
    signatureKind: report.signatureKind,
    installReady: true,
    nonBlockingDistributionGuidance: report.nonBlockingDistributionGuidance,
    report: reportRef,
    privatePathsIncluded: false,
  }));
}

try {
  main();
} catch {
  console.error(JSON.stringify({
    ok: false,
    reason: "macos_local_identity_install_failed",
    privatePathsIncluded: false,
  }));
  process.exitCode = 1;
}
