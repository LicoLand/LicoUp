#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

import { sha256Buffer, sha256File, stableReadFile } from "./lib/client-release-artifact-digest.mjs";
import { minimalReleaseToolEnvironment } from "./lib/release-tool-environment.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";
import {
  developerIdCertificateEvidenceFromText,
  MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID,
} from "./lib/macos-direct-distribution-policy.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const configSchema = "licoup.macos-local-release-config.v1";
const receiptSchema = "licoup.macos-internal-test-receipt.v1";
const notaryKeychainProfile = "licoup-macos-release";
const maximumCommandOutputBytes = 16 * 1024 * 1024;
const maximumProfileBytes = 4 * 1024 * 1024;
const distributionManifestPath = path.join(
  repoRoot,
  "build/apps/desktop/distribution/macos/manifest.json",
);
const artifactReceiptPath = path.join(
  repoRoot,
  "build/reports/client-macos-release-artifact-preflight.json",
);
const betaReceiptRef = "reports/client-macos-internal-test-receipt.json";
const betaReceiptPath = path.join(repoRoot, "build", betaReceiptRef);
const installedAppPath = "/Applications/LicoUp.app";
const templateRefs = Object.freeze([
  "apps/desktop/scripts/build-macos-distribution.mjs",
  "tools/scripts/client-macos-release-artifact-preflight.mjs",
  "tools/scripts/client-macos-release-tool.mjs",
  "tools/scripts/lib/macos-direct-distribution-policy.mjs",
]);

export const BETA_STAGE_ORDER = Object.freeze([
  "workspace",
  "source-gate",
  "release-policy",
  "distribution-preflight",
  "package",
  "artifact-install",
  "launch",
  "receipt",
]);

const managedConfigKeys = Object.freeze([
  "schemaVersion",
  "bundleIdentifier",
  "notaryKeychainProfile",
  "signingIdentity",
  "applicationIdentifierPrefix",
  "signerFingerprint",
  "profileDigest",
]);

export class MacosReleaseToolError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function fail(code) {
  throw new MacosReleaseToolError(code);
}

function safeStage(stage, status) {
  process.stdout.write(`${JSON.stringify({
    stage,
    status,
    privateDataIncluded: false,
  })}\n`);
}

function commandEnvironment(overrides = {}) {
  return minimalReleaseToolEnvironment(process.env, {
    PATH: process.env.PATH || "/usr/bin:/bin:/usr/sbin:/sbin",
    ...overrides,
  });
}

function runCapture(program, args, code, {
  env = commandEnvironment(),
  input,
  timeout = 15 * 60 * 1000,
} = {}) {
  const result = spawnSync(program, args, {
    cwd: repoRoot,
    env,
    encoding: "utf8",
    stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
    ...(input === undefined ? {} : { input }),
    timeout,
    maxBuffer: maximumCommandOutputBytes,
  });
  if (result.error || result.status !== 0) fail(code);
  return String(result.stdout || "");
}

function runInteractive(program, args, code) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    fail("macos_release_setup_terminal_required");
  }
  const result = spawnSync(program, args, {
    cwd: repoRoot,
    env: commandEnvironment(),
    stdio: "inherit",
    timeout: 15 * 60 * 1000,
  });
  if (result.error || result.status !== 0) fail(code);
}

function localReleaseRoot() {
  const home = path.resolve(os.homedir());
  if (!path.isAbsolute(home) || home === path.parse(home).root) {
    fail("macos_release_local_store_invalid");
  }
  return path.join(home, "Library", "Application Support", "LicoUp Developer", "macos-release");
}

function managedPaths(root = localReleaseRoot()) {
  return Object.freeze({
    root,
    config: path.join(root, "config.json"),
    profile: path.join(root, "developer-id.provisionprofile"),
  });
}

function preparePrivateRoot(root) {
  mkdirSync(root, { recursive: true, mode: 0o700 });
  chmodSync(root, 0o700);
  const info = lstatSync(root);
  if (!info.isDirectory() || info.isSymbolicLink() || realpathSync(root) !== path.resolve(root)) {
    fail("macos_release_local_store_invalid");
  }
}

function atomicWritePrivateFile(target, bytes) {
  const parent = path.dirname(target);
  preparePrivateRoot(parent);
  if (existsSync(target) && lstatSync(target).isSymbolicLink()) {
    fail("macos_release_local_store_invalid");
  }
  const temporary = path.join(parent, `.${path.basename(target)}.${process.pid}.tmp`);
  rmSync(temporary, { force: true });
  const descriptor = openSync(
    temporary,
    constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
    0o600,
  );
  try {
    writeFileSync(descriptor, bytes);
    fsyncSync(descriptor);
  } catch {
    rmSync(temporary, { force: true });
    fail("macos_release_local_store_write_failed");
  } finally {
    closeSync(descriptor);
  }
  try {
    chmodSync(temporary, 0o600);
    renameSync(temporary, target);
  } catch {
    rmSync(temporary, { force: true });
    fail("macos_release_local_store_write_failed");
  }
}

function resolveRegularFile(selected, maximumBytes, invalidCode) {
  if (!path.isAbsolute(selected) || !existsSync(selected)) {
    fail(invalidCode);
  }
  const resolved = realpathSync(selected);
  const info = statSync(resolved);
  if (!info.isFile() || info.size <= 0 || info.size > maximumBytes) {
    fail(invalidCode);
  }
  return resolved;
}

function chooseProvisioningProfile() {
  const selected = runCapture(
    "/usr/bin/osascript",
    ["-e", 'POSIX path of (choose file with prompt "Select the LicoUp Developer ID provisioning profile")'],
    "macos_release_setup_profile_selection_failed",
  ).trim();
  return resolveRegularFile(
    selected,
    maximumProfileBytes,
    "macos_release_setup_profile_selection_failed",
  );
}

export function extractProvisioningProfilePayload(xml) {
  const source = String(xml || "");
  const certificatePattern = /<key>\s*DeveloperCertificates\s*<\/key>\s*<array>([\s\S]*?)<\/array>/gu;
  const certificateMatches = [...source.matchAll(certificatePattern)];
  if (certificateMatches.length !== 1) fail("macos_release_setup_profile_invalid");

  const dataPattern = /<data>\s*([A-Za-z0-9+/=\s]+?)\s*<\/data>/gu;
  const certificateBlock = certificateMatches[0][1];
  const certificates = [...certificateBlock.matchAll(dataPattern)].map((match) =>
    match[1].replace(/\s+/gu, ""));
  if (certificates.length === 0 || certificates.length > 64 ||
    certificateBlock.replace(dataPattern, "").trim() !== "" ||
    certificates.some((encoded) => encoded.length % 4 !== 0 ||
      !/^[A-Za-z0-9+/]+={0,2}$/u.test(encoded) || Buffer.from(encoded, "base64").length === 0)) {
    fail("macos_release_setup_profile_invalid");
  }

  const derPattern = /<key>\s*DER-Encoded-Profile\s*<\/key>\s*<data>[\s\S]*?<\/data>/gu;
  const derMatches = [...source.matchAll(derPattern)];
  if (derMatches.length > 1) fail("macos_release_setup_profile_invalid");
  const sanitizedXml = source
    .replace(certificatePattern, "")
    .replace(derPattern, "")
    .replace(/<date>\s*([^<]+?)\s*<\/date>/gu, "<string>$1</string>");
  if (/<(?:data|date)(?:\s|>)/u.test(sanitizedXml)) {
    fail("macos_release_setup_profile_invalid");
  }
  return Object.freeze({
    sanitizedXml,
    developerCertificates: Object.freeze(certificates),
  });
}

function decodeProvisioningProfile(profilePath) {
  const xml = runCapture(
    "/usr/bin/security",
    ["cms", "-D", "-i", profilePath],
    "macos_release_setup_profile_invalid",
  );
  const payload = extractProvisioningProfilePayload(xml);
  const json = runCapture(
    "/usr/bin/plutil",
    ["-convert", "json", "-o", "-", "--", "-"],
    "macos_release_setup_profile_invalid",
    { input: payload.sanitizedXml },
  );
  try {
    return {
      ...JSON.parse(json),
      DeveloperCertificates: payload.developerCertificates,
    };
  } catch {
    fail("macos_release_setup_profile_invalid");
  }
}

function certificateFacts(profile) {
  const certificates = Array.isArray(profile?.DeveloperCertificates)
    ? profile.DeveloperCertificates
    : [];
  if (certificates.length === 0 || certificates.length > 64) {
    fail("macos_release_setup_profile_invalid");
  }
  return certificates.map((encoded) => {
    const normalized = String(encoded || "").replace(/\s+/gu, "");
    if (!normalized || normalized.length % 4 !== 0 ||
      !/^[A-Za-z0-9+/]+={0,2}$/u.test(normalized)) {
      fail("macos_release_setup_profile_invalid");
    }
    const der = Buffer.from(normalized, "base64");
    if (der.length === 0) fail("macos_release_setup_profile_invalid");
    const inspected = runCapture(
      "/usr/bin/openssl",
      ["x509", "-inform", "DER", "-noout", "-text", "-subject"],
      "macos_release_setup_profile_invalid",
      { input: der },
    );
    return Object.freeze({
      ...developerIdCertificateEvidenceFromText(inspected),
      sha1: createHash("sha1").update(der).digest("hex").toUpperCase(),
      sha256: sha256Buffer(der),
    });
  });
}

export function parseCodeSigningIdentities(output) {
  const identities = [];
  const pattern = /^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"\r\n]+)"\s*$/gmu;
  for (const match of String(output || "").matchAll(pattern)) {
    identities.push(Object.freeze({ sha1: match[1], name: match[2] }));
  }
  return Object.freeze(identities);
}

function profileTeam(profile) {
  const teams = Array.isArray(profile?.TeamIdentifier)
    ? profile.TeamIdentifier.map((entry) => String(entry || "").trim()).filter(Boolean)
    : [];
  return teams.length === 1 ? teams[0] : "";
}

export function deriveManagedReleaseConfig({
  profile,
  certificates,
  identities,
  profileDigest,
  now = Date.now(),
} = {}) {
  const team = profileTeam(profile);
  const applicationIdentifier = String(
    profile?.Entitlements?.["com.apple.application-identifier"] || "",
  ).trim();
  const prefixMatch = /^([A-Z0-9]{10})\.(.+)$/u.exec(applicationIdentifier);
  const expiration = new Date(String(profile?.ExpirationDate || "")).getTime();
  const certificateList = Array.isArray(certificates) ? certificates : [];
  const identityList = Array.isArray(identities) ? identities : [];
  if (profile?.ProvisionsAllDevices !== true || !/^[A-Z0-9]{10}$/u.test(team) ||
    !prefixMatch || prefixMatch[1] !== team ||
    prefixMatch[2] !== MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID ||
    !Number.isFinite(expiration) || expiration <= now || certificateList.length === 0 ||
    certificateList.some((entry) => entry?.developerIdApplication !== true ||
      entry?.teamIdentifier !== team || !/^[A-F0-9]{40}$/u.test(String(entry?.sha1 || "")) ||
      !/^sha256:[a-f0-9]{64}$/u.test(String(entry?.sha256 || ""))) ||
    !/^sha256:[a-f0-9]{64}$/u.test(String(profileDigest || ""))) {
    fail("macos_release_setup_profile_invalid");
  }
  const certificateBySha1 = new Map(certificateList.map((entry) => [entry.sha1, entry]));
  const matches = identityList.filter((identity) => {
    const name = String(identity?.name || "");
    return name.startsWith("Developer ID Application: ") &&
      name.endsWith(` (${team})`) && name.length <= 360 &&
      !name.includes("\r") && !name.includes("\n") &&
      certificateBySha1.has(String(identity?.sha1 || ""));
  });
  if (matches.length !== 1) fail("macos_release_setup_identity_ambiguous");
  const certificate = certificateBySha1.get(matches[0].sha1);
  return Object.freeze({
    schemaVersion: configSchema,
    bundleIdentifier: MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID,
    notaryKeychainProfile,
    signingIdentity: matches[0].sha1,
    applicationIdentifierPrefix: `${team}.`,
    signerFingerprint: certificate.sha256,
    profileDigest,
  });
}

export function validateManagedReleaseConfig(config) {
  if (!config || typeof config !== "object" || Array.isArray(config) ||
    JSON.stringify(Object.keys(config)) !== JSON.stringify(managedConfigKeys) ||
    config.schemaVersion !== configSchema ||
    config.bundleIdentifier !== MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID ||
    config.notaryKeychainProfile !== notaryKeychainProfile ||
    !/^[A-F0-9]{40}$/u.test(String(config.signingIdentity || "")) ||
    !/^[A-Z0-9]{10}\.$/u.test(String(config.applicationIdentifierPrefix || "")) ||
    !/^sha256:[a-f0-9]{64}$/u.test(String(config.signerFingerprint || "")) ||
    !/^sha256:[a-f0-9]{64}$/u.test(String(config.profileDigest || ""))) {
    fail("macos_release_local_config_invalid");
  }
  return Object.freeze({ ...config });
}

function readManagedReleaseConfig() {
  const refs = managedPaths();
  preparePrivateRoot(refs.root);
  for (const target of [refs.config, refs.profile]) {
    if (!existsSync(target) || lstatSync(target).isSymbolicLink() ||
      (statSync(target).mode & 0o077) !== 0) {
      fail("macos_release_setup_required");
    }
  }
  let parsed;
  try {
    parsed = JSON.parse(stableReadFile(refs.config, { maxBytes: 64 * 1024 }).toString("utf8"));
  } catch {
    fail("macos_release_local_config_invalid");
  }
  const config = validateManagedReleaseConfig(parsed);
  if (sha256File(refs.profile, { maxBytes: maximumProfileBytes }) !== config.profileDigest) {
    fail("macos_release_local_config_invalid");
  }
  return Object.freeze({ config, profilePath: refs.profile });
}

function codeSigningIdentities() {
  return parseCodeSigningIdentities(runCapture(
    "/usr/bin/security",
    ["find-identity", "-v", "-p", "codesigning"],
    "macos_release_setup_identity_missing",
  ));
}

function authorizeCodesignOnce(identity) {
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "licoup-codesign-setup-"));
  const probe = path.join(temporaryRoot, "probe");
  try {
    writeFileSync(probe, "#!/bin/sh\nexit 0\n", { encoding: "utf8", mode: 0o700 });
    runCapture(
      "/usr/bin/codesign",
      ["--force", "--timestamp=none", "--sign", identity, probe],
      "macos_release_setup_codesign_authorization_failed",
      { timeout: 5 * 60 * 1000 },
    );
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

function parseSetupOptions(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index];
    const value = args[index + 1];
    if (name !== "--profile" || !value || Object.hasOwn(options, name)) {
      fail("macos_release_option_invalid");
    }
    options[name] = value;
  }
  return Object.freeze({
    profilePath: options["--profile"],
  });
}

function runSetup(options = {}) {
  if (process.platform !== "darwin") fail("macos_release_host_unsupported");
  safeStage("distribution-preflight", "running");
  runCapture(
    process.execPath,
    ["apps/desktop/scripts/build-macos-distribution.mjs", "--preflight"],
    "macos_release_distribution_preflight_failed",
  );
  safeStage("distribution-preflight", "passed");

  const selectedProfile = options.profilePath
    ? resolveRegularFile(
      options.profilePath,
      maximumProfileBytes,
      "macos_release_setup_profile_invalid",
    )
    : chooseProvisioningProfile();
  const profileBytes = stableReadFile(selectedProfile, { maxBytes: maximumProfileBytes });
  const profile = decodeProvisioningProfile(selectedProfile);
  const config = deriveManagedReleaseConfig({
    profile,
    certificates: certificateFacts(profile),
    identities: codeSigningIdentities(),
    profileDigest: sha256Buffer(profileBytes),
  });

  safeStage("notary-credentials", "running");
  runInteractive(
    "/usr/bin/xcrun",
    ["notarytool", "store-credentials", notaryKeychainProfile, "--validate"],
    "macos_release_setup_notary_credentials_failed",
  );
  safeStage("notary-credentials", "passed");

  safeStage("codesign-authorization", "running");
  authorizeCodesignOnce(config.signingIdentity);
  safeStage("codesign-authorization", "passed");

  const refs = managedPaths();
  atomicWritePrivateFile(refs.profile, profileBytes);
  atomicWritePrivateFile(refs.config, `${JSON.stringify(config, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify({
    ok: true,
    configured: true,
    keychainBackedNotarization: true,
    oneTimeCodesignAuthorizationCompleted: true,
    privateDataIncluded: false,
  })}\n`);
}

function gitValue(args, code) {
  return runCapture("/usr/bin/git", args, code, { timeout: 60_000 }).trim();
}

function requireCleanWorkspace() {
  if (gitValue(["status", "--porcelain=v1", "--untracked-files=all"],
    "macos_release_workspace_check_failed") !== "") {
    fail("macos_release_workspace_dirty");
  }
  const revision = gitValue(["rev-parse", "HEAD"], "macos_release_workspace_check_failed");
  const tree = gitValue(["write-tree"], "macos_release_workspace_check_failed");
  if (!/^[a-f0-9]{40,64}$/u.test(revision) || !/^[a-f0-9]{40,64}$/u.test(tree)) {
    fail("macos_release_workspace_check_failed");
  }
  return Object.freeze({ revision, tree });
}

function releaseEnvironment(config, profilePath) {
  return commandEnvironment({
    LICO_MACOS_SIGNING_IDENTITY: config.signingIdentity,
    LICO_MACOS_PROVISIONING_PROFILE: profilePath,
    LICO_MACOS_NOTARY_KEYCHAIN_PROFILE: config.notaryKeychainProfile,
    LICO_MACOS_APP_IDENTIFIER_PREFIX: config.applicationIdentifierPrefix,
    LICO_MACOS_RELEASE_SIGNER_SHA256: config.signerFingerprint,
  });
}

function readBoundedJson(target, code, maxBytes = 1024 * 1024) {
  try {
    return JSON.parse(stableReadFile(target, { maxBytes }).toString("utf8"));
  } catch {
    fail(code);
  }
}

function releaseVersion() {
  const version = readBoundedJson(
    path.join(repoRoot, "tools/client-version.json"),
    "macos_release_version_invalid",
    64 * 1024,
  );
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(String(version.productVersion || "")) ||
    !Number.isSafeInteger(version.buildNumber) || version.buildNumber < 1) {
    fail("macos_release_version_invalid");
  }
  return Object.freeze({
    productVersion: version.productVersion,
    buildNumber: version.buildNumber,
  });
}

function releaseTemplateDigest() {
  const hash = createHash("sha256");
  for (const ref of templateRefs) {
    hash.update(ref);
    hash.update("\0");
    hash.update(stableReadFile(path.join(repoRoot, ref), { maxBytes: 4 * 1024 * 1024 }));
    hash.update("\0");
  }
  return `sha256:${hash.digest("hex")}`;
}

function buildBetaReceipt(source, version) {
  const manifest = readBoundedJson(
    distributionManifestPath,
    "macos_release_distribution_manifest_invalid",
  );
  const artifactReceipt = readBoundedJson(
    artifactReceiptPath,
    "macos_release_artifact_receipt_invalid",
  );
  const digest = String(manifest.sha256 || "");
  if (manifest.schemaVersion !== "v0.0.1:client-macos:distribution-1" ||
    manifest.targetId !== "macos-arm64" || manifest.artifactReady !== true ||
    manifest.productVersion !== version.productVersion ||
    manifest.buildNumber !== version.buildNumber ||
    !/^[a-f0-9]{64}$/u.test(digest) || manifest.notarized !== true ||
    manifest.stapled !== true || manifest.gatekeeperVerified !== true ||
    artifactReceipt.schemaVersion !== "licoup.client-macos-release-artifact-preflight.v1" ||
    artifactReceipt.archiveDigest !== `sha256:${digest}` ||
    artifactReceipt.installedFromExactArtifact !== true ||
    artifactReceipt.launchStable !== true ||
    artifactReceipt.nestedCodeIdentityUniform !== true ||
    !/^sha256:[a-f0-9]{64}$/u.test(String(artifactReceipt.installedAppDigest || ""))) {
    fail("macos_release_artifact_receipt_invalid");
  }
  return Object.freeze({
    schemaVersion: receiptSchema,
    channel: "local-internal-test",
    sourceRevision: source.revision,
    sourceTree: source.tree,
    productVersion: version.productVersion,
    buildNumber: version.buildNumber,
    releaseTemplateDigest: releaseTemplateDigest(),
    artifactDigest: `sha256:${digest}`,
    distributionManifestDigest: sha256File(distributionManifestPath, { maxBytes: 1024 * 1024 }),
    installedArtifactDigest: artifactReceipt.installedAppDigest,
    checks: {
      sourceGate: true,
      releasePolicy: true,
      developerIdSigned: true,
      appNotarizedAndStapled: true,
      dmgNotarizedAndStapled: true,
      gatekeeperAccepted: true,
      exactArtifactInstalled: true,
      stableLaunchVerified: true,
    },
    publicationRequested: false,
    remoteMutation: false,
    privacy: {
      redacted: true,
      absolutePathsIncluded: false,
      accountDataIncluded: false,
      credentialsIncluded: false,
      identityMaterialIncluded: false,
      rawOutputIncluded: false,
    },
  });
}

function runBeta() {
  if (process.platform !== "darwin" || process.arch !== "arm64") {
    fail("macos_release_host_unsupported");
  }
  const { config, profilePath } = readManagedReleaseConfig();
  const env = releaseEnvironment(config, profilePath);
  rmSync(betaReceiptPath, { force: true });

  safeStage(BETA_STAGE_ORDER[0], "running");
  const source = requireCleanWorkspace();
  const version = releaseVersion();
  safeStage(BETA_STAGE_ORDER[0], "passed");

  const commands = [
    ["source-gate", ["tools/scripts/client-gate.mjs", "run", "source"],
      "macos_release_source_gate_failed", commandEnvironment()],
    ["release-policy", ["tools/scripts/client-gate.mjs", "run", "release-policy"],
      "macos_release_policy_gate_failed", commandEnvironment()],
    ["distribution-preflight",
      ["apps/desktop/scripts/build-macos-distribution.mjs", "--preflight"],
      "macos_release_distribution_preflight_failed", commandEnvironment()],
    ["package", ["apps/desktop/scripts/build-macos-distribution.mjs", "--platform-channel"],
      "macos_release_package_failed", env],
    ["artifact-install", ["tools/scripts/client-macos-release-artifact-preflight.mjs"],
      "macos_release_artifact_install_failed", env],
  ];
  for (const [stage, args, code, stageEnvironment] of commands) {
    safeStage(stage, "running");
    runCapture(process.execPath, args, code, {
      env: stageEnvironment,
      timeout: stage === "package" ? 2 * 60 * 60 * 1000 : 45 * 60 * 1000,
    });
    safeStage(stage, "passed");
  }

  safeStage("launch", "running");
  runCapture("/usr/bin/open", ["-n", installedAppPath], "macos_release_launch_failed");
  safeStage("launch", "passed");

  safeStage("receipt", "running");
  const finalSource = requireCleanWorkspace();
  if (finalSource.revision !== source.revision || finalSource.tree !== source.tree) {
    fail("macos_release_source_changed");
  }
  const receipt = buildBetaReceipt(source, version);
  atomicWriteReportJson(path.join(repoRoot, "build"), betaReceiptRef, receipt);
  safeStage("receipt", "passed");
  process.stdout.write(`${JSON.stringify({
    ok: true,
    channel: receipt.channel,
    productVersion: receipt.productVersion,
    buildNumber: receipt.buildNumber,
    artifactDigest: receipt.artifactDigest,
    installed: true,
    launched: true,
    publicationRequested: false,
    remoteMutation: false,
    privateDataIncluded: false,
  })}\n`);
}

export function redactMacosReleaseToolFailure(error) {
  const candidate = String(error?.code || "");
  return Object.freeze({
    ok: false,
    code: /^macos_release_[a-z0-9_]+$/u.test(candidate)
      ? candidate
      : "macos_release_tool_failed",
    privateDataIncluded: false,
  });
}

export function main(args = process.argv.slice(2)) {
  if (args[0] === "setup") return runSetup(parseSetupOptions(args.slice(1)));
  if (args.length === 1 && args[0] === "beta") return runBeta();
  fail("macos_release_option_invalid");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${JSON.stringify(redactMacosReleaseToolFailure(error))}\n`);
    process.exitCode = 1;
  }
}
