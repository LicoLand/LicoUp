#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
  renameSync,
  copyFileSync,
  statSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { gzipSync, unzipSync } from "node:zlib";
import { packageClient } from "./package-client.mjs";
import {
  artifactTreeDigest,
  sha256Buffer,
  sha256File,
} from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import { minimalReleaseToolEnvironment } from "../../../tools/scripts/lib/release-tool-environment.mjs";
import {
  inspectBoundedMacosCodePolicy,
  inspectMacosContainerSignature,
  listMacosNestedCodePaths,
} from "../../../tools/scripts/lib/macos-code-signature.mjs";
import {
  authorizeProvisioningProfile,
  developerIdCertificateEvidenceFromText,
  macosDistributionFailureCode,
  macosDistributionManifestClaims,
  macosDistributionReadinessPolicy,
  macosEntitlementsAuthorityRef,
  MACOS_DIRECT_COMMAND_KINDS,
  MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID,
  MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME,
  MACOS_DIRECT_PROTECTED_ENVIRONMENT,
  MACOS_DIRECT_TOOLCHAIN,
  redactMacosDistributionFailure,
  validateLocalEntitlements,
  validateMacosCameraPluginBoundary,
  validateMacosDistributionMetadata,
  validateMacosToolchainPreflight,
  validateProductionEntitlements,
} from "../../../tools/scripts/lib/macos-direct-distribution-policy.mjs";

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
const runnableRoot = path.join(workspaceRoot, "build", "apps", "desktop", "runnable", "macos", "release");
const runnableManifestRef = "package-metadata/licoup/packaging-modules.json";
const sourceInfoPlist = "apps/desktop/macos/Runner/Info.plist";
const sourceProductionEntitlements = "apps/desktop/macos/Runner/ProductionRelease.entitlements";
const sourceLocalEntitlements = "apps/desktop/macos/Runner/Release.entitlements";
const macosReleaseMaterialsRoot = path.join(
  workspaceRoot,
  "apps",
  "desktop",
  "packaging",
  "macos",
);
const privacyManifestSource = path.join(macosReleaseMaterialsRoot, "PrivacyInfo.xcprivacy");
const privacyPolicySource = path.join(macosReleaseMaterialsRoot, "LicoUp Privacy Policy.html");
const licenseSource = path.join(workspaceRoot, "LICENSE");
const openSourceNoticeSource = path.join(workspaceRoot, "NOTICE");
const commandOutputLimit = 1024 * 1024;
const thirdPartyNoticesLimit = 64 * 1024 * 1024;
const rustLicenseFilePattern = /^(?:license|licence|copying|notice)(?:[._-].*)?$/iu;
const rustFallbackLicenseMarkers = Object.freeze({
  "Apache-2.0": "Apache License",
  MIT: "Permission is hereby granted, free of charge",
  "MPL-2.0": "Mozilla Public License Version 2.0",
  Zlib: "This software is provided 'as-is'",
});

export class MacosDistributionError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function toolProbeArguments(tool) {
  if (tool === "xcodebuild") return ["-version"];
  if (tool === "notarytool") return ["--version"];
  if (tool === "plutil") return ["-help"];
  if (tool === "security") return ["help"];
  if (tool === "openssl") return ["version"];
  if (tool === "stapler" || tool === "codesign") return ["-h"];
  if (tool === "spctl") return ["--status"];
  if (tool === "hdiutil") return ["help"];
  return ["--help"];
}

function toolProbeSucceeded(tool, result, version) {
  if (result?.error || !Number.isInteger(result?.status) || version === "") return false;
  if (["xcodebuild", "notarytool", "openssl"].includes(tool)) {
    return result.status === 0;
  }
  if (tool === "codesign") {
    return [0, 1, 2, 64].includes(result.status);
  }
  // Several Apple command-line tools intentionally return a usage status for
  // help. Successful spawn plus bounded non-empty usage output proves the
  // resolved executable is runnable without performing a mutating operation.
  return [0, 1, 64].includes(result.status);
}

function boundedVersionText(result) {
  return `${String(result?.stdout || "")}\n${String(result?.stderr || "")}`
    .replace(/[^\x20-\x7E\r\n]/gu, "")
    .trim()
    .split(/\r?\n/u)[0]
    .slice(0, 256);
}

function parsePlistText(text) {
  try {
    return JSON.parse(text);
  } catch {
    throw new MacosDistributionError("macos_distribution_metadata_invalid");
  }
}

function defaultExecutor(program, args, options = {}) {
  return spawnSync(program, args, {
    encoding: "utf8",
    stdio: "pipe",
    maxBuffer: commandOutputLimit,
    timeout: 15 * 60 * 1000,
    ...options,
  });
}

function defaultHost() {
  return Object.freeze({
    platform: process.platform,
    arch: process.arch,
  });
}

function createToolEnvironment(env) {
  return minimalReleaseToolEnvironment(env, {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
  });
}

function environmentRecordProxy(env, record = () => {}) {
  return new Proxy(env, {
    get(target, prop, receiver) {
      if (typeof prop === "string" && MACOS_DIRECT_PROTECTED_ENVIRONMENT.includes(prop)) {
        record({ kind: "protected-env-read", name: prop });
        throw new MacosDistributionError("macos_distribution_protected_environment_read");
      }
      const value = Reflect.get(target, prop, receiver);
      if (typeof prop === "string") record({ kind: "env-read", name: prop });
      return value;
    },
    has(target, prop) {
      if (typeof prop === "string" && MACOS_DIRECT_PROTECTED_ENVIRONMENT.includes(prop)) {
        record({ kind: "protected-env-read", name: prop });
        throw new MacosDistributionError("macos_distribution_protected_environment_read");
      }
      return Reflect.has(target, prop);
    },
    getOwnPropertyDescriptor(target, prop) {
      if (typeof prop === "string" && MACOS_DIRECT_PROTECTED_ENVIRONMENT.includes(prop)) {
        record({ kind: "protected-env-read", name: prop });
        throw new MacosDistributionError("macos_distribution_protected_environment_read");
      }
      return Reflect.getOwnPropertyDescriptor(target, prop);
    },
  });
}

function requireEnvironment(env, name) {
  const value = String(env[name] || "").trim();
  if (!value) {
    throw new MacosDistributionError("macos_distribution_credentials_missing");
  }
  return value;
}

function requireContainedFile(fs, absolutePath, code) {
  if (!absolutePath || !path.isAbsolute(absolutePath) || !fs.exists(absolutePath)) {
    throw new MacosDistributionError(code);
  }
}

function distributionManifestPath(root = distributionRoot) {
  return path.join(root, "manifest.json");
}

function resolveBundleIdentifier(bundleIdentifier) {
  if (bundleIdentifier === "$(PRODUCT_BUNDLE_IDENTIFIER)") {
    return MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID;
  }
  return bundleIdentifier;
}

export function coordinatePreflight({
  env = process.env,
  host = defaultHost(),
  executor = defaultExecutor,
  fs = defaultFilesystem,
  record = () => {},
} = {}) {
  if (host.platform !== "darwin") {
    throw new MacosDistributionError("macos_distribution_host_unsupported");
  }
  const protectedEnv = environmentRecordProxy(env, record);
  const toolEnvironment = createToolEnvironment(protectedEnv);
  const tools = [];
  for (const tool of MACOS_DIRECT_TOOLCHAIN) {
    const discovered = executor("/usr/bin/xcrun", ["--find", tool], { env: toolEnvironment });
    const resolvedTool = String(discovered.stdout || "").trim();
    const found = discovered.status === 0 && path.isAbsolute(resolvedTool);
    let probed = false;
    let version = "";
    if (found) {
      const probeResult = executor(resolvedTool, toolProbeArguments(tool), { env: toolEnvironment });
      version = boundedVersionText(probeResult);
      if (toolProbeSucceeded(tool, probeResult, version)) {
        probed = true;
      }
    }
    const toolRecord = Object.freeze({ name: tool, found, probed, version });
    tools.push(toolRecord);
    record({ kind: "tool-discovery", name: tool, found, probed, version });
  }
  const plistResult = executor("/usr/bin/plutil", ["-convert", "json", "-o", "-", "--",
    path.join(workspaceRoot, sourceInfoPlist)], { env: toolEnvironment });
  if (plistResult.status !== 0) {
    throw new MacosDistributionError("macos_distribution_metadata_invalid");
  }
  const plist = parsePlistText(String(plistResult.stdout || "{}"));
  const metadata = validateMacosDistributionMetadata({
    displayName: plist.CFBundleDisplayName,
    bundleName: plist.CFBundleName,
    bundleIdentifier: resolveBundleIdentifier(plist.CFBundleIdentifier),
  });
  const productionEntitlements = validateProductionEntitlements(
    parsePlistText(readEntitlementsJson(executor, toolEnvironment, sourceProductionEntitlements, record)),
  );
  const localEntitlements = validateLocalEntitlements(
    parsePlistText(readEntitlementsJson(executor, toolEnvironment, sourceLocalEntitlements, record)),
  );
  const readiness = validateMacosToolchainPreflight(tools, metadata);
  const errors = [...readiness.errors];
  if (!metadata.ready) {
    errors.push(...metadata.errors);
  }
  if (!productionEntitlements.ready) {
    errors.push(...productionEntitlements.errors);
  }
  if (!localEntitlements.ready) {
    errors.push(...localEntitlements.errors);
  }
  const ready = readiness.ready && productionEntitlements.ready && localEntitlements.ready;
  return Object.freeze({
    ok: ready,
    ready,
    errors: Object.freeze([...new Set(errors)]),
    tools: readiness.tools,
    metadata: Object.freeze({
      ready: metadata.ready,
      displayName: metadata.displayName,
      bundleName: metadata.bundleName,
      bundleIdentifier: metadata.bundleIdentifier,
    }),
    entitlements: Object.freeze({
      production: Object.freeze({
        ready: productionEntitlements.ready,
        errors: productionEntitlements.errors,
      }),
      local: Object.freeze({
        ready: localEntitlements.ready,
        errors: localEntitlements.errors,
      }),
    }),
    privatePathsIncluded: false,
  });
}

function readEntitlementsJson(executor, toolEnvironment, sourceRef, record) {
  const sourcePath = path.join(workspaceRoot, sourceRef);
  record({ kind: "metadata-read", source: sourceRef });
  const result = executor("/usr/bin/plutil", ["-convert", "json", "-o", "-", "--", sourcePath],
    { env: toolEnvironment });
  if (result.status !== 0) {
    throw new MacosDistributionError("macos_distribution_entitlements_invalid");
  }
  return String(result.stdout || "{}");
}

function decodeProvisioningProfile(executor, toolEnvironment, profilePath) {
  const decoded = executor("/usr/bin/security", ["cms", "-D", "-i", profilePath], {
    env: toolEnvironment,
    maxBuffer: commandOutputLimit,
  });
  if (decoded.status !== 0) {
    throw new MacosDistributionError("macos_distribution_profile_invalid");
  }
  const profileXml = String(decoded.stdout || "");
  const extract = (key, format, { required = true } = {}) => {
    const result = executor(
      "/usr/bin/plutil",
      ["-extract", key, format, "-o", "-", "--", "-"],
      {
        env: toolEnvironment,
        input: profileXml,
        maxBuffer: commandOutputLimit,
      },
    );
    if (result.status !== 0 || result.error) {
      if (!required) return null;
      throw new MacosDistributionError("macos_distribution_profile_invalid");
    }
    return String(result.stdout || "").trim();
  };
  const parseExtractedJson = (key) => {
    try {
      return JSON.parse(extract(key, "json"));
    } catch (error) {
      if (error instanceof MacosDistributionError) throw error;
      throw new MacosDistributionError("macos_distribution_profile_invalid");
    }
  };
  const developerCertificates = [];
  const certificateLimit = 64;
  for (let index = 0; index < certificateLimit; index += 1) {
    const certificate = extract(`DeveloperCertificates.${index}`, "raw", {
      required: false,
    });
    if (certificate === null) break;
    developerCertificates.push(certificate);
  }
  if (developerCertificates.length === certificateLimit &&
    extract(`DeveloperCertificates.${certificateLimit}`, "raw", {
      required: false,
    }) !== null) {
    throw new MacosDistributionError("macos_distribution_profile_invalid");
  }
  return {
    Name: extract("Name", "raw", { required: false }) || "",
    UUID: extract("UUID", "raw", { required: false }) || "",
    ProvisionsAllDevices: extract("ProvisionsAllDevices", "raw", {
      required: false,
    }) === "true",
    DeveloperCertificates: developerCertificates,
    TeamIdentifier: parseExtractedJson("TeamIdentifier"),
    ExpirationDate: extract("ExpirationDate", "raw"),
    Entitlements: parseExtractedJson("Entitlements"),
  };
}

function inspectProvisioningProfileCertificates(profile, executor, toolEnvironment) {
  const certificates = Array.isArray(profile?.DeveloperCertificates)
    ? profile.DeveloperCertificates
    : [];
  if (certificates.length === 0) {
    throw new MacosDistributionError("macos_distribution_profile_not_developer_id");
  }
  return certificates.map((encodedCertificate) => {
    const encoded = String(encodedCertificate || "").replace(/\s+/gu, "");
    if (encoded === "" || encoded.length % 4 !== 0 ||
      !/^[A-Za-z0-9+/]+={0,2}$/u.test(encoded)) {
      throw new MacosDistributionError("macos_distribution_profile_invalid");
    }
    const certificate = Buffer.from(encoded, "base64");
    if (certificate.length === 0) {
      throw new MacosDistributionError("macos_distribution_profile_invalid");
    }
    const inspected = executor(
      "/usr/bin/openssl",
      ["x509", "-inform", "DER", "-noout", "-text", "-subject"],
      {
        env: toolEnvironment,
        input: certificate,
        maxBuffer: commandOutputLimit,
      },
    );
    if (inspected.status !== 0 || inspected.error) {
      throw new MacosDistributionError("macos_distribution_profile_invalid");
    }
    return developerIdCertificateEvidenceFromText(
      `${String(inspected.stdout || "")}\n${String(inspected.stderr || "")}`,
    );
  });
}

function readResolvedEntitlements(executor, toolEnvironment, entitlementsPath) {
  const converted = executor("/usr/bin/plutil", ["-convert", "json", "-o", "-", "--", entitlementsPath], {
    env: toolEnvironment,
  });
  if (converted.status !== 0) {
    throw new MacosDistributionError("macos_distribution_entitlements_invalid");
  }
  return parsePlistText(String(converted.stdout || "{}"));
}

function resolvedProductionEntitlementsTemplate(entitlements, identifierPrefix) {
  const prefix = String(identifierPrefix || "").trim();
  if (!/^[A-Z0-9]{10}\.$/u.test(prefix)) {
    throw new MacosDistributionError("macos_distribution_entitlements_invalid");
  }
  const resolved = JSON.stringify(entitlements)
    .replaceAll("$(AppIdentifierPrefix)", prefix)
    .replaceAll("$(PRODUCT_BUNDLE_IDENTIFIER)", MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID);
  if (resolved.includes("$(")) {
    throw new MacosDistributionError("macos_distribution_entitlements_invalid");
  }
  return parsePlistText(resolved);
}

function requireProfileAuthorization(authorization) {
  if (authorization.authorized) return authorization;
  const firstError = authorization.errors[0];
  throw new MacosDistributionError(
    firstError === "macos_distribution_profile_not_developer_id"
      ? "macos_distribution_profile_not_developer_id"
      : firstError === "macos_distribution_profile_expired"
        ? "macos_distribution_profile_expired"
        : firstError === "macos_distribution_profile_application_identifier_mismatch"
          ? "macos_distribution_profile_application_identifier_mismatch"
          : firstError === "macos_distribution_profile_team_mismatch"
            ? "macos_distribution_profile_team_mismatch"
            : "macos_distribution_entitlements_invalid",
  );
}

function requireValidProductionEntitlements(entitlements) {
  const validation = validateProductionEntitlements(entitlements);
  if (!validation.ready) {
    throw new MacosDistributionError("macos_distribution_entitlements_invalid");
  }
  return entitlements;
}

function plistStringValue(executor, toolEnvironment, plistPath, key) {
  const result = executor("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, plistPath], {
    env: toolEnvironment,
  });
  if (result.status !== 0) {
    throw new MacosDistributionError("macos_distribution_package_missing");
  }
  return String(result.stdout || "").trim();
}

const defaultFilesystem = Object.freeze({
  exists: (target) => existsSync(target),
  readText: (target) => readFileSync(target, "utf8"),
  readBuffer: (target) => readFileSync(target),
  writeText: (target, text) => writeFileSync(target, text, "utf8"),
  rm: (target, options = {}) => rmSync(target, options),
  mkdir: (target, options = {}) => mkdirSync(target, options),
  copyFile: (source, target) => copyFileSync(source, target),
  symlink: (source, target) => symlinkSync(source, target),
  rename: (source, target) => renameSync(source, target),
});

function embeddedProfilePath(appPath) {
  return path.join(appPath, "Contents", "embedded.provisionprofile");
}

function macosAppResourcesPath(appPath) {
  return path.join(appPath, "Contents", "Resources");
}

function flutterNoticesPath(appPath, fs) {
  const candidates = [
    path.join(
      appPath,
      "Contents",
      "Frameworks",
      "App.framework",
      "Resources",
      "flutter_assets",
      "NOTICES.Z",
    ),
    path.join(
      appPath,
      "Contents",
      "Frameworks",
      "App.framework",
      "Versions",
      "A",
      "Resources",
      "flutter_assets",
      "NOTICES.Z",
    ),
  ];
  const noticesPath = candidates.find((candidate) => fs.exists(candidate));
  if (!noticesPath) {
    throw new MacosDistributionError("macos_distribution_license_materials_missing");
  }
  return noticesPath;
}

function rustDependencyPackages(metadata) {
  const root = metadata.packages?.find((candidate) => candidate.name === "licoup-native");
  const nodes = new Map((metadata.resolve?.nodes || []).map((node) => [node.id, node]));
  const packages = new Map((metadata.packages || []).map((candidate) => [candidate.id, candidate]));
  if (!root || !nodes.has(root.id)) {
    throw new MacosDistributionError("macos_distribution_license_materials_invalid");
  }
  const visited = new Set();
  const pending = [root.id];
  while (pending.length > 0) {
    const id = pending.pop();
    if (visited.has(id)) continue;
    visited.add(id);
    for (const dependency of nodes.get(id)?.deps || []) {
      if ((dependency.dep_kinds || []).some((kind) => kind.kind !== "dev")) {
        pending.push(dependency.pkg);
      }
    }
  }
  return [...visited]
    .map((id) => packages.get(id))
    .filter((candidate) => candidate?.source)
    .sort((left, right) =>
      left.name.localeCompare(right.name) || left.version.localeCompare(right.version));
}

function rustPackageLicenseFiles(pkg) {
  const packageRoot = path.dirname(pkg.manifest_path);
  const candidates = new Set();
  if (pkg.license_file) {
    candidates.add(path.resolve(packageRoot, pkg.license_file));
  }
  for (const name of readdirSync(packageRoot)) {
    if (rustLicenseFilePattern.test(name)) candidates.add(path.join(packageRoot, name));
  }
  if (String(pkg.source || "").startsWith("git+")) {
    const workspaceParent = path.dirname(packageRoot);
    for (const name of readdirSync(workspaceParent)) {
      if (rustLicenseFilePattern.test(name)) candidates.add(path.join(workspaceParent, name));
    }
  }
  return [...candidates]
    .filter((candidate) => statSync(candidate).isFile())
    .sort((left, right) => path.basename(left).localeCompare(path.basename(right)));
}

function spdxLicenseIds(expression) {
  return new Set(String(expression || "").match(/[A-Za-z0-9][A-Za-z0-9.-]*/gu) || []);
}

export function rustThirdPartyNotices(architecture, executor = defaultExecutor) {
  const rustTarget = architecture === "arm64"
    ? "aarch64-apple-darwin"
    : "x86_64-apple-darwin";
  const cargoEnvironment = minimalReleaseToolEnvironment(process.env, {
    PATH: process.env.PATH,
  });
  const result = executor("cargo", [
    "metadata",
    "--locked",
    "--offline",
    "--format-version=1",
    "--filter-platform",
    rustTarget,
  ], {
    cwd: workspaceRoot,
    env: cargoEnvironment,
    timeout: 2 * 60 * 1000,
    maxBuffer: thirdPartyNoticesLimit,
  });
  if (result.error || result.status !== 0) {
    throw new MacosDistributionError("macos_distribution_license_materials_invalid");
  }
  let packages;
  try {
    packages = rustDependencyPackages(JSON.parse(String(result.stdout || "{}")));
  } catch (error) {
    if (error instanceof MacosDistributionError) throw error;
    throw new MacosDistributionError("macos_distribution_license_materials_invalid");
  }
  const documents = new Map();
  const packagesWithoutDocuments = [];
  let totalBytes = 0;
  for (const pkg of packages) {
    const files = rustPackageLicenseFiles(pkg);
    if (files.length === 0) packagesWithoutDocuments.push(pkg);
    for (const file of files) {
      const content = readFileSync(file, "utf8").trim();
      if (!content) continue;
      totalBytes += Buffer.byteLength(content);
      if (totalBytes > thirdPartyNoticesLimit) {
        throw new MacosDistributionError("macos_distribution_license_materials_invalid");
      }
      const digest = sha256Buffer(Buffer.from(content, "utf8"));
      const existing = documents.get(digest);
      if (existing) {
        existing.packages.add(`${pkg.name} ${pkg.version}`);
      } else {
        documents.set(digest, {
          fileName: path.basename(file),
          packages: new Set([`${pkg.name} ${pkg.version}`]),
          content,
        });
      }
    }
  }
  const combinedDocuments = [...documents.values()].map((document) => document.content).join("\n");
  for (const pkg of packagesWithoutDocuments) {
    const ids = spdxLicenseIds(pkg.license);
    const relevant = [...ids].filter((id) => Object.hasOwn(rustFallbackLicenseMarkers, id));
    if (relevant.length === 0 || !relevant.some((id) =>
      combinedDocuments.includes(rustFallbackLicenseMarkers[id]))) {
      throw new MacosDistributionError("macos_distribution_license_materials_invalid");
    }
  }
  const inventory = packages.map((pkg) =>
    `- ${pkg.name} ${pkg.version} — ${pkg.license || `license file: ${pkg.license_file}`}`);
  const licenseSections = [...documents.values()].map((document) => [
    "",
    "=".repeat(72),
    `Packages: ${[...document.packages].sort().join(", ")}`,
    `Source license file: ${document.fileName}`,
    "=".repeat(72),
    document.content,
  ].join("\n"));
  return [
    "Rust dependencies linked into LicoUp",
    "",
    "Resolved from the locked, target-filtered Cargo dependency graph.",
    "",
    ...inventory,
    ...licenseSections,
    "",
  ].join("\n");
}

export function installMacosReleaseMaterials(
  appPath,
  fs = defaultFilesystem,
  { architecture = process.arch === "arm64" ? "arm64" : "x64" } = {},
) {
  for (const source of [
    privacyManifestSource,
    privacyPolicySource,
    licenseSource,
    openSourceNoticeSource,
  ]) {
    requireContainedFile(fs, source, "macos_distribution_release_materials_missing");
  }
  const resources = macosAppResourcesPath(appPath);
  fs.mkdir(resources, { recursive: true });
  const materials = Object.freeze({
    privacyManifest: path.join(resources, "PrivacyInfo.xcprivacy"),
    privacyPolicy: path.join(resources, "LicoUp Privacy Policy.html"),
    license: path.join(resources, "LicoUp License.txt"),
    openSourceNotice: path.join(resources, "LicoUp Open Source Notice.txt"),
    thirdPartyNotices: path.join(resources, "Third-Party Notices.txt"),
  });
  fs.copyFile(privacyManifestSource, materials.privacyManifest);
  fs.copyFile(privacyPolicySource, materials.privacyPolicy);
  fs.copyFile(licenseSource, materials.license);
  fs.copyFile(openSourceNoticeSource, materials.openSourceNotice);
  try {
    const notices = decodeFlutterNotices(
      fs.readBuffer(flutterNoticesPath(appPath, fs)),
    );
    const rustNotices = rustThirdPartyNotices(architecture);
    const combinedNotices = [
      "Flutter and Dart dependencies",
      "",
      notices.toString("utf8").trim(),
      "",
      rustNotices.trim(),
      "",
    ].join("\n");
    if (Buffer.byteLength(combinedNotices) > thirdPartyNoticesLimit) {
      throw new MacosDistributionError("macos_distribution_license_materials_invalid");
    }
    fs.writeText(materials.thirdPartyNotices, combinedNotices);
  } catch (error) {
    if (error instanceof MacosDistributionError) throw error;
    throw new MacosDistributionError("macos_distribution_license_materials_invalid");
  }
  return materials;
}

export function decodeFlutterNotices(archive) {
  try {
    return unzipSync(archive, { maxOutputLength: thirdPartyNoticesLimit });
  } catch {
    throw new MacosDistributionError("macos_distribution_license_materials_invalid");
  }
}

function redactedCommandArgs(kind, args) {
  if (kind === "profile-embed") return Object.freeze(["Contents/embedded.provisionprofile"]);
  if (!["app-nested-sign", "app-sign", "dmg-sign"].includes(kind)) {
    return Object.freeze([]);
  }
  const safeFlags = new Set([
    "--options",
    "runtime",
    "--timestamp",
    "--timestamp=none",
    "--entitlements",
    "--deep",
  ]);
  return Object.freeze(args.map(String).filter((value) => safeFlags.has(value)));
}

export function coordinatePlatformChannel({
  env = process.env,
  host = defaultHost(),
  executor = defaultExecutor,
  fs = defaultFilesystem,
  record = () => {},
  packageRunnable = packageClient,
  inventoryCode = listMacosNestedCodePaths,
  inspectCodePolicy = inspectBoundedMacosCodePolicy,
  inspectContainerSignature = inspectMacosContainerSignature,
  inspectProfileCertificates = inspectProvisioningProfileCertificates,
  installReleaseMaterials = installMacosReleaseMaterials,
  hashFile = sha256,
  digestTree = artifactTreeDigest,
  now = Date.now,
} = {}) {
  if (host.platform !== "darwin") {
    throw new MacosDistributionError("macos_distribution_host_unsupported");
  }
  const sequence = [];
  const capture = (entry) => {
    const frozen = Object.freeze({
      kind: String(entry.kind),
      program: "",
      args: redactedCommandArgs(
        String(entry.kind),
        Array.isArray(entry.args) ? entry.args : [],
      ),
      ...(entry.failed === true ? { failed: true } : {}),
    });
    sequence.push(frozen);
    record(frozen);
    return frozen;
  };
  const toolEnvironment = createToolEnvironment(env);
  const run = (kind, program, args, code, options = {}) => {
    capture({ kind, program, args });
    let result;
    try {
      result = executor(program, args, {
        env: options.env || toolEnvironment,
        timeout: options.timeout ?? 15 * 60 * 1000,
        ...(options.input !== undefined ? { input: options.input } : {}),
        ...(options.maxBuffer !== undefined ? { maxBuffer: options.maxBuffer } : {}),
      });
    } catch {
      capture({ kind, program, args, failed: true });
      throw new MacosDistributionError(code);
    }
    if (result.status !== 0 || result.error) {
      capture({ kind, program, args, failed: true });
      throw new MacosDistributionError(code);
    }
    return result;
  };

  const identity = requireEnvironment(env, "LICO_MACOS_SIGNING_IDENTITY");
  const profilePath = requireEnvironment(env, "LICO_MACOS_PROVISIONING_PROFILE");
  requireContainedFile(fs, profilePath, "macos_distribution_credentials_missing");
  const keyId = requireEnvironment(env, "LICO_MACOS_NOTARY_KEY_ID");
  const issuer = requireEnvironment(env, "LICO_MACOS_NOTARY_ISSUER_ID");
  const keyPath = requireEnvironment(env, "LICO_MACOS_NOTARY_KEY_PATH");
  requireContainedFile(fs, keyPath, "macos_distribution_credentials_missing");
  const identifierPrefix = requireEnvironment(env, "LICO_MACOS_APP_IDENTIFIER_PREFIX");
  const signingKeychain = String(env.LICO_MACOS_RELEASE_SIGNING_KEYCHAIN || "").trim();
  const signingKeychainArgs = signingKeychain ? ["--keychain", signingKeychain] : [];

  const profile = decodeProvisioningProfile(executor, toolEnvironment, profilePath);
  const certificateEvidence = inspectProfileCertificates(profile, executor, toolEnvironment);
  const sourceEntitlements = parsePlistText(readEntitlementsJson(
    executor,
    toolEnvironment,
    sourceProductionEntitlements,
    () => {},
  ));
  const sourceResolvedEntitlements = requireValidProductionEntitlements(
    resolvedProductionEntitlementsTemplate(sourceEntitlements, identifierPrefix),
  );
  requireProfileAuthorization(authorizeProvisioningProfile(
    profile,
    sourceResolvedEntitlements,
    { now: now(), certificateEvidence },
  ));

  const manifestPath = distributionManifestPath();
  const runnableManifestPath = path.join(runnableRoot, runnableManifestRef);
  fs.rm(manifestPath, { force: true });
  fs.rm(runnableManifestPath, { force: true });
  capture({ kind: "stale-manifest-remove", program: "", args: [] });

  const packaged = packageRunnable([
    "--platform", "macos",
    "--mode", "release",
    "--production-entitlements",
  ]);
  const appPath = packaged?.runnable?.appPath;
  if (!appPath || !fs.exists(appPath) || !fs.exists(resolvedEntitlements)) {
    throw new MacosDistributionError("macos_distribution_package_missing");
  }
  const architecture = host.arch === "arm64" ? "arm64" : "x64";

  const entitlements = requireValidProductionEntitlements(
    readResolvedEntitlements(executor, toolEnvironment, resolvedEntitlements),
  );
  const authorization = requireProfileAuthorization(authorizeProvisioningProfile(
    profile,
    entitlements,
    {
    now: now(),
    certificateEvidence,
    },
  ));
  fs.copyFile(profilePath, embeddedProfilePath(appPath));
  capture({ kind: "profile-embed", program: "", args: ["Contents/embedded.provisionprofile"] });
  run(
    "privacy-manifest-validate",
    "/usr/bin/plutil",
    ["-lint", "--", privacyManifestSource],
    "macos_distribution_privacy_manifest_invalid",
  );
  const releaseMaterials = installReleaseMaterials(appPath, fs, { architecture });
  capture({ kind: "release-materials-stage", program: "", args: [] });

  const mainExecutableName = plistStringValue(
    executor,
    toolEnvironment,
    path.join(appPath, "Contents", "Info.plist"),
    "CFBundleExecutable",
  );
  const nestedCodePaths = inventoryCode(appPath, mainExecutableName);
  if (!Array.isArray(nestedCodePaths) || nestedCodePaths.length === 0) {
    throw new MacosDistributionError("macos_distribution_nested_signing_missing");
  }
  if (!validateMacosCameraPluginBoundary(nestedCodePaths).ready) {
    throw new MacosDistributionError("macos_distribution_camera_plugin_present");
  }
  for (const nestedPath of nestedCodePaths) {
    run("app-nested-sign", "/usr/bin/codesign", [
      "--force", "--options", "runtime", "--timestamp", ...signingKeychainArgs,
      "--sign", identity, nestedPath,
    ], "macos_distribution_codesign_failed");
  }
  run("app-sign", "/usr/bin/codesign", [
    "--force", "--options", "runtime", "--timestamp", ...signingKeychainArgs,
    "--sign", identity, "--entitlements", resolvedEntitlements, appPath,
  ], "macos_distribution_codesign_failed");
  run("app-signature-verify", "/usr/bin/codesign",
    ["--verify", "--deep", "--strict", "--verbose=2", appPath],
    "macos_distribution_signature_verify_failed");
  let inspectedAppSignature;
  try {
    const policy = inspectCodePolicy(appPath, mainExecutableName, resolvedEntitlements);
    const inspectedNestedPaths = Array.isArray(policy?.nestedCodePaths)
      ? policy.nestedCodePaths
      : [];
    const nestedInventoryMatches = inspectedNestedPaths.length === nestedCodePaths.length &&
      inspectedNestedPaths.every((entry, index) => entry === nestedCodePaths[index]);
    if (!policy?.signature?.verified ||
      policy?.signature?.signatureKind !== "local-identity-codesign" ||
      policy?.signature?.developerIdApplication !== true ||
      policy?.signature?.hardenedRuntime !== true ||
      policy?.signature?.secureTimestamp !== true ||
      policy?.signature?.teamIdentifier !== authorization.profile.teamIdentifier ||
      policy?.signerIdentityUniform !== true ||
      policy?.signature?.entitlementsMatch !== true ||
      !/^sha256:[a-f0-9]{64}$/u.test(String(policy?.signature?.signerFingerprint || "")) ||
      !nestedInventoryMatches ||
      !Array.isArray(policy?.nestedSignatures) ||
      policy.nestedSignatures.length !== nestedCodePaths.length ||
      !policy?.nestedSignatures?.every((entry, index) =>
        entry.path === nestedCodePaths[index] &&
        entry.signature?.verified === true &&
        entry.signature?.signatureKind === "local-identity-codesign" &&
        entry.signature?.signerFingerprint === policy.signature.signerFingerprint &&
        entry.signature?.developerIdApplication === true &&
        entry.signature?.hardenedRuntime === true &&
        entry.signature?.secureTimestamp === true &&
        entry.signature?.teamIdentifier === authorization.profile.teamIdentifier &&
        entry.signature?.entitlementsEmpty === true)) {
      throw new MacosDistributionError("macos_distribution_signature_verify_failed");
    }
    inspectedAppSignature = policy.signature;
  } catch (error) {
    if (error instanceof MacosDistributionError) throw error;
    throw new MacosDistributionError("macos_distribution_signature_verify_failed");
  }

  const submissionZip = path.join(os.tmpdir(), `lico-up-notary-app-${process.pid}.zip`);
  fs.rm(submissionZip, { force: true });
  run("app-notarize-submission", "/usr/bin/ditto",
    ["-c", "-k", "--keepParent", appPath, submissionZip],
    "macos_distribution_archive_failed");
  try {
    run("app-notarize", "/usr/bin/xcrun", [
      "notarytool", "submit", submissionZip,
      "--key", keyPath, "--key-id", keyId, "--issuer", issuer, "--wait",
    ], "macos_distribution_notarization_failed", { timeout: 30 * 60 * 1000 });
  } finally {
    fs.rm(submissionZip, { force: true });
  }
  run("app-staple", "/usr/bin/xcrun", ["stapler", "staple", appPath],
    "macos_distribution_staple_failed");
  run("app-staple-validate", "/usr/bin/xcrun", ["stapler", "validate", appPath],
    "macos_distribution_staple_verify_failed");
  run("app-gatekeeper", "/usr/sbin/spctl",
    ["--assess", "--type", "execute", "--verbose=2", appPath],
    "macos_distribution_gatekeeper_failed");

  const updateArchivePath = path.join(distributionRoot, `LicoUp-macos-${architecture}-update.zip`);
  fs.rm(updateArchivePath, { force: true });
  run("update-archive", "/usr/bin/ditto",
    ["-c", "-k", "--keepParent", appPath, updateArchivePath],
    "macos_distribution_archive_failed", {
      env: { ...toolEnvironment, COPYFILE_DISABLE: "1" },
    });
  const updateDigest = hashFile(updateArchivePath);
  fs.writeText(`${updateArchivePath}.sha256`,
    `${updateDigest}  ${path.basename(updateArchivePath)}\n`);

  const dmgPath = path.join(distributionRoot, `LicoUp-macos-${architecture}.dmg`);
  const dmgStage = path.join(os.tmpdir(), `licoup-dmg-stage-${process.pid}`);
  fs.rm(dmgPath, { force: true });
  fs.rm(dmgStage, { recursive: true, force: true });
  fs.mkdir(dmgStage, { recursive: true, mode: 0o700 });
  try {
    run("dmg-stage", "/usr/bin/ditto", [appPath, path.join(dmgStage, `${MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME}.app`)],
      "macos_distribution_dmg_stage_failed");
    for (const [source, name] of [
      [releaseMaterials.privacyPolicy, "LicoUp Privacy Policy.html"],
      [releaseMaterials.license, "LicoUp License.txt"],
      [releaseMaterials.openSourceNotice, "LicoUp Open Source Notice.txt"],
      [releaseMaterials.thirdPartyNotices, "Third-Party Notices.txt"],
    ]) {
      fs.copyFile(source, path.join(dmgStage, name));
    }
    fs.symlink("/Applications", path.join(dmgStage, "Applications"));
    run("dmg-create", "/usr/bin/hdiutil", [
      "create", "-quiet", "-ov", "-format", "UDZO",
      "-volname", MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME,
      "-srcfolder", dmgStage, dmgPath,
    ], "macos_distribution_dmg_create_failed");
  } finally {
    fs.rm(dmgStage, { recursive: true, force: true });
  }
  run("dmg-sign", "/usr/bin/codesign", [
    "--force", "--timestamp", ...signingKeychainArgs, "--sign", identity, dmgPath,
  ], "macos_distribution_dmg_sign_failed");
  run("dmg-notarize", "/usr/bin/xcrun", [
    "notarytool", "submit", dmgPath,
    "--key", keyPath, "--key-id", keyId, "--issuer", issuer, "--wait",
  ], "macos_distribution_notarization_failed", { timeout: 30 * 60 * 1000 });
  run("dmg-staple", "/usr/bin/xcrun", ["stapler", "staple", dmgPath],
    "macos_distribution_staple_failed");
  run("dmg-staple-validate", "/usr/bin/xcrun", ["stapler", "validate", dmgPath],
    "macos_distribution_staple_verify_failed");
  run("dmg-signature-verify", "/usr/bin/codesign", ["--verify", "--strict", dmgPath],
    "macos_distribution_dmg_signature_verify_failed");
  try {
    const containerSignature = inspectContainerSignature(dmgPath);
    if (containerSignature?.verified !== true ||
      containerSignature?.signatureKind !== "local-identity-codesign" ||
      containerSignature?.developerIdApplication !== true ||
      containerSignature?.secureTimestamp !== true ||
      containerSignature?.teamIdentifier !== authorization.profile.teamIdentifier ||
      containerSignature?.signerFingerprint !== inspectedAppSignature.signerFingerprint) {
      throw new MacosDistributionError("macos_distribution_dmg_signature_verify_failed");
    }
  } catch (error) {
    if (error instanceof MacosDistributionError) throw error;
    throw new MacosDistributionError("macos_distribution_dmg_signature_verify_failed");
  }
  run("dmg-image-verify", "/usr/bin/hdiutil", ["verify", "-quiet", dmgPath],
    "macos_distribution_dmg_verify_failed");
  run("dmg-gatekeeper", "/usr/sbin/spctl",
    ["--assess", "--type", "open", "--context", "context:primary-signature", dmgPath],
    "macos_distribution_gatekeeper_failed");

  const originalRunnableManifestText = fs.readText(runnableManifestPath);
  const runnableManifest = JSON.parse(originalRunnableManifestText);
  if (!/^sha256:[a-f0-9]{64}$/u.test(String(runnableManifest.sourceStateDigest || ""))) {
    throw new MacosDistributionError("macos_distribution_lineage_invalid");
  }
  const finalizedRunnableManifest = {
    ...runnableManifest,
    signing: {
      platform: "macos",
      signingKind: "developer-id-application",
      entitlementProfile: "production-release",
      productionEntitlementsRequested: true,
      hardenedRuntime: true,
      timestamped: true,
      notarized: true,
      stapled: true,
      gatekeeperVerified: true,
      githubReleaseBlocked: true,
    },
  };
  const finalizedRunnableManifestText =
    `${JSON.stringify(finalizedRunnableManifest, null, 2)}\n`;
  const clientVersion = JSON.parse(readFileSync(
    path.join(workspaceRoot, "tools", "client-version.json"),
    "utf8",
  ));
  if (!String(clientVersion.productVersion || "").trim() ||
    !Number.isInteger(clientVersion.buildNumber) || clientVersion.buildNumber <= 0) {
    throw new MacosDistributionError("macos_distribution_lineage_invalid");
  }
  const readiness = macosDistributionReadinessPolicy([
    ...sequence,
    { kind: "ready-manifest-write", program: "", args: [] },
  ]);
  if (!readiness.ready || !readiness.finalDmgVerified || !readiness.staleManifestRemoved) {
    throw new MacosDistributionError("macos_distribution_ready_claim_premature");
  }
  const claims = macosDistributionManifestClaims({
    platformChannelRequested: true,
    sequenceReady: true,
    signingKind: "developer-id-application",
  });
  const installArtifactDigest = digestTree(appPath);
  const bundleManifestDigest = sha256Buffer(Buffer.from(finalizedRunnableManifestText, "utf8"));
  const digest = hashFile(dmgPath);
  fs.writeText(`${dmgPath}.sha256`, `${digest}  ${path.basename(dmgPath)}\n`);
  const manifestPayload = {
    schemaVersion: "v0.0.1:client-macos:distribution-1",
    targetId: `macos-${architecture}`,
    platform: "macos",
    architecture,
    artifactReady: true,
    nonBlockingDistributionGuidance: {
      channelRequested: true,
      platformChannelReady: claims.platformChannelReady,
      githubReleaseBlocked: claims.githubReleaseBlocked,
    },
    productVersion: clientVersion.productVersion,
    buildNumber: clientVersion.buildNumber,
    sourceStateDigest: runnableManifest.sourceStateDigest,
    sourceStateDigestProvenance: runnableManifest.sourceStateDigestProvenance || "git-worktree",
    signingKind: claims.signingKind,
    entitlementProfile: "production-release",
    notarized: claims.notarized,
    stapled: claims.stapled,
    gatekeeperVerified: claims.gatekeeperVerified,
    privacyManifestIncluded: true,
    privacyPolicyIncluded: true,
    licenseMaterialsIncluded: true,
    archive: path.basename(dmgPath),
    sha256: digest,
    updateArchive: path.basename(updateArchivePath),
    updateSha256: updateDigest,
    installArtifactKind: "macos-app-bundle",
    installArtifactDigest,
    bundleManifestDigest,
  };
  const stagedManifest = `${manifestPath}.tmp-${process.pid}`;
  const stagedRunnableManifest = `${runnableManifestPath}.tmp-${process.pid}`;
  const restoreRunnableManifest = `${runnableManifestPath}.restore-${process.pid}`;
  fs.writeText(stagedManifest, `${JSON.stringify(manifestPayload, null, 2)}\n`);
  fs.writeText(stagedRunnableManifest, finalizedRunnableManifestText);
  let runnableManifestPublished = false;
  try {
    fs.rename(stagedRunnableManifest, runnableManifestPath);
    runnableManifestPublished = true;
    fs.rename(stagedManifest, manifestPath);
  } catch {
    fs.rm(stagedManifest, { force: true });
    fs.rm(stagedRunnableManifest, { force: true });
    if (runnableManifestPublished) {
      try {
        fs.writeText(restoreRunnableManifest, originalRunnableManifestText);
        fs.rename(restoreRunnableManifest, runnableManifestPath);
      } catch {
        fs.rm(restoreRunnableManifest, { force: true });
        fs.rm(runnableManifestPath, { force: true });
      }
    }
    fs.rm(manifestPath, { force: true });
    throw new MacosDistributionError("macos_distribution_manifest_invalid");
  }
  capture({ kind: "ready-manifest-write", program: "", args: [] });
  return Object.freeze({
    ok: true,
    targetId: `macos-${architecture}`,
    claims,
    archive: path.basename(dmgPath),
    updateArchive: path.basename(updateArchivePath),
    sequence: Object.freeze(sequence),
    privatePathsIncluded: false,
  });
}


function sha256(filePath) {
  return sha256File(filePath, {
    chunkBytes: 1024 * 1024,
    maxBytes: 8 * 1024 * 1024 * 1024,
  }).slice("sha256:".length);
}


function parseMode(argv) {
  const options = [...argv];
  const allowed = ["--preflight", "--platform-channel", "--self-test"];
  if (options.some((option) => !allowed.includes(option))) {
    throw new MacosDistributionError("macos_distribution_option_invalid");
  }
  const modes = options.filter((option) => option !== "--self-test");
  if (modes.length !== 1) {
    throw new MacosDistributionError("macos_distribution_option_invalid");
  }
  return Object.freeze({
    mode: modes[0],
    selfTest: options.includes("--self-test"),
  });
}

function main() {
  const { mode } = parseMode(process.argv.slice(2));
  if (mode === "--preflight") {
    const result = coordinatePreflight();
    console.log(JSON.stringify({
      ok: result.ready,
      ready: result.ready,
      tools: result.tools,
      metadata: result.metadata,
      entitlements: result.entitlements,
      privatePathsIncluded: false,
    }));
    if (!result.ready) process.exitCode = 1;
    return result;
  }
  if (mode === "--platform-channel") {
    const result = coordinatePlatformChannel();
    console.log(JSON.stringify({
      ok: true,
      targetId: result.targetId,
      signingKind: result.claims.signingKind,
      notarized: result.claims.notarized,
      stapled: result.claims.stapled,
      gatekeeperVerified: result.claims.gatekeeperVerified,
      privatePathsIncluded: false,
    }));
    return result;
  }
  throw new MacosDistributionError("macos_distribution_option_invalid");
}

async function runSelfTest() {
  const marker = "private-signing-identity-marker";
  let failure;
  try {
    defaultExecutor(process.execPath, [
      "-e",
      `process.stdout.write(${JSON.stringify(marker)});process.stderr.write(${JSON.stringify(marker)});process.exit(7)`,
    ], { timeout: 5_000 });
  } catch (error) {
    failure = error;
  }
  if (failure) {
    throw new Error("macos_distribution_marker_executor_should_not_throw");
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
  const noticesFixture = Buffer.from("synthetic flutter notices", "utf8");
  if (!decodeFlutterNotices(gzipSync(noticesFixture)).equals(noticesFixture)) {
    throw new Error("macos_distribution_flutter_notices_decode_failed");
  }

  const selfTest = await import("../../../tests/contract/client/macos-direct-distribution-self-test.mjs");
  const evidence = selfTest.runDistributionSelfTest({
    marker,
    adapters: {
      coordinatePlatformChannel,
      coordinatePreflight,
      MacosDistributionError,
    },
  });
  if (!evidence.ok) {
    throw new Error(evidence.code || "macos_distribution_self_test_failed");
  }
  console.log(JSON.stringify({
    ok: true,
    childOutputCapturedAndBounded: true,
    signingIdentityOutputAbsent: true,
    notaryCredentialOutputAbsent: true,
    minimalToolEnvironment: true,
    archiveHashStreaming: true,
    preflightIsolation: evidence.preflightIsolation,
    commandPartialOrder: evidence.commandPartialOrder,
    finalDmgFailureClosure: evidence.finalDmgFailureClosure,
    profileAuthorization: evidence.profileAuthorization,
    redaction: evidence.redaction,
    privatePathsIncluded: false,
  }));
}

if (process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2);
    if (args.includes("--self-test")) {
      if (args.length !== 1) {
        throw new MacosDistributionError("macos_distribution_option_invalid");
      }
      await runSelfTest();
    } else {
      main();
    }
  } catch (error) {
    const redacted = redactMacosDistributionFailure(error, {
      markers: ["private-signing-identity-marker"],
    });
    console.error(JSON.stringify({
      ok: false,
      code: redacted.code,
      privatePathsIncluded: false,
    }));
    process.exitCode = 1;
  }
}
