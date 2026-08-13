// Synthetic command-recording regression shared by the macOS direct
// distribution CLI self-test and the focused policy contract.  This module
// never touches Apple services, credentials, or the real filesystem.

import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  authorizeProvisioningProfile,
  developerIdCertificateEvidenceFromText,
  MACOS_DIRECT_COMMAND_KINDS,
  MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID,
  MACOS_DIRECT_PROTECTED_ENVIRONMENT,
  MACOS_DIRECT_TOOLCHAIN,
  macosDistributionFailureCode,
  macosDistributionReadinessPolicy,
  redactMacosDistributionFailure,
  validateLocalEntitlements,
  validateMacosDirectCommandSequence,
  validateMacosDistributionMetadata,
  validateMacosToolchainPreflight,
  validateProductionEntitlements,
} from "../../../tools/scripts/lib/macos-direct-distribution-policy.mjs";

// The CLI module owns the procedural coordinator; this regression must not
// statically import it, because the CLI dynamically imports this module while
// its own top-level await is still evaluating (a circular-import deadlock).
// The CLI injects its coordinator, preflight, and error class at run time.
let distributionAdapters = Object.freeze({
  coordinatePlatformChannel: null,
  coordinatePreflight: null,
  MacosDistributionError: null,
});

function requiredAdapter(name) {
  const value = distributionAdapters[name];
  if (!value) throw new Error("macos_distribution_adapters_missing");
  return value;
}

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const distributionRoot = path.join(repoRoot, "build", "apps", "desktop", "distribution", "macos");
const manifestPath = path.join(distributionRoot, "manifest.json");
const runnableRoot = path.join(repoRoot, "build", "apps", "desktop", "runnable", "macos", "release");
const appPath = path.join(runnableRoot, "LicoUp.app");
const resolvedEntitlementsPath = path.join(
  repoRoot,
  "build", "apps", "desktop", "signing", "macos", "release",
  "ProductionRelease.resolved.entitlements",
);
const runnableManifestPath = path.join(
  runnableRoot,
  "package-metadata", "licoup", "packaging-modules.json",
);
const syntheticInputRoot = path.join(
  repoRoot,
  "build",
  "synthetic-macos-distribution-inputs",
);
const embeddedProfileRef = path.join("Contents", "embedded.provisionprofile");

const FIXED_NOW = Date.parse("2026-08-11T00:00:00.000Z");
const sourceDigest = `sha256:${"a".repeat(64)}`;
const fingerprint = `sha256:${"b".repeat(64)}`;
const syntheticCertificate = Buffer.from("synthetic-public-certificate").toString("base64");

export function certificateEvidenceFixture(variant = "matching") {
  if (variant === "non-developer-id") {
    return Object.freeze([Object.freeze({
      developerIdApplication: false,
      teamIdentifier: "TEAM123456",
    })]);
  }
  return Object.freeze([Object.freeze({
    developerIdApplication: true,
    teamIdentifier: variant === "team-mismatch" ? "OTHER999999" : "TEAM123456",
  })]);
}

export const productionEntitlementsFixture = Object.freeze({
  "com.apple.application-identifier": "TEAM123456.land.lico.licoup",
  "keychain-access-groups": ["TEAM123456.land.lico.licoup"],
  "com.apple.security.network.client": true,
  "com.apple.security.files.user-selected.read-only": true,
});

export const localEntitlementsFixture = Object.freeze({
  "com.apple.security.network.client": true,
  "com.apple.security.files.user-selected.read-only": true,
});

const plistMetadataFixture = Object.freeze({
  CFBundleName: "LicoUp",
  CFBundleDisplayName: "LicoUp",
  CFBundleIdentifier: "$(PRODUCT_BUNDLE_IDENTIFIER)",
});

function matchingProfileFixture() {
  return {
    Name: "LicoUp Developer ID Profile",
    UUID: "11111111-2222-3333-4444-555555555555",
    ProvisionsAllDevices: true,
    DeveloperCertificates: [syntheticCertificate],
    TeamIdentifier: ["TEAM123456"],
    ExpirationDate: "2027-01-01T00:00:00.000Z",
    Entitlements: {
      "com.apple.application-identifier": "TEAM123456.land.lico.licoup",
      "keychain-access-groups": ["TEAM123456.land.lico.licoup"],
    },
  };
}

export function profileVariant(variant) {
  const base = matchingProfileFixture();
  switch (variant) {
    case "expired":
      return { ...base, ExpirationDate: "2020-01-01T00:00:00.000Z" };
    case "non-developer-id":
      return { ...base, ProfileType: "DeveloperID", DeveloperCertificates: [] };
    case "app-id-mismatch":
      return {
        ...base,
        Entitlements: {
          "com.apple.application-identifier": "TEAM123456.other.bundle",
          "keychain-access-groups": ["TEAM123456.other.bundle"],
        },
      };
    case "keychain-mismatch":
      return {
        ...base,
        Entitlements: {
          "com.apple.application-identifier": "TEAM123456.land.lico.licoup",
          "keychain-access-groups": ["TEAM123456.different.group"],
        },
      };
    case "team-mismatch":
      return { ...base, TeamIdentifier: ["OTHER999999"] };
    default:
      return base;
  }
}

function virtualFilesystem(initial = {}) {
  const files = new Map(Object.entries(initial));
  const operations = [];
  const fs = {
    exists: (target) => files.has(target),
    readText: (target) => {
      operations.push({ kind: "fs-read", path: target });
      if (!files.has(target)) throw new Error("virtual file missing");
      return files.get(target);
    },
    writeText: (target, text) => {
      operations.push({ kind: "fs-write", path: target });
      files.set(target, text);
    },
    rm: (target, options = {}) => {
      operations.push({ kind: "fs-rm", path: target, force: options.force === true });
      if (!options.force && !files.has(target)) throw new Error("virtual file missing");
      files.delete(target);
    },
    mkdir: (target, options = {}) => {
      operations.push({ kind: "fs-mkdir", path: target });
    },
    copyFile: (source, target) => {
      operations.push({ kind: "fs-copy", source, target });
      if (!files.has(source)) throw new Error("virtual source missing");
      files.set(target, files.get(source));
    },
    symlink: (source, target) => {
      operations.push({ kind: "fs-symlink", source, target });
      files.set(target, `symlink:${source}`);
    },
    rename: (source, target) => {
      operations.push({ kind: "fs-rename", source, target });
      if (!files.has(source)) throw new Error("virtual source missing");
      files.set(target, files.get(source));
      files.delete(source);
    },
  };
  return { fs, operations, files };
}

function classifyCommand(program, args) {
  const base = path.basename(String(program));
  const has = (value) => args.includes(value);
  const dmgArg = args.find((arg) => typeof arg === "string" && arg.endsWith(".dmg"));
  const zipArg = args.find((arg) =>
    typeof arg === "string" && arg.endsWith(".zip"));
  if (base === "xcrun" && args[0] === "notarytool") {
    return dmgArg ? "dmg-notarize" : "app-notarize";
  }
  if (base === "xcrun" && args[0] === "stapler") {
    if (args[1] === "validate") {
      return dmgArg ? "dmg-staple-validate" : "app-staple-validate";
    }
    return dmgArg ? "dmg-staple" : "app-staple";
  }
  if (base === "stapler") {
    if (args[0] === "validate") {
      return dmgArg ? "dmg-staple-validate" : "app-staple-validate";
    }
    return dmgArg ? "dmg-staple" : "app-staple";
  }
  if (base === "codesign") {
    if (has("--verify")) {
      return dmgArg ? "dmg-signature-verify" : "app-signature-verify";
    }
    if (dmgArg) return "dmg-sign";
    if (has("--entitlements")) return "app-sign";
    return "app-nested-sign";
  }
  if (base === "hdiutil") {
    return args[0] === "verify" ? "dmg-image-verify" : "dmg-create";
  }
  if (base === "spctl") {
    const typeIndex = args.indexOf("--type");
    return typeIndex >= 0 && args[typeIndex + 1] === "open"
      ? "dmg-gatekeeper"
      : "app-gatekeeper";
  }
  if (base === "ditto") {
    if (!has("-c")) return "dmg-stage";
    return zipArg && zipArg.includes("-update.zip")
      ? "update-archive"
      : "app-notarize-submission";
  }
  return "other";
}

function syntheticExecutor({
  failures = {},
  profileVariantName = "matching",
  plists = {},
  missingTools = [],
  failedProbes = [],
} = {}) {
  const executed = [];
  const byPath = new Map(Object.entries(plists));
  function plistFor(plistPath) {
    if (byPath.has(plistPath)) return byPath.get(plistPath);
    const base = path.basename(String(plistPath));
    if (base === "Info.plist") return plistMetadataFixture;
    if (base === "ProductionRelease.entitlements") return productionEntitlementsFixture;
    if (base === "Release.entitlements") return localEntitlementsFixture;
    if (base === "ProductionRelease.resolved.entitlements") {
      return productionEntitlementsFixture;
    }
    return null;
  }
  return function executor(program, args, options = {}) {
    executed.push({ program: String(program), args: [...args] });
    const base = path.basename(String(program));
    if (base === "xcrun" && args[0] === "--find") {
      const tool = args[1];
      if (missingTools.includes(tool)) {
        return { status: 1, stdout: "", stderr: "not found" };
      }
      return { status: 0, stdout: `/usr/bin/${tool}\n`, stderr: "" };
    }
    if (base === "plutil" && args[0] === "-convert" && args[1] === "json") {
      const targetIndex = args.indexOf("--");
      const target = args[targetIndex + 1];
      if (target === "-") {
        return {
          status: 0,
          stdout: String(options.input || "{}"),
          stderr: "",
        };
      }
      const fixture = plistFor(target);
      if (fixture === null) return { status: 1, stdout: "", stderr: "unreadable" };
      return { status: 0, stdout: JSON.stringify(fixture), stderr: "" };
    }
    if (base === "security" && args[0] === "cms") {
      return {
        status: 0,
        stdout: JSON.stringify(profileVariant(profileVariantName)),
        stderr: "",
      };
    }
    if (base === "openssl" && args[0] === "x509") {
      const evidence = certificateEvidenceFixture(profileVariantName)[0];
      const oid = evidence?.developerIdApplication
        ? "1.2.840.113635.100.6.1.13"
        : "1.2.840.113635.100.6.1.4";
      return {
        status: 0,
        stdout: `Certificate:\n  ${oid}\nsubject=CN = Synthetic, OU = ${evidence?.teamIdentifier || "TEAM123456"}\n`,
        stderr: "",
      };
    }
    if (base === "PlistBuddy") {
      return { status: 0, stdout: "licoup\n", stderr: "" };
    }
    if (base === "spctl" && args[0] === "--help") {
      return { status: 2, stdout: "", stderr: "unsupported option" };
    }
    const isProbe = MACOS_DIRECT_TOOLCHAIN.includes(base) &&
      ["-version", "--version", "-help", "help", "version", "-h", "--help", "--status"]
        .includes(args[0]);
    if (isProbe) {
      if (failedProbes.includes(base)) {
        return { status: 1, stdout: "", stderr: "" };
      }
      const usageStatus = base === "codesign"
        ? 2
        : ["xcodebuild", "notarytool", "openssl", "spctl"].includes(base) ? 0 : 1;
      return { status: usageStatus, stdout: `${base} synthetic probe\n`, stderr: "" };
    }
    const kind = classifyCommand(String(program), args);
    if (Object.hasOwn(failures, kind)) {
      return { status: 1, stdout: "", stderr: "injected synthetic failure" };
    }
    return { status: 0, stdout: "", stderr: "" };
  };
}

function requireValue(condition, code) {
  if (!condition) throw new Error(code);
}

function canonicalKinds(sequence) {
  const kinds = [];
  for (const entry of sequence) {
    const kind = String(entry?.kind || "");
    if (MACOS_DIRECT_COMMAND_KINDS.includes(kind) && !kinds.includes(kind)) {
      kinds.push(kind);
    }
  }
  return kinds;
}

function assertPreflightIsolation(marker) {
  const record = [];
  const env = Object.freeze({
    HOME: "fixture-home",
    USER: "fixture",
    LOGNAME: "fixture",
    LANG: "en_US.UTF-8",
    TMPDIR: "fixture-tmp",
    LICO_MACOS_SIGNING_IDENTITY: marker,
    LICO_MACOS_PROVISIONING_PROFILE: marker,
    LICO_MACOS_NOTARY_KEY_ID: marker,
    LICO_MACOS_NOTARY_ISSUER_ID: marker,
    LICO_MACOS_NOTARY_KEY_PATH: marker,
    LICO_MACOS_RELEASE_SIGNING_IDENTITY: marker,
    LICO_MACOS_RELEASE_SIGNING_KEYCHAIN: marker,
  });
  const { fs, operations } = virtualFilesystem();
  const result = requiredAdapter("coordinatePreflight")({
    env,
    host: { platform: "darwin", arch: "arm64" },
    executor: syntheticExecutor(),
    fs,
    record: (entry) => record.push(entry),
  });
  requireValue(result.ready === true && result.ok === true,
    "preflight_readiness_false");
  const discovered = record.filter((entry) => entry.kind === "tool-discovery");
  requireValue(discovered.length === MACOS_DIRECT_TOOLCHAIN.length &&
    MACOS_DIRECT_TOOLCHAIN.every((name) =>
      discovered.some((entry) => entry.name === name && entry.found === true &&
        entry.probed === true)),
  "preflight_toolset_incomplete");
  requireValue(!record.some((entry) => entry.kind === "protected-env-read"),
    "preflight_protected_env_read");
  requireValue(operations.length === 0,
    "preflight_fs_mutation");
  requireValue(result.tools.length === MACOS_DIRECT_TOOLCHAIN.length &&
    result.tools.every((tool) => tool.found === true && tool.probed === true && tool.version),
  "preflight_tool_report_incomplete");
  requireValue(result.metadata.displayName === "LicoUp" &&
    result.metadata.bundleIdentifier === MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID,
  "preflight_metadata_invalid");
  requireValue(result.entitlements.production.ready === true &&
    result.entitlements.local.ready === true,
  "preflight_entitlements_invalid");

  const missingRecord = [];
  const missingResult = requiredAdapter("coordinatePreflight")({
    env,
    host: { platform: "darwin", arch: "arm64" },
    executor: syntheticExecutor({ missingTools: ["notarytool"] }),
    fs,
    record: (entry) => missingRecord.push(entry),
  });
  requireValue(missingResult.ready === false &&
    missingResult.errors.includes("macos_distribution_tool_missing"),
  "preflight_missing_tool_not_fail_closed");

  const failedProbe = requiredAdapter("coordinatePreflight")({
    env,
    host: { platform: "darwin", arch: "arm64" },
    executor: syntheticExecutor({ failedProbes: ["notarytool"] }),
    fs,
    record: () => {},
  });
  requireValue(failedProbe.ready === false &&
    failedProbe.errors.includes("macos_distribution_tool_missing") &&
    failedProbe.tools.find((tool) => tool.name === "notarytool")?.found === true &&
    failedProbe.tools.find((tool) => tool.name === "notarytool")?.probed === false,
  "preflight_failed_probe_not_fail_closed");

  const badMetadataResult = requiredAdapter("coordinatePreflight")({
    env,
    host: { platform: "darwin", arch: "arm64" },
    executor: syntheticExecutor({
      plists: {
        [path.join(repoRoot, "apps/desktop/macos/Runner/Info.plist")]: {
          CFBundleName: "LicoUp",
          CFBundleDisplayName: "Arc",
          CFBundleIdentifier: "land.lico.licoup",
        },
      },
    }),
    fs,
    record: () => {},
  });
  requireValue(badMetadataResult.ready === false &&
    badMetadataResult.errors.includes("macos_distribution_display_name_invalid"),
  "preflight_bad_metadata_not_fail_closed");
}

function fullCommandSequence() {
  return MACOS_DIRECT_COMMAND_KINDS.map((kind) => {
    if (kind === "app-nested-sign") {
      return {
        kind,
        args: ["--force", "--options", "runtime", "--timestamp", "--sign", "identity", "fixture/app/nested"],
      };
    }
    if (kind === "app-sign") {
      return {
        kind,
        args: ["--force", "--options", "runtime", "--timestamp", "--sign", "identity",
          "--entitlements", "fixture/app/entitlements.plist", "fixture/app/LicoUp.app"],
      };
    }
    if (kind === "dmg-sign") {
      return { kind, args: ["--force", "--timestamp", "--sign", "identity", "fixture/out/LicoUp.dmg"] };
    }
    return { kind, args: [] };
  });
}

function assertCommandPartialOrder() {
  requireValue(validateMacosDirectCommandSequence(fullCommandSequence()).ready === true,
    "canonical_sequence_rejected");

  const appSignWithDeep = fullCommandSequence().map((command) =>
    command.kind === "app-sign"
      ? { ...command, args: [...command.args, "--deep"] }
      : command);
  requireValue(
    validateMacosDirectCommandSequence(appSignWithDeep)
      .errors.includes("macos_distribution_codesign_deep_sign_forbidden"),
    "deep_sign_not_forbidden");

  const nestedSignWithDeep = fullCommandSequence().map((command) =>
    command.kind === "app-nested-sign"
      ? { ...command, args: [...command.args, "--deep"] }
      : command);
  requireValue(
    validateMacosDirectCommandSequence(nestedSignWithDeep)
      .errors.includes("macos_distribution_codesign_deep_sign_forbidden"),
    "nested_deep_sign_not_forbidden");

  const nestedWithEntitlements = fullCommandSequence().map((command) =>
    command.kind === "app-nested-sign"
      ? { ...command, args: [...command.args, "--entitlements", "fixture/entitlements.plist"] }
      : command);
  requireValue(
    validateMacosDirectCommandSequence(nestedWithEntitlements)
      .errors.includes("macos_distribution_entitlements_invalid"),
    "nested_entitlements_not_rejected");

  const noRuntime = fullCommandSequence().map((command) =>
    command.kind === "app-sign"
      ? { ...command, args: command.args.filter((arg) => arg !== "runtime") }
      : command);
  requireValue(
    validateMacosDirectCommandSequence(noRuntime)
      .errors.includes("macos_distribution_signing_order_invalid"),
    "missing_runtime_not_rejected");

  const noTimestamp = fullCommandSequence().map((command) =>
    command.kind === "app-nested-sign"
      ? { ...command, args: command.args.filter((arg) => arg !== "--timestamp") }
      : command);
  requireValue(
    validateMacosDirectCommandSequence(noTimestamp)
      .errors.includes("macos_distribution_signing_order_invalid"),
    "missing_timestamp_not_rejected");

  const dmgTimestampNone = fullCommandSequence().map((command) =>
    command.kind === "dmg-sign"
      ? { ...command, args: ["--force", "--timestamp=none", "--sign", "identity", "fixture/out/LicoUp.dmg"] }
      : command);
  requireValue(
    validateMacosDirectCommandSequence(dmgTimestampNone)
      .errors.includes("macos_distribution_ready_claim_premature"),
    "timestamp_none_not_rejected");

  const missingKinds = fullCommandSequence().filter((command) =>
    command.kind !== "dmg-gatekeeper");
  requireValue(
    validateMacosDirectCommandSequence(missingKinds)
      .errors.includes("macos_distribution_command_sequence_incomplete"),
    "missing_kind_not_rejected");

  const claimNotLast = [...fullCommandSequence().slice(0, -1),
    { kind: "dmg-gatekeeper", args: [] },
    { kind: "ready-manifest-write", args: [] },
    { kind: "app-gatekeeper", args: [] }];
  requireValue(
    validateMacosDirectCommandSequence(claimNotLast)
      .errors.includes("macos_distribution_ready_claim_not_last"),
    "claim_not_last_not_rejected");

  const nestedAfterApp = fullCommandSequence().map((command) =>
    command.kind === "app-nested-sign"
      ? { kind: "app-nested-sign", args: command.args }
      : command);
  nestedAfterApp.splice(
    nestedAfterApp.findIndex((command) => command.kind === "app-sign") + 1,
    0,
    { kind: "app-nested-sign", args: ["--force"] },
  );
  requireValue(
    validateMacosDirectCommandSequence(nestedAfterApp)
      .errors.includes("macos_distribution_signing_order_invalid"),
    "nested_after_app_not_rejected");
}

function assertProfileAuthorization() {
  const matching = authorizeProvisioningProfile(
    profileVariant("matching"),
    productionEntitlementsFixture,
    { now: FIXED_NOW, certificateEvidence: certificateEvidenceFixture("matching") },
  );
  requireValue(matching.authorized === true && matching.errors.length === 0,
    "matching_profile_rejected");
  for (const [variant, expected] of [
    ["non-developer-id", "macos_distribution_profile_not_developer_id"],
    ["expired", "macos_distribution_profile_expired"],
    ["app-id-mismatch", "macos_distribution_profile_application_identifier_mismatch"],
    ["keychain-mismatch", "macos_distribution_profile_keychain_group_mismatch"],
    ["team-mismatch", "macos_distribution_profile_team_mismatch"],
  ]) {
    const denied = authorizeProvisioningProfile(
      profileVariant(variant),
      productionEntitlementsFixture,
      { now: FIXED_NOW, certificateEvidence: certificateEvidenceFixture(variant) },
    );
    requireValue(denied.authorized === false && denied.errors.includes(expected),
      `profile_${variant}_not_rejected`);
  }
  const ambiguous = authorizeProvisioningProfile(
    {
      ...profileVariant("matching"),
      ProfileType: "DeveloperID",
      DeveloperCertificates: [],
    },
    productionEntitlementsFixture,
    { now: FIXED_NOW, certificateEvidence: [] },
  );
  requireValue(ambiguous.authorized === false &&
    ambiguous.errors.includes("macos_distribution_profile_not_developer_id"),
  "ambiguous_all_devices_profile_not_rejected");
  const ambiguousTeam = authorizeProvisioningProfile(
    {
      ...profileVariant("matching"),
      TeamIdentifier: ["TEAM123456", "OTHER999999"],
    },
    productionEntitlementsFixture,
    { now: FIXED_NOW, certificateEvidence: certificateEvidenceFixture("matching") },
  );
  requireValue(ambiguousTeam.authorized === false &&
    ambiguousTeam.errors.includes("macos_distribution_profile_not_developer_id"),
  "ambiguous_profile_team_not_rejected");
  const parsedEvidence = developerIdCertificateEvidenceFromText(
    "Certificate:\n  1.2.840.113635.100.6.1.13\nsubject=CN = Synthetic, OU = TEAM123456\n",
  );
  requireValue(parsedEvidence.developerIdApplication === true &&
    parsedEvidence.teamIdentifier === "TEAM123456",
  "developer_id_certificate_evidence_not_parsed");
  const withGetTaskAllow = {
    ...productionEntitlementsFixture,
    "get-task-allow": true,
  };
  requireValue(!validateProductionEntitlements(withGetTaskAllow).ready,
    "get_task_allow_not_rejected");
  const withLibraryValidation = {
    ...productionEntitlementsFixture,
    "com.apple.security.cs.disable-library-validation": true,
  };
  requireValue(!validateProductionEntitlements(withLibraryValidation).ready,
    "disable_library_validation_not_rejected");
  requireValue(validateLocalEntitlements(localEntitlementsFixture).ready === true,
    "local_entitlements_rejected");
  requireValue(!validateLocalEntitlements({
    "com.apple.security.cs.disable-library-validation": true,
  }).ready, "local_library_validation_not_rejected");
  requireValue(validateMacosDistributionMetadata({
    displayName: "LicoUp",
    bundleName: "LicoUp",
    bundleIdentifier: "land.lico.licoup",
  }).ready === true, "valid_metadata_rejected");
}

function greenCodePolicy(inventory) {
  return {
    signature: {
      verified: true,
      signatureKind: "local-identity-codesign",
      signerFingerprint: fingerprint,
      developerIdApplication: true,
      hardenedRuntime: true,
      secureTimestamp: true,
      teamIdentifier: "TEAM123456",
      entitlementsMatch: true,
    },
    signerIdentityUniform: true,
    nestedCodePaths: [...inventory],
    nestedSignatures: inventory.map((nestedPath) => ({
      path: nestedPath,
      signature: {
        verified: true,
        signatureKind: "local-identity-codesign",
        signerFingerprint: fingerprint,
        developerIdApplication: true,
        hardenedRuntime: true,
        secureTimestamp: true,
        teamIdentifier: "TEAM123456",
        entitlementsEmpty: true,
      },
    })),
  };
}

function greenContainerSignature() {
  return {
    verified: true,
    signatureKind: "local-identity-codesign",
    signerFingerprint: fingerprint,
    developerIdApplication: true,
    secureTimestamp: true,
    teamIdentifier: "TEAM123456",
  };
}

export function platformChannelHarness({
  failures = {},
  profileVariantName = "matching",
  inventory = [path.join(appPath, "Contents", "Frameworks", "FlutterMacOS.framework", "FlutterMacOS")],
  inspectPolicy = () => greenCodePolicy(inventory),
  inspectContainer = () => greenContainerSignature(),
  plists = {},
  runnableSourceDigest = sourceDigest,
} = {}) {
  const sequence = [];
  const profilePath = path.join(syntheticInputRoot, "licoup.provisionprofile");
  const notaryKeyPath = path.join(syntheticInputRoot, "licoup-notary-key.p8");
  const virtual = virtualFilesystem({
    [appPath]: "",
    [resolvedEntitlementsPath]: JSON.stringify(productionEntitlementsFixture),
    [runnableManifestPath]: JSON.stringify({
      sourceStateDigest: runnableSourceDigest,
      sourceStateDigestProvenance: "git-worktree",
      signing: {
        notarized: true,
        stapled: true,
        gatekeeperVerified: true,
      },
    }),
    [profilePath]: "der-profile",
    [notaryKeyPath]: "notary-key",
    [manifestPath]: "stale-ready-manifest",
  });
  const env = Object.freeze({
    HOME: "fixture-home",
    LICO_MACOS_SIGNING_IDENTITY: "Developer ID Application: LicoUp (TEAM123456)",
    LICO_MACOS_APP_IDENTIFIER_PREFIX: "TEAM123456.",
    LICO_MACOS_PROVISIONING_PROFILE: profilePath,
    LICO_MACOS_NOTARY_KEY_ID: "NOTARY-KEY-ID",
    LICO_MACOS_NOTARY_ISSUER_ID: "ISSUER-ID",
    LICO_MACOS_NOTARY_KEY_PATH: notaryKeyPath,
  });
  const run = () => requiredAdapter("coordinatePlatformChannel")({
    env,
    host: { platform: "darwin", arch: "arm64" },
    executor: syntheticExecutor({ failures, profileVariantName, plists }),
    fs: virtual.fs,
    record: (entry) => sequence.push(entry),
    packageRunnable: () => {
      virtual.fs.writeText(runnableManifestPath, JSON.stringify({
        sourceStateDigest: runnableSourceDigest,
        sourceStateDigestProvenance: "git-worktree",
      }));
      return { runnable: { root: runnableRoot, appPath } };
    },
    inventoryCode: () => inventory,
    inspectCodePolicy: inspectPolicy,
    inspectContainerSignature: inspectContainer,
    installReleaseMaterials: (targetAppPath, fs) => {
      const resources = path.join(targetAppPath, "Contents", "Resources");
      fs.mkdir(resources, { recursive: true });
      const materials = {
        privacyManifest: path.join(resources, "PrivacyInfo.xcprivacy"),
        privacyPolicy: path.join(resources, "LicoUp Privacy Policy.html"),
        license: path.join(resources, "LicoUp License.txt"),
        openSourceNotice: path.join(resources, "LicoUp Open Source Notice.txt"),
        thirdPartyNotices: path.join(resources, "Third-Party Notices.txt"),
      };
      for (const target of Object.values(materials)) {
        fs.writeText(target, "synthetic release material");
      }
      return materials;
    },
    now: () => FIXED_NOW,
  });
  return { run, sequence, virtual };
}

function assertFinalDmgFailureClosure() {
  const failureCodes = {
    "dmg-sign": "macos_distribution_dmg_sign_failed",
    "dmg-notarize": "macos_distribution_notarization_failed",
    "dmg-staple": "macos_distribution_staple_failed",
    "dmg-staple-validate": "macos_distribution_staple_verify_failed",
    "dmg-signature-verify": "macos_distribution_dmg_signature_verify_failed",
    "dmg-image-verify": "macos_distribution_dmg_verify_failed",
    "dmg-gatekeeper": "macos_distribution_gatekeeper_failed",
  };
  for (const [kind, expectedCode] of Object.entries(failureCodes)) {
    const harness = platformChannelHarness({ failures: { [kind]: "fail" } });
    let thrown = null;
    try {
      harness.run();
    } catch (error) {
      thrown = error;
    }
    requireValue(thrown instanceof requiredAdapter("MacosDistributionError") &&
      thrown.code === expectedCode,
    `final_dmg_${kind}_wrong_failure`);
    requireValue(!harness.virtual.files.has(manifestPath),
      `final_dmg_${kind}_left_ready_manifest`);
    const runnableAfterFailure = JSON.parse(
      harness.virtual.files.get(runnableManifestPath),
    );
    requireValue(runnableAfterFailure.signing?.notarized !== true &&
      runnableAfterFailure.signing?.stapled !== true,
    `final_dmg_${kind}_left_runnable_ready_claim`);
    const readiness = macosDistributionReadinessPolicy(harness.sequence);
    requireValue(readiness.ready === false,
      `final_dmg_${kind}_claimed_ready`);
  }

  const appFailure = platformChannelHarness({ failures: { "app-notarize": "fail" } });
  let appThrown = null;
  try {
    appFailure.run();
  } catch (error) {
    appThrown = error;
  }
  requireValue(appThrown instanceof requiredAdapter("MacosDistributionError") &&
    appThrown.code === "macos_distribution_notarization_failed",
  "app_notarize_wrong_failure");
  requireValue(!appFailure.virtual.files.has(manifestPath),
    "app_notarize_left_ready_manifest");

  const allGreen = platformChannelHarness();
  const result = allGreen.run();
  requireValue(result.ok === true, "all_green_not_ready");
  requireValue(allGreen.virtual.files.has(manifestPath),
    "all_green_missing_manifest");
  const manifest = JSON.parse(allGreen.virtual.files.get(manifestPath));
  requireValue(manifest.artifactReady === true &&
    manifest.signingKind === "developer-id-application" &&
    manifest.notarized === true && manifest.stapled === true &&
    manifest.gatekeeperVerified === true &&
    manifest.nonBlockingDistributionGuidance?.platformChannelReady === true &&
    manifest.nonBlockingDistributionGuidance?.githubReleaseBlocked === true &&
    manifest.privacyManifestIncluded === true &&
    manifest.privacyPolicyIncluded === true &&
    manifest.licenseMaterialsIncluded === true,
  "all_green_claims_incorrect");
  const kinds = canonicalKinds(allGreen.sequence);
  requireValue(JSON.stringify(kinds) === JSON.stringify(MACOS_DIRECT_COMMAND_KINDS),
    "all_green_command_order_wrong");
  requireValue(allGreen.sequence[0]?.kind === "stale-manifest-remove",
    "stale_manifest_not_removed_first");
  requireValue(allGreen.sequence[allGreen.sequence.length - 1]?.kind ===
    "ready-manifest-write", "ready_manifest_not_last");
  const appNotarizeIndex = allGreen.sequence.findIndex((entry) => entry.kind === "app-notarize");
  const updateArchiveIndex = allGreen.sequence.findIndex((entry) => entry.kind === "update-archive");
  const dmgSignIndex = allGreen.sequence.findIndex((entry) => entry.kind === "dmg-sign");
  const dmgNotarizeIndex = allGreen.sequence.findIndex((entry) => entry.kind === "dmg-notarize");
  requireValue(appNotarizeIndex >= 0 && updateArchiveIndex >= 0 &&
    appNotarizeIndex < updateArchiveIndex,
  "update_archive_not_after_app_notarize");
  requireValue(dmgSignIndex >= 0 && dmgNotarizeIndex > dmgSignIndex,
    "dmg_notarize_not_after_dmg_sign");
  requireValue(!allGreen.sequence.some((entry) =>
    entry.kind === "app-sign" && entry.args.includes("--deep")),
  "app_deep_sign_present");
  requireValue(!allGreen.sequence.some((entry) =>
    entry.kind === "dmg-sign" && entry.args.includes("--timestamp=none")),
  "dmg_timestamp_none_present");
  requireValue(allGreen.sequence.some((entry) =>
    entry.kind === "profile-embed" &&
    entry.args.includes("Contents/embedded.provisionprofile")),
  "profile_not_embedded");
  requireValue(allGreen.virtual.operations.some((operation) =>
    operation.kind === "fs-copy" &&
    String(operation.target).endsWith(embeddedProfileRef)),
  "profile_copy_not_recorded");
  for (const name of [
    "LicoUp Privacy Policy.html",
    "LicoUp License.txt",
    "LicoUp Open Source Notice.txt",
    "Third-Party Notices.txt",
  ]) {
    requireValue(allGreen.virtual.operations.some((operation) =>
      operation.kind === "fs-copy" &&
      String(operation.target).endsWith(name)),
    `dmg_release_material_missing_${name}`);
  }
  requireValue(allGreen.virtual.operations.some((operation) =>
    operation.kind === "fs-rm" && operation.path === manifestPath &&
    operation.force === true),
  "stale_manifest_removal_not_recorded");
  requireValue(allGreen.virtual.operations.some((operation) =>
    operation.kind === "fs-rm" && operation.path === runnableManifestPath &&
    operation.force === true),
  "stale_runnable_claim_removal_not_recorded");
  const serializedSequence = JSON.stringify(allGreen.sequence);
  for (const privateValue of [
    syntheticInputRoot,
    "Developer ID Application: LicoUp",
    "NOTARY-KEY-ID",
    "ISSUER-ID",
    fingerprint,
  ]) {
    requireValue(!serializedSequence.includes(privateValue),
      "recorded_sequence_contains_private_input");
  }

  for (const variant of ["app-id-mismatch", "expired", "non-developer-id"]) {
    const mismatched = platformChannelHarness({ profileVariantName: variant });
    let thrown = null;
    try {
      mismatched.run();
    } catch (error) {
      thrown = error;
    }
    requireValue(thrown instanceof requiredAdapter("MacosDistributionError"),
      `profile_${variant}_coordinator_did_not_fail`);
    const embeddedCopy = mismatched.virtual.operations.some((operation) =>
      operation.kind === "fs-copy" &&
      String(operation.target).endsWith(embeddedProfileRef));
    requireValue(!embeddedCopy,
      `profile_${variant}_embedded_despite_denial`);
    requireValue(!mismatched.virtual.operations.some((operation) =>
      ["fs-rm", "fs-write", "fs-mkdir", "fs-copy", "fs-symlink", "fs-rename"]
        .includes(operation.kind)),
    `profile_${variant}_mutated_before_authorization`);
  }

  const invalidProductionEntitlements = platformChannelHarness({
    plists: {
      [path.join(repoRoot, "apps/desktop/macos/Runner/ProductionRelease.entitlements")]: {
        ...productionEntitlementsFixture,
        "get-task-allow": true,
      },
    },
  });
  let invalidEntitlementsThrown = null;
  try {
    invalidProductionEntitlements.run();
  } catch (error) {
    invalidEntitlementsThrown = error;
  }
  requireValue(invalidEntitlementsThrown instanceof requiredAdapter("MacosDistributionError") &&
    invalidEntitlementsThrown.code === "macos_distribution_entitlements_invalid",
  "invalid_production_entitlements_not_fail_closed");
  requireValue(!invalidProductionEntitlements.virtual.operations.some((operation) =>
    ["fs-rm", "fs-write", "fs-mkdir", "fs-copy", "fs-symlink", "fs-rename"]
      .includes(operation.kind)),
  "invalid_production_entitlements_mutated_before_authorization");

  const lateLineageFailure = platformChannelHarness({ runnableSourceDigest: "invalid" });
  let lateLineageThrown = null;
  try {
    lateLineageFailure.run();
  } catch (error) {
    lateLineageThrown = error;
  }
  requireValue(lateLineageThrown instanceof requiredAdapter("MacosDistributionError") &&
    lateLineageThrown.code === "macos_distribution_lineage_invalid",
  "late_lineage_failure_not_fail_closed");
  requireValue(!lateLineageFailure.virtual.files.has(manifestPath),
    "late_lineage_failure_left_distribution_claim");
  const lateRunnable = JSON.parse(
    lateLineageFailure.virtual.files.get(runnableManifestPath),
  );
  requireValue(lateRunnable.signing?.notarized !== true &&
    lateRunnable.signing?.stapled !== true,
  "late_lineage_failure_left_runnable_ready_claim");

  const emptyInventory = platformChannelHarness({ inventory: [] });
  let emptyThrown = null;
  try {
    emptyInventory.run();
  } catch (error) {
    emptyThrown = error;
  }
  requireValue(emptyThrown instanceof requiredAdapter("MacosDistributionError") &&
    emptyThrown.code === "macos_distribution_nested_signing_missing",
  "empty_inventory_not_fail_closed");

  const nonUniform = platformChannelHarness({
    inspectPolicy: () => ({
      signature: {
        verified: true,
        signatureKind: "local-identity-codesign",
        signerFingerprint: fingerprint,
        hardenedRuntime: true,
        entitlementsMatch: true,
      },
      signerIdentityUniform: false,
      nestedSignatures: [],
    }),
  });
  let nonUniformThrown = null;
  try {
    nonUniform.run();
  } catch (error) {
    nonUniformThrown = error;
  }
  requireValue(nonUniformThrown instanceof requiredAdapter("MacosDistributionError") &&
    nonUniformThrown.code === "macos_distribution_signature_verify_failed",
  "non_uniform_signer_not_fail_closed");

  for (const field of ["developerIdApplication", "hardenedRuntime", "secureTimestamp"]) {
    const outerPolicy = greenCodePolicy([
      path.join(appPath, "Contents", "Frameworks", "Nested.framework"),
    ]);
    outerPolicy.signature[field] = false;
    const harness = platformChannelHarness({ inspectPolicy: () => outerPolicy });
    let thrown = null;
    try { harness.run(); } catch (error) { thrown = error; }
    requireValue(thrown instanceof requiredAdapter("MacosDistributionError") &&
      thrown.code === "macos_distribution_signature_verify_failed",
    `outer_${field}_not_fail_closed`);
  }

  for (const field of [
    "developerIdApplication",
    "hardenedRuntime",
    "secureTimestamp",
    "entitlementsEmpty",
  ]) {
    const nestedPolicy = greenCodePolicy([
      path.join(appPath, "Contents", "Frameworks", "Nested.framework"),
    ]);
    nestedPolicy.nestedSignatures[0].signature[field] = false;
    const harness = platformChannelHarness({ inspectPolicy: () => nestedPolicy });
    let thrown = null;
    try { harness.run(); } catch (error) { thrown = error; }
    requireValue(thrown instanceof requiredAdapter("MacosDistributionError") &&
      thrown.code === "macos_distribution_signature_verify_failed",
    `nested_${field}_not_fail_closed`);
  }

  const inventoryMismatch = greenCodePolicy([
    path.join(appPath, "Contents", "Frameworks", "Nested.framework"),
  ]);
  inventoryMismatch.nestedCodePaths[0] = path.join(
    appPath,
    "Contents",
    "Frameworks",
    "Different.framework",
  );
  const mismatchedInventoryHarness = platformChannelHarness({
    inspectPolicy: () => inventoryMismatch,
  });
  let inventoryMismatchThrown = null;
  try { mismatchedInventoryHarness.run(); } catch (error) { inventoryMismatchThrown = error; }
  requireValue(inventoryMismatchThrown instanceof requiredAdapter("MacosDistributionError") &&
    inventoryMismatchThrown.code === "macos_distribution_signature_verify_failed",
  "nested_inventory_mismatch_not_fail_closed");

  for (const field of ["developerIdApplication", "secureTimestamp"]) {
    const container = greenContainerSignature();
    container[field] = false;
    const harness = platformChannelHarness({ inspectContainer: () => container });
    let thrown = null;
    try { harness.run(); } catch (error) { thrown = error; }
    requireValue(thrown instanceof requiredAdapter("MacosDistributionError") &&
      thrown.code === "macos_distribution_dmg_signature_verify_failed",
    `dmg_${field}_not_fail_closed`);
  }
}

function assertRedaction(marker) {
  const stable = new (requiredAdapter("MacosDistributionError"))(
    "macos_distribution_codesign_failed",
  );
  requireValue(macosDistributionFailureCode(stable) ===
    "macos_distribution_codesign_failed", "stable_code_mapped_wrong");
  requireValue(macosDistributionFailureCode(new Error("anything")) ===
    "macos_distribution_failed", "unknown_code_not_mapped");
  const redacted = redactMacosDistributionFailure(stable, { markers: [marker] });
  requireValue(redacted.ok === false &&
    redacted.code === "macos_distribution_codesign_failed" &&
    redacted.privatePathsIncluded === false &&
    redacted.markerDataIncluded === false,
  "redaction_fields_wrong");
  const leakingError = new (requiredAdapter("MacosDistributionError"))(
    `macos_distribution_codesign_failed ${marker}`,
  );
  leakingError.code = "macos_distribution_codesign_failed";
  const leaking = redactMacosDistributionFailure(leakingError, { markers: [marker] });
  requireValue(leaking.code === "macos_distribution_codesign_failed" &&
    leaking.markerDataIncluded === true,
  "marker_detection_missing");
  requireValue(JSON.stringify({
    ok: false,
    code: redacted.code,
    privatePathsIncluded: false,
  }).includes(marker) === false, "redacted_output_leaks_marker");
}

export function runDistributionSelfTest({ marker, adapters }) {
  distributionAdapters = Object.freeze({
    coordinatePlatformChannel: adapters?.coordinatePlatformChannel || null,
    coordinatePreflight: adapters?.coordinatePreflight || null,
    MacosDistributionError: adapters?.MacosDistributionError || null,
  });
  try {
    assertPreflightIsolation(marker);
    assertCommandPartialOrder();
    assertProfileAuthorization();
    assertFinalDmgFailureClosure();
    assertRedaction(marker);
    return Object.freeze({
      ok: true,
      preflightIsolation: true,
      commandPartialOrder: true,
      finalDmgFailureClosure: true,
      profileAuthorization: true,
      redaction: true,
    });
  } catch (error) {
    return Object.freeze({
      ok: false,
      code: String(error?.message || "macos_distribution_self_test_failed"),
    });
  }
}
