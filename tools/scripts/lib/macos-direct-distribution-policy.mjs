// Pure Apple policy validators for the macOS direct-distribution channel.
//
// This module is deliberately side-effect free. It never touches the
// filesystem, child processes, or environment variables; callers decode,
// discover, and execute and pass plain values here. It owns the fail-closed
// contract shared by the distribution command, release metadata checks, and
// the synthetic macOS release regression.

export const MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME = "LicoUp";
export const MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID = "land.lico.licoup";

export const MACOS_DIRECT_TOOLCHAIN = Object.freeze([
  "xcodebuild",
  "codesign",
  "notarytool",
  "stapler",
  "hdiutil",
  "ditto",
  "spctl",
  "plutil",
  "security",
  "openssl",
]);

export const MACOS_DIRECT_PROTECTED_ENVIRONMENT = Object.freeze([
  "LICO_MACOS_SIGNING_IDENTITY",
  "LICO_MACOS_RELEASE_SIGNING_KEYCHAIN",
  "LICO_MACOS_RELEASE_SIGNER_SHA256",
  "LICO_MACOS_APP_IDENTIFIER_PREFIX",
  "LICO_MACOS_PROVISIONING_PROFILE",
  "LICO_MACOS_NOTARY_KEYCHAIN_PROFILE",
]);

export const MACOS_DIRECT_FAILURE_CODES = Object.freeze([
  "macos_distribution_host_unsupported",
  "macos_distribution_option_invalid",
  "macos_distribution_credentials_missing",
  "macos_distribution_protected_environment_read",
  "macos_distribution_metadata_invalid",
  "macos_distribution_entitlements_invalid",
  "macos_distribution_profile_invalid",
  "macos_distribution_profile_not_developer_id",
  "macos_distribution_profile_expired",
  "macos_distribution_profile_application_identifier_mismatch",
  "macos_distribution_profile_team_mismatch",
  "macos_distribution_package_missing",
  "macos_distribution_privacy_manifest_invalid",
  "macos_distribution_release_materials_missing",
  "macos_distribution_license_materials_missing",
  "macos_distribution_license_materials_invalid",
  "macos_distribution_camera_plugin_present",
  "macos_distribution_tool_missing",
  "macos_distribution_codesign_failed",
  "macos_distribution_signature_verify_failed",
  "macos_distribution_notarization_failed",
  "macos_distribution_staple_failed",
  "macos_distribution_staple_verify_failed",
  "macos_distribution_gatekeeper_failed",
  "macos_distribution_archive_failed",
  "macos_distribution_dmg_stage_failed",
  "macos_distribution_dmg_create_failed",
  "macos_distribution_dmg_sign_failed",
  "macos_distribution_dmg_signature_verify_failed",
  "macos_distribution_dmg_verify_failed",
  "macos_distribution_lineage_invalid",
  "macos_distribution_manifest_invalid",
  "macos_distribution_local_integrity_missing",
  "macos_distribution_ready_claim_premature",
  "macos_distribution_nested_signing_missing",
  "macos_distribution_signing_order_invalid",
  "macos_distribution_codesign_deep_sign_forbidden",
  "macos_distribution_command_sequence_incomplete",
  "macos_distribution_command_order_invalid",
  "macos_distribution_ready_claim_not_last",
]);

// Canonical public-channel command order. Every real or synthetic sequence
// must match this partial order; failures never produce a ready manifest.
export const MACOS_DIRECT_COMMAND_KINDS = Object.freeze([
  "stale-manifest-remove",
  "app-nested-sign",
  "app-sign",
  "app-notarize",
  "app-staple",
  "app-staple-validate",
  "app-gatekeeper",
  "update-archive",
  "dmg-create",
  "dmg-sign",
  "dmg-notarize",
  "dmg-staple",
  "dmg-staple-validate",
  "dmg-signature-verify",
  "dmg-image-verify",
  "dmg-gatekeeper",
  "ready-manifest-write",
]);

const MACOS_DIRECT_FINAL_DMG_KINDS = Object.freeze([
  "dmg-sign",
  "dmg-notarize",
  "dmg-staple",
  "dmg-staple-validate",
  "dmg-signature-verify",
  "dmg-image-verify",
  "dmg-gatekeeper",
]);

const MACOS_DIRECT_LOCAL_ENTITLEMENT_KEYS = Object.freeze([
  "com.apple.security.network.client",
  "com.apple.security.files.user-selected.read-only",
]);

const MACOS_DIRECT_PRODUCTION_ENTITLEMENT_KEYS = Object.freeze([
  "com.apple.application-identifier",
  "keychain-access-groups",
  "com.apple.security.network.client",
  "com.apple.security.files.user-selected.read-only",
]);

export function macosDistributionFailureCode(error) {
  const code = error && typeof error === "object" && typeof error.code === "string"
    ? error.code
    : "";
  return MACOS_DIRECT_FAILURE_CODES.includes(code)
    ? code
    : "macos_distribution_failed";
}

export function redactMacosDistributionFailure(error, { markers = [] } = {}) {
  const code = macosDistributionFailureCode(error);
  const message = String(error?.message ?? code)
    .replace(/[^\x20-\x7E]/gu, "")
    .trim();
  const markerDataIncluded = markers.some((marker) => message.includes(String(marker)));
  return Object.freeze({
    ok: false,
    code,
    privatePathsIncluded: false,
    markerDataIncluded,
  });
}

export function validateMacosDistributionMetadata(metadata) {
  const displayName = String(metadata?.displayName || "").trim();
  const bundleName = String(metadata?.bundleName || "").trim();
  const bundleIdentifier = String(metadata?.bundleIdentifier || "").trim();
  const errors = [];
  if (displayName !== MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME) {
    errors.push("macos_distribution_display_name_invalid");
  }
  if (bundleName !== MACOS_DIRECT_DISTRIBUTION_PRODUCT_NAME) {
    errors.push("macos_distribution_bundle_name_invalid");
  }
  if (bundleIdentifier !== MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID) {
    errors.push("macos_distribution_bundle_identifier_invalid");
  }
  return Object.freeze({
    ready: errors.length === 0,
    errors: Object.freeze(errors),
    displayName,
    bundleName,
    bundleIdentifier,
  });
}

export function validateLocalEntitlements(entitlements) {
  const source = entitlements && typeof entitlements === "object"
    ? entitlements
    : {};
  const errors = [];
  if (source["get-task-allow"] === true) {
    errors.push("macos_distribution_entitlements_invalid");
  }
  if (source["com.apple.security.cs.disable-library-validation"] === true) {
    errors.push("macos_distribution_entitlements_invalid");
  }
  for (const key of Object.keys(source)) {
    if (!MACOS_DIRECT_LOCAL_ENTITLEMENT_KEYS.includes(key)) {
      errors.push("macos_distribution_entitlements_invalid");
      break;
    }
  }
  return Object.freeze({
    ready: errors.length === 0,
    errors: Object.freeze(errors),
  });
}

export function productionEntitlementsIdentity(entitlements, {
  bundleIdentifier = MACOS_DIRECT_DISTRIBUTION_BUNDLE_ID,
} = {}) {
  const source = entitlements && typeof entitlements === "object"
    ? entitlements
    : {};
  const applicationIdentifier = String(source["com.apple.application-identifier"] || "").trim();
  const keychainAccessGroups = Array.isArray(source["keychain-access-groups"])
    ? source["keychain-access-groups"].map((value) => String(value).trim())
    : [];
  const prefixMatch = /^([A-Z0-9]{10})\.(.+)$/u.exec(applicationIdentifier);
  const placeholder = applicationIdentifier === "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)";
  const paired = (Boolean(prefixMatch && prefixMatch[2] === bundleIdentifier) || placeholder) &&
    keychainAccessGroups.length === 1 &&
    keychainAccessGroups[0] === applicationIdentifier;
  return Object.freeze({
    applicationIdentifier,
    keychainAccessGroups: Object.freeze(keychainAccessGroups),
    teamPrefix: prefixMatch ? prefixMatch[1] : "",
    paired,
    placeholder,
  });
}

export function validateProductionEntitlements(entitlements, options = {}) {
  const identity = productionEntitlementsIdentity(entitlements, options);
  const source = entitlements && typeof entitlements === "object"
    ? entitlements
    : {};
  const errors = [];
  if (!identity.applicationIdentifier) {
    errors.push("macos_distribution_entitlements_invalid");
  } else if (!identity.paired) {
    errors.push("macos_distribution_entitlements_invalid");
  }
  if (source["get-task-allow"] === true) {
    errors.push("macos_distribution_entitlements_invalid");
  }
  if (source["com.apple.security.cs.disable-library-validation"] === true) {
    errors.push("macos_distribution_entitlements_invalid");
  }
  for (const key of Object.keys(source)) {
    if (!MACOS_DIRECT_PRODUCTION_ENTITLEMENT_KEYS.includes(key)) {
      errors.push("macos_distribution_entitlements_invalid");
      break;
    }
  }
  return Object.freeze({
    ready: errors.length === 0,
    errors: Object.freeze(errors),
    identity,
  });
}

export function developerIdCertificateEvidenceFromText(text) {
  const certificateText = String(text || "");
  const subject = /(?:^|\n)subject\s*=\s*([^\n]+)/iu.exec(certificateText)?.[1] || "";
  const teamIdentifier = /(?:^|[,/]\s*)OU\s*=\s*([A-Z0-9]{10})(?:\s*[,/]|$)/u
    .exec(subject)?.[1] || "";
  return Object.freeze({
    developerIdApplication:
      /\b1\.2\.840\.113635\.100\.6\.1\.13\b/u.test(certificateText),
    teamIdentifier,
  });
}

export function normalizeProvisioningProfile(profile, { certificateEvidence = [] } = {}) {
  const source = profile && typeof profile === "object" ? profile : {};
  const entitlements = source.Entitlements && typeof source.Entitlements === "object"
    ? source.Entitlements
    : {};
  const teamIdentifiers = Array.isArray(source.TeamIdentifier)
    ? source.TeamIdentifier.map((value) => String(value).trim()).filter(Boolean)
    : [];
  const expirationMs = Number(new Date(String(source.ExpirationDate || "")).getTime());
  const developerCertificates = Array.isArray(source.DeveloperCertificates)
    ? source.DeveloperCertificates
    : [];
  const evidence = Array.isArray(certificateEvidence) ? certificateEvidence : [];
  const profileTeamUnambiguous = teamIdentifiers.length === 1;
  const certificateEvidenceComplete = profileTeamUnambiguous &&
    developerCertificates.length > 0 &&
    evidence.length === developerCertificates.length &&
    evidence.every((entry) => entry?.developerIdApplication === true &&
      String(entry?.teamIdentifier || "") === teamIdentifiers[0]);
  return Object.freeze({
    name: String(source.Name || "").trim(),
    uuid: String(source.UUID || "").trim(),
    provisionsAllDevices: source.ProvisionsAllDevices === true,
    developerCertificatesCount: developerCertificates.length,
    certificateEvidenceComplete,
    developerIdProfile: source.ProvisionsAllDevices === true && certificateEvidenceComplete,
    teamIdentifier: teamIdentifiers[0] || "",
    teamIdentifiers: Object.freeze(teamIdentifiers),
    applicationIdentifier: String(
      entitlements["com.apple.application-identifier"] || "",
    ).trim(),
    expirationMs,
  });
}

export function authorizeProvisioningProfile(
  profile,
  entitlements,
  { now = Date.now(), certificateEvidence = [] } = {},
) {
  const normalized = normalizeProvisioningProfile(profile, { certificateEvidence });
  const identity = productionEntitlementsIdentity(entitlements);
  const errors = [];
  if (!normalized.developerIdProfile) {
    errors.push("macos_distribution_profile_not_developer_id");
  }
  if (!Number.isFinite(normalized.expirationMs) || normalized.expirationMs <= now) {
    errors.push("macos_distribution_profile_expired");
  }
  if (!identity.paired) {
    errors.push("macos_distribution_entitlements_invalid");
  }
  if (normalized.applicationIdentifier !== identity.applicationIdentifier) {
    errors.push("macos_distribution_profile_application_identifier_mismatch");
  }
  if (identity.teamPrefix && normalized.teamIdentifier !== identity.teamPrefix) {
    errors.push("macos_distribution_profile_team_mismatch");
  }
  return Object.freeze({
    authorized: errors.length === 0,
    errors: Object.freeze(errors),
    profile: normalized,
    identity,
  });
}

export function validateMacosToolchainPreflight(tools, metadata) {
  const byName = new Map((Array.isArray(tools) ? tools : [])
    .map((tool) => [String(tool?.name || ""), tool]));
  const missingTools = MACOS_DIRECT_TOOLCHAIN.filter((name) => {
    const tool = byName.get(name);
    return tool?.found !== true || tool?.probed !== true ||
      String(tool?.version || "").trim() === "";
  });
  const metadataReady = metadata?.ready === true;
  const errors = [];
  for (const name of missingTools) errors.push("macos_distribution_tool_missing");
  if (!metadataReady) errors.push("macos_distribution_metadata_invalid");
  return Object.freeze({
    ready: errors.length === 0,
    errors: Object.freeze(errors),
    missingTools: Object.freeze(missingTools),
    metadataReady,
    tools: Object.freeze(MACOS_DIRECT_TOOLCHAIN.map((name) => Object.freeze({
      name,
      found: byName.get(name)?.found === true,
      probed: byName.get(name)?.probed === true,
      version: String(byName.get(name)?.version || ""),
    }))),
  });
}

export function validateMacosCameraPluginBoundary(nestedCodePaths) {
  const cameraPluginPresent = (Array.isArray(nestedCodePaths) ? nestedCodePaths : [])
    .some((entry) => String(entry || "").replaceAll("\\", "/").split("/")
      .some((segment) => /camera|mobile[_-]?scanner|qr[_-]?code[_-]?dart[_-]?scan/iu
        .test(segment)));
  return Object.freeze({
    ready: !cameraPluginPresent,
    cameraPluginPresent,
  });
}

export function validateMacosDirectCommandSequence(commands) {
  const sequence = Array.isArray(commands) ? commands : [];
  const kinds = sequence.map((command) => String(command?.kind || ""));
  const errors = [];
  const first = (kind) => kinds.indexOf(kind);
  const last = (kind) => kinds.lastIndexOf(kind);
  if (kinds[0] !== "stale-manifest-remove") {
    errors.push("macos_distribution_command_order_invalid");
  }
  const canonicalOrder = MACOS_DIRECT_COMMAND_KINDS.slice(1);
  for (let index = 0; index < canonicalOrder.length - 1; index += 1) {
    const left = first(canonicalOrder[index]);
    const right = first(canonicalOrder[index + 1]);
    if (left === -1 || right === -1) {
      errors.push("macos_distribution_command_sequence_incomplete");
      break;
    }
    if (left >= right) {
      errors.push("macos_distribution_command_order_invalid");
      break;
    }
  }
  const firstNestedSign = first("app-nested-sign");
  const firstAppSign = first("app-sign");
  if (firstNestedSign === -1 || firstAppSign === -1) {
    errors.push("macos_distribution_nested_signing_missing");
  } else if (last("app-nested-sign") >= firstAppSign) {
    errors.push("macos_distribution_signing_order_invalid");
  }
  for (const command of sequence) {
    const args = Array.isArray(command?.args) ? command.args : [];
    const hasArg = (value) => args.includes(value);
    if (command?.kind === "app-nested-sign") {
      if (hasArg("--entitlements")) {
        errors.push("macos_distribution_entitlements_invalid");
      }
      if (hasArg("--deep")) {
        errors.push("macos_distribution_codesign_deep_sign_forbidden");
      }
      if (!hasArg("--options") || !hasArg("runtime") || !hasArg("--timestamp")) {
        errors.push("macos_distribution_signing_order_invalid");
      }
    }
    if (command?.kind === "app-sign") {
      if (!hasArg("--entitlements")) {
        errors.push("macos_distribution_entitlements_invalid");
      }
      if (!hasArg("--options") || !hasArg("runtime") || !hasArg("--timestamp")) {
        errors.push("macos_distribution_signing_order_invalid");
      }
      if (hasArg("--deep")) {
        errors.push("macos_distribution_codesign_deep_sign_forbidden");
      }
    }
    if (command?.kind === "dmg-sign") {
      if (hasArg("--timestamp=none") || !hasArg("--timestamp")) {
        errors.push("macos_distribution_ready_claim_premature");
      }
    }
  }
  if (kinds[kinds.length - 1] !== "ready-manifest-write") {
    errors.push("macos_distribution_ready_claim_not_last");
  }
  return Object.freeze({
    ready: errors.length === 0,
    errors: Object.freeze(errors),
    commandCount: kinds.length,
  });
}

export function macosDistributionReadinessPolicy(steps) {
  const sequence = (Array.isArray(steps) ? steps : []).map((step) => ({
    kind: String(step?.kind || ""),
    args: Object.freeze(Array.isArray(step?.args)
      ? step.args.map((value) => String(value))
      : []),
    failed: step?.failed === true,
  }));
  const order = validateMacosDirectCommandSequence(sequence);
  const anyFailure = sequence.some((step) => step.failed);
  const finalDmgFailed = sequence.some((step) =>
    MACOS_DIRECT_FINAL_DMG_KINDS.includes(step.kind) && step.failed);
  const last = sequence[sequence.length - 1];
  const ready = order.ready && !anyFailure && last?.kind === "ready-manifest-write";
  const finalDmgVerified = order.ready && !finalDmgFailed &&
    MACOS_DIRECT_FINAL_DMG_KINDS.every((kind) => sequence.some((step) => step.kind === kind));
  return Object.freeze({
    ready,
    orderReady: order.ready,
    orderErrors: order.errors,
    finalDmgVerified,
    staleManifestRemoved: sequence[0]?.kind === "stale-manifest-remove",
  });
}

export function macosDistributionManifestClaims({
  platformChannelRequested,
  sequenceReady,
  signingKind,
}) {
  const publicClaims = platformChannelRequested === true && sequenceReady === true;
  return Object.freeze({
    signingKind: String(signingKind || ""),
    notarized: publicClaims,
    stapled: publicClaims,
    gatekeeperVerified: publicClaims,
    platformChannelReady: publicClaims,
    githubReleaseBlocked: true,
  });
}

export function macosEntitlementsAuthorityRef({ production }) {
  return production
    ? "apps/desktop/macos/Runner/ProductionRelease.entitlements"
    : "apps/desktop/macos/Runner/Release.entitlements";
}
