import {
  existsSync,
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

import {
  packageClientRuntime,
  packageFailure,
} from "../cli-policy.mjs";
import { runPackageProcess } from "../process-runner.mjs";
import { macosAppDirFromBundle } from "./metadata.mjs";

export function assertMacosSigningPreflight(options) {
  if (options.platform !== "macos") return;
  const templatePath = macosEntitlementsPath(options);
  if (!existsSync(templatePath)) packageFailure("macos_entitlements_missing");
  if (options.productionEntitlements) macosAppIdentifierPrefix();
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
    signingKind: "local-ad-hoc-codesign",
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

export function signMacosBundle(bundle, copiedArtifacts, options) {
  if (options.platform !== "macos") return;
  const entitlementsPath = macosEntitlementsPathForSigning(options);
  for (const frameworkPath of repairMacosFrameworkSymlinks(
    macosAppDirFromBundle(bundle),
  )) {
    signMacosArtifact(frameworkPath);
  }
  for (const artifact of copiedArtifacts) {
    if (existsSync(artifact) && statSync(artifact).isFile()) {
      signMacosArtifact(artifact, entitlementsPath);
    }
  }
  signMacosArtifact(macosAppDirFromBundle(bundle), entitlementsPath);
}

export function signMacosRunnable(runnable, options) {
  if (options.platform !== "macos") return;
  for (const frameworkPath of repairMacosFrameworkSymlinks(
    runnable.appPath,
  )) {
    signMacosArtifact(frameworkPath);
  }
  signMacosArtifact(
    runnable.appPath,
    macosEntitlementsPathForSigning(options),
  );
}

export function signMacosArtifact(artifactPath, entitlementsPath = "") {
  const args = ["--force", "--sign", "-"];
  if (entitlementsPath) args.push("--entitlements", entitlementsPath);
  args.push(artifactPath);
  runPackageProcess("codesign", args, {
    failureCode: "macos_codesign_failed",
    stage: "macos-signing",
  });
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

function macosAppIdentifierPrefix() {
  const configured = String(
    process.env.LICO_MACOS_APP_IDENTIFIER_PREFIX || "",
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

function macosEntitlementsPathForSigning(options) {
  const templatePath = macosEntitlementsPath(options);
  if (!existsSync(templatePath)) packageFailure("macos_entitlements_missing");
  if (!options.productionEntitlements) return templatePath;
  const resolved = readFileSync(templatePath, "utf8")
    .replaceAll("$(AppIdentifierPrefix)", macosAppIdentifierPrefix())
    .replaceAll("$(PRODUCT_BUNDLE_IDENTIFIER)", packageClientRuntime.bundleId);
  if (resolved.includes("$(")) {
    packageFailure("macos_entitlements_placeholder_unresolved");
  }
  const target = path.join(
    packageClientRuntime.clientBuildRoot,
    "signing",
    "macos",
    options.mode,
    "ProductionRelease.resolved.entitlements",
  );
  mkdirSync(path.dirname(target), { recursive: true });
  writeFileSync(target, resolved, "utf8");
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
