// Static macOS direct-distribution release boundary contract.
//
// This regression reads only checked-in metadata, entitlements, the release
// target catalog, the direct recipe description, and the downstream verifier
// sources.  It never builds, signs, reads credentials, or touches Apple
// services.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { describePlatformReleasePackages } from "../../../apps/desktop/scripts/build-platform-release-package.mjs";
import {
  macosEntitlementsInspection,
  macosSignatureEvidenceFromText,
} from "../../../tools/scripts/lib/macos-code-signature.mjs";
import {
  authorizeProvisioningProfile,
  MACOS_DIRECT_COMMAND_KINDS,
  MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID,
  MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME,
  MACOS_DIRECT_PROTECTED_ENVIRONMENT,
  MACOS_DIRECT_TOOLCHAIN,
  macosDistributionFailureCode,
  macosDistributionManifestClaims,
  macosDistributionReadinessPolicy,
  redactMacosDistributionFailure,
  validateLocalEntitlements,
  validateMacosCameraPluginBoundary,
  validateMacosDirectCommandSequence,
  validateMacosDistributionMetadata,
  validateProductionEntitlements,
} from "../../../tools/scripts/lib/macos-direct-distribution-policy.mjs";
import {
  certificateEvidenceFixture,
  localEntitlementsFixture,
  productionEntitlementsFixture,
  profileVariant,
} from "./macos-direct-distribution-self-test.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const entitlementsDir = path.join(repoRoot, "apps/desktop/macos/Runner");
const productionEntitlementsPath = path.join(entitlementsDir, "ProductionRelease.entitlements");
const localEntitlementsPath = path.join(entitlementsDir, "Release.entitlements");
const infoPlistPath = path.join(entitlementsDir, "Info.plist");
const pluginRegistrantPath = path.join(
  repoRoot,
  "apps/desktop/macos/Flutter/GeneratedPluginRegistrant.swift",
);
const privacyManifestPath = path.join(
  repoRoot,
  "apps/desktop/packaging/macos/PrivacyInfo.xcprivacy",
);
const catalogPath = path.join(repoRoot, "tools/client-release-targets.json");
const architectureConfigPath = path.join(
  repoRoot,
  "apps/desktop/macos/Runner/Configs/Architecture.xcconfig",
);
const fixedNow = Date.parse("2026-08-11T00:00:00.000Z");

function plistValue(source, key) {
  const open = `<key>${key}</key>`;
  const start = source.indexOf(open);
  if (start < 0) return undefined;
  const after = source.slice(start + open.length);
  const stringMatch = /^\s*<string>([^<]*)<\/string>/u.exec(after);
  if (stringMatch) return stringMatch[1];
  if (/^\s*<true\s*\/>/u.test(after)) return true;
  const arrayMatch = /^\s*<array>\s*(.*?)<\/array>/su.exec(after);
  if (arrayMatch) {
    return [...arrayMatch[1].matchAll(/<string>([^<]*)<\/string>/gu)]
      .map((match) => match[1]);
  }
  return undefined;
}

function plistObject(source) {
  const object = {};
  for (const match of source.matchAll(/<key>([^<]+)<\/key>/gu)) {
    const value = plistValue(source, match[1]);
    if (value !== undefined) object[match[1]] = value;
  }
  return object;
}

function greenSequence(identity) {
  const nestedPath = "/build/LicoUp.app/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS";
  const appPath = "/build/LicoUp.app";
  const entitlementsPath = "/build/ProductionRelease.resolved.entitlements";
  const dmgPath = "/build/LicoUp-macos-arm64.dmg";
  return MACOS_DIRECT_COMMAND_KINDS.map((kind) => {
    if (kind === "app-nested-sign") {
      return {
        kind,
        program: "/usr/bin/codesign",
        args: ["--force", "--options", "runtime", "--timestamp",
          "--sign", identity, nestedPath],
      };
    }
    if (kind === "app-sign") {
      return {
        kind,
        program: "/usr/bin/codesign",
        args: ["--force", "--options", "runtime", "--timestamp",
          "--sign", identity, "--entitlements", entitlementsPath, appPath],
      };
    }
    if (kind === "dmg-sign") {
      return {
        kind,
        program: "/usr/bin/codesign",
        args: ["--force", "--timestamp", "--sign", identity, dmgPath],
      };
    }
    return { kind, program: "", args: [] };
  });
}

test("product metadata and entitlement authorities are exact and minimal", () => {
  const metadata = validateMacosDistributionMetadata({
    displayName: MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME,
    bundleName: MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME,
    bundleIdentifier: MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID,
  });
  assert.equal(metadata.ready, true);
  assert.equal(validateMacosDistributionMetadata({
    displayName: "Arc",
    bundleName: MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME,
    bundleIdentifier: MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID,
  }).ready, false);

  const infoPlist = readFileSync(infoPlistPath, "utf8");
  assert.equal(plistValue(infoPlist, "CFBundleName"), "LicoUp");
  assert.equal(plistValue(infoPlist, "CFBundleDisplayName"), "LicoUp");
  for (const sensitivePurpose of [
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSScreenCaptureUsageDescription",
  ]) {
    assert.equal(infoPlist.includes(sensitivePurpose), false);
  }

  const productionText = readFileSync(productionEntitlementsPath, "utf8");
  const production = plistObject(productionText);
  const productionResult = validateProductionEntitlements(production);
  assert.equal(productionResult.ready, true);
  assert.equal(productionResult.identity.paired, true);
  assert.equal(productionResult.identity.placeholder, true);
  assert.equal(productionResult.identity.applicationIdentifier,
    "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)");
  assert.deepEqual(productionResult.identity.keychainAccessGroups,
    ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"]);
  assert.equal(production["get-task-allow"], undefined);
  assert.equal(production["com.apple.security.cs.disable-library-validation"], undefined);
  assert.equal(productionText.includes("get-task-allow"), false);
  assert.equal(productionText.includes("disable-library-validation"), false);
  assert.equal(productionText.includes("com.apple.security.device.camera"), false);
  assert.equal(productionText.includes("com.apple.security.device.audio-input"), false);

  const localText = readFileSync(localEntitlementsPath, "utf8");
  const local = plistObject(localText);
  assert.equal(validateLocalEntitlements(local).ready, true);
  assert.equal(local["com.apple.security.cs.disable-library-validation"], true);
  assert.equal(validateLocalEntitlements({
    ...localEntitlementsFixture,
    "com.apple.security.cs.disable-library-validation": false,
  }).ready, false);
  assert.equal(local["get-task-allow"], undefined);
  assert.equal(localText.includes("disable-library-validation"), true);

  const toolchain = [...MACOS_DIRECT_TOOLCHAIN];
  assert.deepEqual(toolchain.sort(), [
    "codesign", "ditto", "hdiutil", "notarytool", "openssl", "plutil",
    "security", "spctl", "stapler", "xcodebuild",
  ]);
});

test("macOS excludes camera registration and ships an audited privacy manifest", () => {
  const registrant = readFileSync(pluginRegistrantPath, "utf8");
  assert.equal(/camera|scanner/iu.test(registrant), false);
  assert.equal(validateMacosCameraPluginBoundary([
    "/bundle/LicoUp.app/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS",
  ]).ready, true);
  const blockedCameraPlugin = validateMacosCameraPluginBoundary([
    "/bundle/LicoUp.app/Contents/Frameworks/camera_avfoundation.framework/camera_avfoundation",
  ]);
  assert.equal(blockedCameraPlugin.ready, false);
  assert.equal(blockedCameraPlugin.cameraPluginPresent, true);

  const privacyManifest = readFileSync(privacyManifestPath, "utf8");
  for (const value of [
    "NSPrivacyTracking",
    "NSPrivacyCollectedDataTypes",
    "NSPrivacyAccessedAPICategoryFileTimestamp",
    "DDA9.1",
    "C617.1",
    "3B52.1",
    "NSPrivacyAccessedAPICategorySystemBootTime",
    "35F9.1",
    "NSPrivacyAccessedAPICategoryUserDefaults",
    "CA92.1",
  ]) {
    assert.ok(privacyManifest.includes(value), value);
  }
});

test("provisioning profile authorization fails closed on every mismatch", () => {
  const authorized = authorizeProvisioningProfile(
    profileVariant("matching"),
    productionEntitlementsFixture,
    { now: fixedNow, certificateEvidence: certificateEvidenceFixture("matching") },
  );
  assert.equal(authorized.authorized, true);
  for (const [variant, expectedCode] of [
    ["expired", "macos_distribution_profile_expired"],
    ["non-developer-id", "macos_distribution_profile_not_developer_id"],
    ["app-id-mismatch", "macos_distribution_profile_application_identifier_mismatch"],
    ["team-mismatch", "macos_distribution_profile_team_mismatch"],
  ]) {
    const denied = authorizeProvisioningProfile(
      profileVariant(variant),
      productionEntitlementsFixture,
      { now: fixedNow, certificateEvidence: certificateEvidenceFixture(variant) },
    );
    assert.equal(denied.authorized, false, variant);
    assert.ok(denied.errors.includes(expectedCode), variant);
  }
});

test("command sequence policy enforces inside-out hardened signing and atomic last claim", () => {
  const identity = "Developer ID Application: LicoUp (TEAM123456)";
  const green = greenSequence(identity);
  assert.equal(validateMacosDirectCommandSequence(green).ready, true);
  const readiness = macosDistributionReadinessPolicy(green);
  assert.equal(readiness.ready, true);
  assert.equal(readiness.finalDmgVerified, true);
  assert.equal(readiness.staleManifestRemoved, true);

  const nested = green.find((entry) => entry.kind === "app-nested-sign");
  const appSign = green.find((entry) => entry.kind === "app-sign");
  const dmgSign = green.find((entry) => entry.kind === "dmg-sign");
  const assertRejects = (sequence, code) => {
    const result = validateMacosDirectCommandSequence(sequence);
    assert.equal(result.ready, false);
    assert.ok(result.errors.includes(code), `${code} not raised`);
  };
  assertRejects([...green.filter((entry) => entry.kind !== "app-nested-sign")],
    "macos_distribution_nested_signing_missing");
  assertRejects(green.map((entry) => entry.kind === "app-sign"
    ? { ...entry, args: [...entry.args, "--deep"] } : entry),
  "macos_distribution_codesign_deep_sign_forbidden");
  assertRejects(green.map((entry) => entry.kind === "app-nested-sign"
    ? { ...entry, args: ["--entitlements", "fixture/entitlements.plist", ...nested.args] } : entry),
  "macos_distribution_entitlements_invalid");
  assertRejects(green.map((entry) => entry.kind === "app-nested-sign"
    ? { ...entry, args: entry.args.filter((arg) => arg !== "runtime") } : entry),
  "macos_distribution_signing_order_invalid");
  assertRejects(green.map((entry) => entry.kind === "app-sign"
    ? { ...entry, args: entry.args.filter((arg) => arg !== "--entitlements") } : entry),
  "macos_distribution_entitlements_invalid");
  assertRejects(green.map((entry) => entry.kind === "dmg-sign"
    ? { ...entry, args: entry.args.map((arg) => arg === "--timestamp" ? "--timestamp=none" : arg) }
    : entry),
  "macos_distribution_ready_claim_premature");
  assertRejects(green.filter((entry) => entry.kind !== "ready-manifest-write"),
    "macos_distribution_ready_claim_not_last");

  const failedFinalDmg = green.map((entry) => entry.kind === "dmg-notarize"
    ? { ...entry, failed: true } : entry);
  assert.equal(macosDistributionReadinessPolicy(failedFinalDmg).ready, false);
  assert.equal(macosDistributionReadinessPolicy(green.slice(1)).staleManifestRemoved, false);
  assert.equal(validateMacosDirectCommandSequence(green.slice(1)).ready, false);
  assert.equal(macosDistributionManifestClaims({
    platformChannelRequested: true,
    sequenceReady: true,
    signingKind: "developer-id-application",
  }).githubReleaseBlocked, true);
});

test("inspected signature evidence requires Developer ID OIDs and accepts verified empty nested entitlements", () => {
  const details = "Authority=Developer ID Application\nTeamIdentifier=TEAM123456\nTimestamp=Aug 11, 2026\n";
  const requirements = [
    "designated => identifier land.lico.licoup and anchor apple generic",
    "certificate 1[field.1.2.840.113635.100.6.2.6] exists",
    "certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
  ].join(" and ");
  const evidence = macosSignatureEvidenceFromText(details, requirements, 0);
  assert.equal(evidence.developerIdApplication, true);
  assert.equal(evidence.secureTimestamp, true);
  assert.equal(evidence.teamIdentifier, "TEAM123456");
  assert.equal(macosSignatureEvidenceFromText(
    details.replace("Aug 11, 2026", "none"),
    requirements.replace(".1.13", ".1.4"),
    0,
  ).developerIdApplication, false);
  assert.deepEqual(macosEntitlementsInspection({
    expected: false,
    actualCanonical: "",
    expectedCanonical: "",
    raw: "",
    parsed: false,
    status: 1,
  }), {
    entitlementsMatch: false,
    entitlementsEmpty: true,
    ready: true,
  });
  assert.equal(macosEntitlementsInspection({
    expected: false,
    actualCanonical: "",
    expectedCanonical: "",
    raw: "malformed",
    parsed: false,
    status: 1,
  }).ready, false);
  assert.equal(macosEntitlementsInspection({
    expected: false,
    actualCanonical: "",
    expectedCanonical: "",
    raw: "",
    parsed: false,
    status: null,
  }).ready, false);
});

test("macOS product and release catalogs are arm64 only", () => {
  const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
  const direct = catalog.targets.find((target) => target.id === "macos-direct-arm64");
  const appStore = catalog.targets.find((target) => target.id === "macos-app-store-arm64");
  const macosTargets = catalog.targets.filter((target) => target.platform === "macos");
  assert.ok(macosTargets.length > 0);
  assert.ok(macosTargets.every((target) =>
    target.arch === "arm64" && target.runtimeTargetId === "macos-arm64" &&
    target.baseline === "macos-11.0" && target.buildHost === "darwin-arm64"));
  assert.equal(direct.releaseSupported, true);
  assert.deepEqual(direct.releaseBlockers, []);
  assert.equal(appStore.releaseSupported, false);
  for (const blocker of [
    "macos_app_store_sandbox_required",
    "macos_app_store_process_policy_pending",
    "macos_app_store_update_authority_required",
    "macos_app_store_signing_authority_required",
    "macos_app_store_submission_receipt_pending",
  ]) {
    assert.ok(appStore.releaseBlockers.includes(blocker), blocker);
  }
});

test("macOS Xcode and CocoaPods builds enforce Apple Silicon", () => {
  const architecture = readFileSync(architectureConfigPath, "utf8");
  const podfile = readFileSync(path.join(repoRoot, "apps/desktop/macos/Podfile"), "utf8");
  const debugConfig = readFileSync(
    path.join(repoRoot, "apps/desktop/macos/Runner/Configs/Debug.xcconfig"),
    "utf8",
  );
  const releaseConfig = readFileSync(
    path.join(repoRoot, "apps/desktop/macos/Runner/Configs/Release.xcconfig"),
    "utf8",
  );
  assert.match(architecture, /^ARCHS = arm64$/mu);
  assert.match(architecture, /^EXCLUDED_ARCHS = x86_64$/mu);
  assert.match(architecture, /^ONLY_ACTIVE_ARCH = YES$/mu);
  assert.match(debugConfig, /#include "Architecture\.xcconfig"/u);
  assert.match(releaseConfig, /#include "Architecture\.xcconfig"/u);
  assert.match(podfile, /platform :osx, '11\.0'/u);
  assert.match(podfile, /config\.build_settings\['ARCHS'\] = 'arm64'/u);
  assert.match(podfile, /config\.build_settings\['EXCLUDED_ARCHS'\] = 'x86_64'/u);
});

test("remote release recipes expose no macOS direct packaging path", () => {
  for (const targetId of ["macos-direct-arm64"]) {
    const recipe = describePlatformReleasePackages({ targetId });
    assert.deepEqual(recipe.commands, []);
    assert.deepEqual(recipe.credentialEnv, []);
    assert.deepEqual(recipe.requiredTools, []);
  }
});

test("downstream macOS verifiers consume the corrected entitlement authority", () => {
  const releasePreflight = readFileSync(
    path.join(repoRoot, "tools/scripts/client-macos-release-artifact-preflight.mjs"), "utf8",
  );
  const updatePreflight = readFileSync(
    path.join(repoRoot, "tools/scripts/client-macos-update-preflight.mjs"), "utf8",
  );
  const packageManifest = readFileSync(path.join(repoRoot, "package.json"), "utf8");
  const localInstall = readFileSync(
    path.join(repoRoot, "tools/scripts/client-macos-install.mjs"), "utf8",
  );
  const distributionBuilder = readFileSync(
    path.join(repoRoot, "apps/desktop/scripts/build-macos-distribution.mjs"), "utf8",
  );
  for (const verifier of [releasePreflight, updatePreflight]) {
    assert.ok(verifier.includes(
      "build/apps/desktop/signing/macos/release/ProductionRelease.resolved.entitlements",
    ));
    assert.equal(verifier.includes(
      "apps/desktop/macos/Runner/ProductionRelease.entitlements",
    ), false);
  }
  assert.equal(packageManifest.includes("client:install:macos:identity"), false);
  assert.equal(localInstall.includes("client-macos-local-identity-install.mjs"), false);
  assert.deepEqual(MACOS_DIRECT_PROTECTED_ENVIRONMENT.includes(
    "LICO_MACOS_SIGNING_IDENTITY",
  ), true);
  assert.deepEqual(MACOS_DIRECT_PROTECTED_ENVIRONMENT.includes(
    "LICO_MACOS_NOTARY_KEYCHAIN_PROFILE",
  ), true);
  assert.ok(distributionBuilder.includes("developerIdApplication !== true"));
  assert.ok(distributionBuilder.includes('"notarytool", "submit"'));
  assert.ok(distributionBuilder.includes('"--keychain-profile", notaryKeychainProfile'));
  for (const removedCredential of [
    "LICO_MACOS_NOTARY_KEY_ID",
    "LICO_MACOS_NOTARY_ISSUER_ID",
    "LICO_MACOS_NOTARY_KEY_PATH",
  ]) {
    assert.equal(distributionBuilder.includes(removedCredential), false);
  }
  for (const cargoNoticeControl of [
    '"metadata"',
    '"--locked"',
    '"--offline"',
    '"--filter-platform"',
    "Rust dependencies linked into LicoUp",
  ]) {
    assert.ok(distributionBuilder.includes(cargoNoticeControl), cargoNoticeControl);
  }
});

test("failures stay typed, stable, and private", () => {
  const error = Object.assign(new Error("marker private-fixture.p12 expired"),
    { code: "macos_distribution_profile_expired" });
  assert.equal(macosDistributionFailureCode(error), "macos_distribution_profile_expired");
  assert.equal(macosDistributionFailureCode(new Error("boom")),
    "macos_distribution_failed");
  const redacted = redactMacosDistributionFailure(error, { markers: ["marker"] });
  assert.equal(redacted.ok, false);
  assert.equal(redacted.code, "macos_distribution_profile_expired");
  assert.equal(redacted.privatePathsIncluded, false);
  assert.equal(redacted.markerDataIncluded, true);
  const privateFree = redactMacosDistributionFailure(error);
  assert.equal(privateFree.markerDataIncluded, false);
});
