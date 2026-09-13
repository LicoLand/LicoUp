import {
  existsSync,
  copyFileSync,
  chmodSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { createHash } from "node:crypto";

import {
  packageClientRuntime,
  packageFailure,
} from "../cli-policy.mjs";
import { capturePackageProcess, runPackageProcess } from "../process-runner.mjs";
import { macosAppDirFromBundle, macosCustodyHelper, macosCustodyHelperPaths } from "./metadata.mjs";

export function assertMacosSigningPreflight(options, dependencies = {}) {
  if (options.platform !== "macos") return;
  const templatePath = macosEntitlementsPath(options);
  if (!existsSync(templatePath)) packageFailure("macos_entitlements_missing");
  if (options.productionEntitlements) macosAppIdentifierPrefix(dependencies.environment);
  if (options.macosCustodySigning) macosCustodySigningConfiguration(dependencies);
}

export function packageSigningPolicyRecord(options) {
  if (options.platform !== "macos") {
    return Object.freeze({
      platform: options.platform,
      signingKind: "platform-default",
      entitlementsFile: "",
      entitlementProfile: "",
      productionEntitlementsRequested: false,
    });
  }
  return Object.freeze({
    platform: "macos",
    signingKind: options.macosCustodySigning
      ? "local-provisioned-developer-id-codesign" : "local-ad-hoc-codesign",
    custodyHelper: macosCustodyHelper.relativeExecutablePath,
    custodyProvisioningRequested: options.macosCustodySigning === true,
    entitlementsFile: path.relative(
      packageClientRuntime.workspaceRoot,
      macosEntitlementsPath(options),
    ),
    entitlementProfile: macosEntitlementsProfile(options),
    productionEntitlementsRequested:
      options.productionEntitlements === true,
    nonDryRunRequiresAppIdentifierPrefix:
      options.productionEntitlements === true,
  });
}

export function signMacosBundle(bundle, copiedArtifacts, options, dependencies = {}) {
  if (options.platform !== "macos") return;
  const signing = options.macosCustodySigning
    ? macosCustodySigningConfiguration(dependencies) : null;
  const appDir = macosAppDirFromBundle(bundle);
  const helper = macosCustodyHelperPaths(appDir);
  prepareMacosProfiles(appDir, signing);
  const entitlementsPath = macosEntitlementsPathForSigning(options, signing?.prefix, dependencies.signingRoot);
  for (const frameworkPath of repairMacosFrameworkSymlinks(
    macosAppDirFromBundle(bundle),
  )) {
    signMacosArtifact(frameworkPath, "", signing, dependencies);
  }
  for (const artifact of copiedArtifacts) {
    if (existsSync(artifact) && statSync(artifact).isFile()) {
      if (path.resolve(artifact) === helper.executablePath) continue;
      signMacosArtifact(artifact, signing ? "" : entitlementsPath, signing, dependencies);
    }
  }
  signMacosArtifact(helper.appPath, options.productionEntitlements
    ? custodyEntitlementsPathForSigning(signing?.prefix || macosAppIdentifierPrefix(), dependencies.signingRoot) : entitlementsPath,
    signing, dependencies);
  signMacosArtifact(appDir, entitlementsPath, signing, dependencies);
}

export function signMacosRunnable(runnable, options, dependencies = {}) {
  if (options.platform !== "macos") return;
  const signing = options.macosCustodySigning
    ? macosCustodySigningConfiguration(dependencies) : null;
  prepareMacosProfiles(runnable.appPath, signing);
  for (const frameworkPath of repairMacosFrameworkSymlinks(
    runnable.appPath,
  )) {
    signMacosArtifact(frameworkPath, "", signing, dependencies);
  }
  signMacosArtifact(macosCustodyHelperPaths(runnable.appPath).appPath,
    options.productionEntitlements ? custodyEntitlementsPathForSigning(signing?.prefix || macosAppIdentifierPrefix(), dependencies.signingRoot) : macosEntitlementsPathForSigning(options),
    signing, dependencies);
  signMacosArtifact(
    runnable.appPath,
    macosEntitlementsPathForSigning(options, signing?.prefix, dependencies.signingRoot),
    signing, dependencies,
  );
}

export function signMacosArtifact(artifactPath, entitlementsPath = "", signing = null,
  { runProcess = runPackageProcess } = {}) {
  const args = ["--force", "--sign", signing?.identity || "-"];
  // This mode performs local validation only; release timestamp/notarization
  // remains owned by the separate release authority.
  if (signing) args.push("--options", "runtime", "--timestamp=none");
  if (entitlementsPath) args.push("--entitlements", entitlementsPath);
  args.push(artifactPath);
  runProcess("codesign", args, {
    failureCode: "macos_codesign_failed",
    stage: "macos-signing",
  });
  if (signing) runProcess("codesign", ["--verify", "--strict", artifactPath], {
    failureCode: "macos_codesign_verification_failed", stage: "macos-signing",
  });
}

export function validateMacosCustodyProfile(profile, { bundleId, prefix, identity }, now = Date.now()) {
  const entitlements = profile?.Entitlements || {};
  const allows = (value, requested) => typeof value === "string" &&
    (value === requested || (value.endsWith(".*") && requested.startsWith(value.slice(0, -1))));
  const applicationId = entitlements["com.apple.application-identifier"];
  const group = `${prefix}${packageClientRuntime.bundleId}`;
  if (profile?.ProvisionsAllDevices !== true ||
      !(Date.parse(profile?.ExpirationDate) > now) ||
      !allows(applicationId, `${prefix}${bundleId}`) ||
      !Array.isArray(entitlements["keychain-access-groups"]) ||
      !entitlements["keychain-access-groups"].some((value) => allows(value, group))) {
    packageFailure("macos_custody_profile_scope_invalid");
  }
  const certificates = profile?.DeveloperCertificates;
  if (!Array.isArray(certificates) || !certificates.some((certificate) =>
    typeof certificate === "string" && createHash("sha1")
      .update(Buffer.from(certificate, "base64")).digest("hex").toUpperCase() === identity)) {
    packageFailure("macos_custody_profile_certificate_mismatch");
  }
}

export function macosCustodySigningConfiguration({
  environment = process.env, readProfile = readMacosProvisioningProfile,
} = {}) {
  const identity = String(environment.LICO_MACOS_SIGNING_IDENTITY || "").trim().toUpperCase();
  if (!/^[A-F0-9]{40}$/u.test(identity)) packageFailure("macos_custody_signing_identity_invalid");
  const prefix = macosAppIdentifierPrefix(environment);
  const appProfile = String(environment.LICO_MACOS_APP_PROVISIONING_PROFILE || "").trim();
  const helperProfile = String(environment.LICO_MACOS_CUSTODY_PROVISIONING_PROFILE || "").trim();
  for (const [profilePath, bundleId] of [[appProfile, packageClientRuntime.bundleId],
    [helperProfile, macosCustodyHelper.bundleId]]) {
    if (!profilePath || !existsSync(profilePath)) packageFailure("macos_custody_profile_missing");
    validateMacosCustodyProfile(readProfile(profilePath), { bundleId, prefix, identity });
  }
  return { identity, prefix, appProfile, helperProfile };
}

export function readMacosProvisioningProfile(profilePath, capture = capturePackageProcess) {
  const options = { failureCode: "macos_custody_profile_decode_failed", stage: "macos-signing" };
  const plist = capture("/usr/bin/security", ["cms", "-D", "-i", profilePath], options);
  // A full profile contains plist dates and data, which are not JSON types.
  // Let Apple's parser extract only the metadata needed by this signing mode.
  const extract = (key, format = "raw") => capture("/usr/bin/plutil",
    ["-extract", key, format, "-o", "-", "-"],
    { ...options, input: plist, stdio: ["pipe", "pipe", "pipe"] }).trim();
  try {
    const certificateCount = Number(extract("DeveloperCertificates"));
    if (!Number.isSafeInteger(certificateCount) || certificateCount < 1) {
      packageFailure("macos_custody_profile_decode_failed");
    }
    return {
      Entitlements: JSON.parse(extract("Entitlements", "json")),
      ProvisionsAllDevices: extract("ProvisionsAllDevices") === "true",
      ExpirationDate: extract("ExpirationDate"),
      DeveloperCertificates: Array.from({ length: certificateCount }, (_, index) =>
        extract(`DeveloperCertificates.${index}`)),
    };
  } catch { packageFailure("macos_custody_profile_decode_failed"); }
}

function prepareMacosProfiles(appDir, signing) {
  const helper = macosCustodyHelperPaths(appDir);
  if (!existsSync(helper.executablePath)) packageFailure("macos_custody_helper_missing");
  const appProfilePath = path.join(appDir, "Contents", "embedded.provisionprofile");
  if (signing) {
    copyFileSync(signing.appProfile, appProfilePath);
    copyFileSync(signing.helperProfile, helper.profilePath);
  } else {
    // A reused staging directory must not advertise a previous signed build's profile.
    rmSync(appProfilePath, { force: true });
    rmSync(helper.profilePath, { force: true });
  }
}

function custodyEntitlementsPathForSigning(prefix, signingRoot = defaultMacosSigningRoot()) {
  const template = path.join(packageClientRuntime.flutterClientRoot, "macos", "CustodyHelper", "ProductionRelease.entitlements");
  const target = path.join(signingRoot, "release", "CustodyRelease.resolved.entitlements");
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, readFileSync(template, "utf8").replaceAll("$(AppIdentifierPrefix)", prefix), { mode: 0o600 });
  chmodSync(target, 0o600);
  return target;
}

function macosEntitlementsProfile(options) {
  if (options.mode === "release" && options.productionEntitlements) {
    return "production-release";
  }
  return options.mode === "release" ? "release" : "debug-profile";
}

function macosEntitlementsPath(options) {
  const fileName =
    macosEntitlementsProfile(options) === "production-release"
      ? "ProductionRelease.entitlements"
      : options.mode === "release"
        ? "Release.entitlements"
        : "DebugProfile.entitlements";
  return path.join(
    packageClientRuntime.flutterClientRoot,
    "macos",
    "Runner",
    fileName,
  );
}

function macosAppIdentifierPrefix(environment = process.env) {
  const configured = String(
    environment.LICO_MACOS_APP_IDENTIFIER_PREFIX || "",
  ).trim();
  if (!configured) packageFailure("macos_app_identifier_prefix_missing");
  const normalized = configured.endsWith(".")
    ? configured
    : `${configured}.`;
  if (!/^[A-Z0-9]{10}\.$/u.test(normalized)) {
    packageFailure("macos_app_identifier_prefix_invalid");
  }
  return normalized;
}

function defaultMacosSigningRoot() {
  return path.join(packageClientRuntime.clientBuildRoot, "signing", "macos");
}

function macosEntitlementsPathForSigning(options, prefix, signingRoot = defaultMacosSigningRoot()) {
  const templatePath = macosEntitlementsPath(options);
  if (!existsSync(templatePath)) packageFailure("macos_entitlements_missing");
  if (!options.productionEntitlements) return templatePath;
  const resolved = readFileSync(templatePath, "utf8")
    .replaceAll("$(AppIdentifierPrefix)", prefix || macosAppIdentifierPrefix())
    .replaceAll("$(PRODUCT_BUNDLE_IDENTIFIER)", packageClientRuntime.bundleId);
  if (resolved.includes("$(")) {
    packageFailure("macos_entitlements_placeholder_unresolved");
  }
  const target = path.join(
    signingRoot,
    options.mode,
    "ProductionRelease.resolved.entitlements",
  );
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, resolved, { mode: 0o600 });
  chmodSync(target, 0o600);
  return target;
}

function repairMacosFrameworkSymlinks(appDir) {
  const frameworksDir = path.join(appDir, "Contents", "Frameworks");
  if (!existsSync(frameworksDir)) return [];
  const repaired = [];
  for (const entry of readdirSync(frameworksDir)) {
    if (!entry.endsWith(".framework")) continue;
    const frameworkPath = path.join(frameworksDir, entry);
    const frameworkName = path.basename(entry, ".framework");
    const versionsDir = path.join(frameworkPath, "Versions");
    const versionRoot = path.join(versionsDir, "A");
    if (!existsSync(versionRoot)) continue;
    rmSync(path.join(versionsDir, "Current"), { force: true });
    symlinkSync("A", path.join(versionsDir, "Current"));
    const binary = path.join(versionRoot, frameworkName);
    if (existsSync(binary)) {
      rmSync(path.join(frameworkPath, frameworkName), { force: true });
      symlinkSync(
        path.join("Versions", "Current", frameworkName),
        path.join(frameworkPath, frameworkName),
      );
    }
    const resources = path.join(versionRoot, "Resources");
    if (existsSync(resources)) {
      rmSync(path.join(frameworkPath, "Resources"), { force: true });
      symlinkSync(
        path.join("Versions", "Current", "Resources"),
        path.join(frameworkPath, "Resources"),
      );
    }
    repaired.push(frameworkPath);
  }
  return repaired;
}
