#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  canonicalClientSourceRootsMatch,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import {
  artifactTreeDigest,
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
  stableHashFileSnapshot,
  stableReadFile,
  stableReadFileSnapshot,
} from "./lib/client-release-artifact-digest.mjs";
import { validateLinuxVmPackageReceipt } from "./lib/secure-mesh-linux-evidence.mjs";
import {
  createReleaseClosureChallenge,
  createReleaseInvocationNonce,
  releaseClosureChallengeDigest,
  releaseClosureEnvironment,
  releaseInvocationEnvironment,
  releaseInvocationNonceDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseClosureStartedAt,
} from "./lib/release-closure-challenge.mjs";
import {
  atomicWriteReportJson,
  removeContainedReportIfExists,
} from "./lib/safe-report-io.mjs";
import {
  captureSourceBoundJsonPolicy,
  publicPolicyBindings,
  sourceBoundPolicySnapshotsStable,
} from "./lib/source-bound-policy-snapshot.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const configRef = "tools/scripts/config/client-artifact-verification-receipts.json";
const configPath = path.join(repoRoot, configRef);
const producer = "tools/scripts/client-artifact-verification-receipts.mjs";
const canonicalReportRef = "build/reports/client-artifact-verification-receipts.json";
const digestPattern = /^sha256:[a-f0-9]{64}$/u;
const maxJsonBytes = 16 * 1024 * 1024;
const maxProducerBytes = 16 * 1024 * 1024;
const maxArtifactFileBytes = 8 * 1024 * 1024 * 1024;

class ReceiptValidationError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function requireValue(condition, code) {
  if (!condition) throw new ReceiptValidationError(code);
}

function text(value) {
  return String(value || "").trim();
}

function readJson(filePath) {
  return JSON.parse(stableReadFile(filePath, { maxBytes: maxJsonBytes }).toString("utf8"));
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validatePolicyBindings(bindings) {
  const expected = [
    ["receipt-config", configRef],
    ["client-version", "tools/client-version.json"],
  ];
  requireValue(Array.isArray(bindings) && bindings.length === expected.length,
    "receipt_policy_bindings_missing");
  for (let index = 0; index < expected.length; index += 1) {
    requireValue(bindings[index]?.id === expected[index][0] &&
      bindings[index]?.ref === expected[index][1] &&
      digestPattern.test(text(bindings[index]?.digest)),
    "receipt_policy_binding_invalid");
  }
  return bindings;
}

function validateConfig(config) {
  requireValue(
    config?.schemaVersion === "licolite.client-artifact-verification-receipts-config.v3",
    "receipt_config_schema_mismatch",
  );
  requireValue(
    config?.reportSchemaVersion === "licolite.client-artifact-verification-receipts.v3",
    "receipt_report_schema_mismatch",
  );
  requireValue(config?.producer === producer, "receipt_config_producer_mismatch");
  requireValue(config?.reportRef === canonicalReportRef,
    "receipt_config_report_ref_mismatch");
  requireValue(
    config?.producerPolicy === "same-closure-approved-producer-invocation",
    "receipt_producer_policy_mismatch",
  );
  requireValue(
    Number.isInteger(config.maxClockSkewMs) && config.maxClockSkewMs >= 0,
    "receipt_clock_skew_invalid",
  );
  requireValue(canonicalClientSourceRootsMatch(config.sourceRoots),
    "receipt_source_roots_not_canonical");
  const expectedTargetIds = ["macos-arm64", "android-arm64", "linux-glibc-arm64"];
  requireValue(
    JSON.stringify(Object.keys(config.targets || {})) === JSON.stringify(expectedTargetIds),
    "receipt_target_catalog_mismatch",
  );
  for (const [targetId, spec] of Object.entries(config.targets)) {
    for (const field of [
      "platform",
      "artifactKind",
      "artifactRef",
      "artifactDigestKind",
      "evidenceRef",
      "evidenceProducer",
      "evidenceProducerField",
      "freshnessKind",
      "consumerVerificationPolicy",
    ]) {
      requireValue(text(spec[field]), `receipt_target_spec_incomplete:${targetId}`);
    }
    requireValue(
      ["file", "tree"].includes(spec.artifactDigestKind),
      `receipt_artifact_digest_kind_invalid:${targetId}`,
    );
    requireValue(
      spec.freshnessKind === "generated-at",
      `receipt_freshness_kind_invalid:${targetId}`,
    );
    requireValue(
      spec.consumerVerificationPolicy === "provenance-or-verifiable-signature",
      `receipt_consumer_verification_policy_invalid:${targetId}`,
    );
    requireValue(text(spec.evidenceInvocation?.script) &&
      Array.isArray(spec.evidenceInvocation?.args) &&
      Number.isInteger(spec.evidenceInvocation?.timeoutMs) &&
      spec.evidenceInvocation.timeoutMs > 0,
    `receipt_evidence_invocation_invalid:${targetId}`);
    if (["macos", "linux"].includes(spec.platform)) {
      requireValue(text(spec.distributionManifestRef),
        `receipt_distribution_manifest_missing:${targetId}`);
    }
    if (spec.platform === "macos") {
      requireValue(spec.evidenceArtifactKind === "macos-app-bundle" &&
        text(spec.evidenceArtifactRef) &&
        spec.evidenceArtifactDigestKind === "tree",
      `receipt_macos_evidence_artifact_invalid:${targetId}`);
    }
  }
  return config;
}

function parseArgs(argv) {
  const options = {
    targets: "",
    targetsSpecified: false,
    selfTest: false,
    schemaFixture: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--self-test") {
      options.selfTest = true;
    } else if (arg === "--schema-fixture") {
      options.schemaFixture = true;
    } else if (arg === "--targets" && next) {
      options.targets = next;
      options.targetsSpecified = true;
      index += 1;
    } else if (arg.startsWith("--targets=")) {
      options.targets = arg.slice("--targets=".length);
      options.targetsSpecified = true;
    } else {
      throw new ReceiptValidationError("receipt_option_unknown");
    }
  }
  return options;
}

function defaultTargetId() {
  if (process.platform === "darwin" && process.arch === "arm64") return "macos-arm64";
  if (process.platform === "linux" && process.arch === "arm64") {
    const glibcVersion = text(process.report?.getReport?.()?.header?.glibcVersionRuntime);
    if (glibcVersion) return "linux-glibc-arm64";
  }
  throw new ReceiptValidationError("receipt_explicit_target_selection_required");
}

function selectedTargetIds(options, config) {
  const environmentSpecified = Object.hasOwn(
    process.env,
    "LICO_CLIENT_RELEASE_TARGETS",
  );
  const explicit = options.targetsSpecified || environmentSpecified;
  const configured = options.targetsSpecified
    ? String(options.targets)
    : environmentSpecified ? String(process.env.LICO_CLIENT_RELEASE_TARGETS) : "";
  const requested = explicit
    ? configured.split(",").map(text)
    : [defaultTargetId()];
  requireValue(requested.every(Boolean), "receipt_target_selection_empty_token");
  const requestedSet = new Set(requested);
  const ids = Object.keys(config.targets).filter((id) => requestedSet.has(id));
  requireValue(ids.length > 0, "receipt_target_selection_empty");
  requireValue(requestedSet.size === requested.length,
    "receipt_target_selection_duplicate");
  requireValue(requested.every((id) => isPlainObject(config.targets[id])) &&
    ids.length === requested.length,
    "receipt_target_selection_unsupported");
  return ids;
}

function freshnessReady(payload, input, closureStartedAtMs, nowMs, config) {
  const skewMs = config.maxClockSkewMs;
  const invocationStartedAtMs = Number(input.invocationStartedAtMs);
  const generatedAtMs = Date.parse(text(payload?.generatedAt));
  return input.invocationExitCode === 0 &&
    Number.isFinite(invocationStartedAtMs) &&
    Number.isFinite(generatedAtMs) &&
    invocationStartedAtMs >= closureStartedAtMs - skewMs &&
    generatedAtMs >= invocationStartedAtMs - skewMs &&
    generatedAtMs >= closureStartedAtMs - skewMs &&
    generatedAtMs <= nowMs + skewMs;
}

function validateCommonEvidence(
  payload,
  spec,
  input,
  expectedClosureChallengeDigest,
  closureStartedAtMs,
  nowMs,
  config
) {
  requireValue(isPlainObject(payload), "approved_evidence_invalid");
  requireValue(input.invocationExitCode === 0, "evidence_invocation_failed");
  requireValue(input.producerStable === true, "evidence_producer_changed_during_invocation");
  if (spec.evidenceSchema) {
    requireValue(payload.schema === spec.evidenceSchema, "evidence_schema_mismatch");
  }
  requireValue(payload.schemaVersion === spec.evidenceSchemaVersion,
    "evidence_schema_version_mismatch");
  const expectedProducerValue = text(spec.evidenceProducerValue || spec.evidenceProducer);
  requireValue(text(payload[spec.evidenceProducerField]) === expectedProducerValue,
    "evidence_producer_mismatch");
  requireValue(payload.closureChallengeDigest === expectedClosureChallengeDigest,
    "evidence_closure_challenge_mismatch");
  requireValue(payload.invocationNonceDigest === input.expectedInvocationNonceDigest,
    "evidence_invocation_nonce_mismatch");
  requireValue(digestPattern.test(text(input.evidenceProducerSourceDigest)),
    "evidence_producer_digest_missing");
  requireValue(digestPattern.test(text(input.evidenceReportDigest)),
    "evidence_report_digest_missing");
  const fresh = freshnessReady(payload, input, closureStartedAtMs, nowMs, config);
  requireValue(fresh, "evidence_stale");
  return { freshnessReady: true, provenanceReady: true };
}

function validateMacosEvidence(payload, context) {
  const receipt = Array.isArray(payload.receipts)
    ? payload.receipts.find((entry) => entry?.targetId === context.targetId)
    : null;
  const dependency = Array.isArray(payload.dependencies) && payload.dependencies.length === 1
    ? payload.dependencies[0]
    : null;
  requireValue(payload.ok === true && payload.platform === "macos", "macos_evidence_not_ready");
  requireValue(payload.redacted === true && payload.reportLeakScan === true,
    "macos_evidence_not_redacted");
  requireValue(payload.rawRuntimeOutputIncluded === false && payload.rawPrivateMaterialIncluded === false,
    "macos_evidence_contains_raw_data");
  requireValue(payload.sourceStateDigest === context.sourceStateDigest,
    "evidence_source_digest_mismatch");
  requireValue(receipt?.targetId === context.targetId, "evidence_target_mismatch");
  requireValue(receipt?.productVersion === context.productVersion, "evidence_version_mismatch");
  requireValue(receipt?.buildNumber === context.buildNumber, "evidence_build_number_mismatch");
  requireValue(context.artifactLineageReady === true &&
    digestPattern.test(text(context.artifactManifestDigest)),
  "artifact_distribution_lineage_mismatch");
  requireValue(receipt?.artifactKind === context.spec.evidenceArtifactKind,
    "evidence_artifact_kind_mismatch");
  requireValue(receipt?.artifactDigest === context.evidenceArtifactDigest,
    "evidence_artifact_digest_mismatch");
  requireValue(digestPattern.test(text(receipt?.runtimeExecutableDigest)),
    "macos_runtime_executable_digest_missing");
  requireValue(dependency?.id === "macos-user-presence-proof" &&
    dependency?.ref ===
      "build/reports/secure-mesh-macos-keychain-user-presence-proof.json" &&
    digestPattern.test(text(dependency?.digest)),
  "macos_capability_dependency_receipt_missing");
  requireValue(receipt?.signatureKind === "local-identity-codesign" &&
    receipt?.platformLocalSignatureReady === true &&
    receipt?.hardenedRuntime === true &&
    receipt?.nestedCodeMinimalEntitlements === true,
  "evidence_signature_policy_mismatch");
  requireValue(receipt?.entitlementsMatch === true &&
    digestPattern.test(text(receipt?.entitlementsDigest)),
  "macos_entitlements_mismatch");
  requireValue(receipt?.installedArtifactMatched === true &&
    receipt?.installReceiptReady === true, "macos_install_receipt_not_ready");
  requireValue(receipt?.launchReady === true, "macos_launch_not_ready");
  requireValue(receipt?.newProcessReady === true &&
    receipt?.startedAfterInvocation === true &&
    receipt?.executableWithinInstalledBundle === true &&
    receipt?.closureChallengeBound === true &&
    receipt?.invocationNonceBound === true &&
    receipt?.stableProcessWindowReady === true &&
    receipt?.postLaunchArtifactStable === true,
  "macos_launch_binding_not_ready");
  requireValue(receipt?.smokeReady === true && receipt?.capabilityProofReady === true,
    "macos_smoke_not_ready");
  return {
    consumerIntegritySignatureKind: "platform-local-validation",
    consumerIntegritySignatureReady: true,
    publicVerificationMaterialReady: false,
    platformSecurityReady: true,
    installReady: true,
    launchReady: true,
    smokeReady: true,
    runtimeExecutableDigest: receipt.runtimeExecutableDigest,
    dependencies: [{
      id: dependency.id,
      ref: dependency.ref,
      digest: dependency.digest,
    }],
  };
}

function validateAndroidEvidence(payload, context) {
  const sourceBuild = payload.sourceBuild || {};
  const binding = payload.evidenceBinding || {};
  const signing = payload.signing || {};
  const install = payload.install || {};
  const launch = payload.launch || {};
  const summary = payload.summary || {};
  requireValue(payload.ok === true && payload.platform === "android" &&
    payload.physicalDevice === true, "android_evidence_not_ready");
  requireValue(payload.targetId === context.targetId, "evidence_target_mismatch");
  requireValue(payload.productVersion === context.productVersion, "evidence_version_mismatch");
  requireValue(payload.buildNumber === context.buildNumber,
    "evidence_build_number_mismatch");
  requireValue(payload.redacted === true && payload.reportLeakScan === true,
    "android_evidence_not_redacted");
  requireValue(payload.rawPrivateMaterialIncluded === false && payload.rawPlaintextIncluded === false,
    "android_evidence_contains_raw_data");
  requireValue(sourceBuild.sourceStateDigest === context.sourceStateDigest &&
    binding.sourceStateDigest === context.sourceStateDigest,
  "evidence_source_digest_mismatch");
  requireValue(payload.apk?.sha256 === context.artifactDigest &&
    binding.apkSha256 === context.artifactDigest,
  "evidence_artifact_digest_mismatch");
  requireValue(payload.apk?.nativeSecureMeshAbi === "arm64-v8a",
    "evidence_target_architecture_mismatch");
  requireValue(payload.packageName === "com.liko.arc" &&
    payload.apkBinaryFacts?.packageName === payload.packageName &&
    payload.apkBinaryFacts?.versionName === payload.productVersion &&
    payload.apkBinaryFacts?.versionCode === String(payload.buildNumber) &&
    payload.apkBinaryFacts?.debuggable === false &&
    JSON.stringify(payload.apkBinaryFacts?.abis) === JSON.stringify(["arm64-v8a"]) &&
    text(payload.apkBinaryFacts?.launchableActivity) &&
    payload.apkBinaryFacts?.signerCount === 1 &&
    payload.apkBinaryFacts?.zipAligned === true &&
    payload.apkBinaryFacts?.nativeSecureMeshLibrary?.path ===
      "lib/arm64-v8a/liblico_client_native.so" &&
    payload.apkBinaryFacts?.nativeSecureMeshLibrary?.regular === true &&
    payload.apkBinaryFacts?.nativeSecureMeshLibrary?.unique === true &&
    payload.apkBinaryFacts?.nativeSecureMeshLibrary?.size > 0 &&
    digestPattern.test(text(
      payload.apkBinaryFacts?.nativeSecureMeshLibrary?.contentDigest,
    )) &&
    Array.isArray(payload.apkBinaryFacts?.signatureSchemes) &&
    payload.apkBinaryFacts.signatureSchemes.some((scheme) =>
      ["v2", "v3", "v4"].includes(scheme)),
  "android_binary_manifest_facts_mismatch");
  requireValue(signing.signingKind === "local-install-keystore" &&
    signing.signatureVerified === true && signing.singleSigner === true &&
    signing.signerIdentityVerified === true &&
    signing.signingPolicySatisfied === true &&
    signing.signatureMatchedBuildManifest === true &&
    binding.signatureMatchedBuildManifest === true,
  "evidence_signature_policy_mismatch");
  requireValue(install.attempted === true && install.installedViaVerifier === true &&
    install.packagePresentAfterInstall === true &&
    install.installedArtifactMatched === true && summary.installReady === true,
  "android_install_receipt_not_ready");
  requireValue(launch.attempted === true && launch.launchedViaVerifier === true &&
    launch.runtimeStatusFreshAfterLaunch === true && summary.launchReady === true,
  "android_launch_not_ready");
  requireValue(summary.runtimeStatusReady === true && summary.nativeRuntimeReady === true &&
    summary.androidCustodyReady === true &&
    summary.adaptiveAuthorizationReady === true &&
    summary.evidenceBindingReady === true && summary.closureChallengeBound === true &&
    summary.invocationNonceBound === true,
  "android_smoke_not_ready");
  return {
    consumerIntegritySignatureKind: "platform-local-validation",
    consumerIntegritySignatureReady: true,
    publicVerificationMaterialReady: false,
    platformSecurityReady: true,
    installReady: true,
    launchReady: true,
    smokeReady: true,
    runtimeExecutableDigest:
      payload.apkBinaryFacts.nativeSecureMeshLibrary.contentDigest,
    dependencies: [],
  };
}

function validateLinuxEvidence(payload, context, linuxValidator) {
  try {
    linuxValidator(payload, context.sourceStateDigest);
  } catch {
    throw new ReceiptValidationError("linux_evidence_not_ready");
  }
  requireValue(payload.target === "ubuntu-linux-arm64", "evidence_target_mismatch");
  requireValue(payload.sourceBinding?.sourceStateDigest === context.sourceStateDigest,
    "evidence_source_digest_mismatch");
  requireValue(context.artifactLineageReady === true &&
    digestPattern.test(text(context.artifactManifestDigest)),
  "artifact_distribution_lineage_mismatch");
  requireValue(payload.sourceBinding?.archiveDigest === context.artifactDigest,
    "evidence_artifact_digest_mismatch");
  requireValue(digestPattern.test(text(payload.sourceBinding?.nativeClientDigest)),
    "linux_native_client_digest_missing");
  requireValue(payload.package?.validationSignature === true &&
    payload.package?.signatureVerified === true, "evidence_signature_policy_mismatch");
  requireValue(payload.summary?.installReceiptReady === true,
    "linux_install_receipt_not_ready");
  requireValue(payload.summary?.sessionLaunchReady === true, "linux_launch_not_ready");
  requireValue(payload.summary?.smokeReady === true && payload.summary?.privacyReady === true,
    "linux_smoke_not_ready");
  requireValue(payload.productVersion === context.productVersion &&
    payload.buildNumber === context.buildNumber,
  "evidence_version_mismatch");
  return {
    consumerIntegritySignatureKind: "detached-validation",
    consumerIntegritySignatureReady: true,
    publicVerificationMaterialReady: true,
    platformSecurityReady: true,
    installReady: true,
    launchReady: true,
    smokeReady: true,
    runtimeExecutableDigest: payload.sourceBinding.nativeClientDigest,
    dependencies: [],
  };
}

function emptyReceipt({
  targetId,
  productVersion,
  buildNumber,
  sourceStateDigest,
  closureChallengeDigest,
  spec,
  input,
}) {
  return {
    targetId,
    productVersion,
    buildNumber,
    artifactKind: spec.artifactKind,
    artifactDigest: digestPattern.test(text(input.artifactDigest)) ? input.artifactDigest : "",
    artifactManifestDigest: digestPattern.test(text(input.artifactManifestDigest))
      ? input.artifactManifestDigest
      : "",
    sourceStateDigest,
    closureChallengeDigest,
    invocationNonceDigest: text(input.expectedInvocationNonceDigest),
    evidenceSchemaVersion: spec.evidenceSchemaVersion,
    evidenceProducer: spec.evidenceProducer,
    evidenceProducerSourceDigest: digestPattern.test(text(input.evidenceProducerSourceDigest))
      ? input.evidenceProducerSourceDigest
      : "",
    evidenceReportDigest: digestPattern.test(text(input.evidenceReportDigest))
      ? input.evidenceReportDigest
      : "",
    freshnessReady: false,
    consumerIntegritySignatureKind: "none",
    consumerIntegritySignatureReady: false,
    publicVerificationMaterialReady: false,
    platformSecurityReady: false,
    installReady: false,
    launchReady: false,
    smokeReady: false,
    runtimeExecutableDigest: "",
    dependencies: [],
    installReceiptReady: false,
    provenanceReady: false,
    ready: false,
    blockers: [],
  };
}

export function buildCanonicalReceiptReport({
  config,
  selectedTargetIds,
  productVersion,
  buildNumber,
  sourceStateDigest,
  closureChallengeDigest,
  closureStartedAtMs,
  targetInputs,
  policyBindings,
  nowMs = Date.now(),
  linuxValidator = validateLinuxVmPackageReceipt,
}) {
  validateConfig(config);
  requireValue(Array.isArray(selectedTargetIds) && selectedTargetIds.length > 0,
    "receipt_target_selection_empty");
  requireValue(new Set(selectedTargetIds).size === selectedTargetIds.length,
    "receipt_target_selection_duplicate");
  requireValue(selectedTargetIds.every((id) => config.targets[id]),
    "receipt_target_selection_unsupported");
  requireValue(text(productVersion), "receipt_product_version_missing");
  requireValue(Number.isInteger(buildNumber) && buildNumber > 0,
    "receipt_build_number_missing");
  requireValue(digestPattern.test(text(sourceStateDigest)), "receipt_source_digest_missing");
  requireValue(digestPattern.test(text(closureChallengeDigest)),
    "receipt_closure_challenge_missing");
  requireValue(Number.isFinite(closureStartedAtMs), "receipt_closure_start_missing");
  validatePolicyBindings(policyBindings);

  const receipts = selectedTargetIds.map((targetId) => {
    const spec = config.targets[targetId];
    const input = targetInputs[targetId] || {};
    const receipt = emptyReceipt({
      targetId,
      productVersion,
      buildNumber,
      sourceStateDigest,
      closureChallengeDigest,
      spec,
      input,
    });
    try {
      const common = validateCommonEvidence(
        input.payload,
        spec,
        input,
        closureChallengeDigest,
        closureStartedAtMs,
        nowMs,
        config,
      );
      const context = {
        targetId,
        productVersion,
        buildNumber,
        sourceStateDigest,
        artifactDigest: input.artifactDigest,
        artifactManifestDigest: input.artifactManifestDigest,
        artifactLineageReady: input.artifactLineageReady,
        evidenceArtifactDigest: input.evidenceArtifactDigest,
        spec,
      };
      const facts = spec.platform === "macos"
        ? validateMacosEvidence(input.payload, context)
        : spec.platform === "android"
          ? validateAndroidEvidence(input.payload, context)
          : validateLinuxEvidence(input.payload, context, linuxValidator);
      Object.assign(receipt, common, facts);
      receipt.installReceiptReady =
        receipt.installReady === true && receipt.launchReady === true &&
        receipt.smokeReady === true && receipt.freshnessReady === true &&
        receipt.provenanceReady === true;
      receipt.consumerVerificationReady = receipt.provenanceReady === true ||
        (receipt.consumerIntegritySignatureReady === true &&
          receipt.publicVerificationMaterialReady === true);
      receipt.ready = receipt.installReceiptReady &&
        receipt.consumerVerificationReady === true;
    } catch (error) {
      receipt.blockers = [error instanceof ReceiptValidationError
        ? error.code
        : "approved_evidence_invalid"];
    }
    return receipt;
  });
  const report = {
    schemaVersion: config.reportSchemaVersion,
    generatedAt: new Date(nowMs).toISOString(),
    generatedBy: producer,
    selectedTargetIds: [...selectedTargetIds],
    productVersion,
    buildNumber,
    sourceStateDigest,
    closureChallengeDigest,
    policyBindings: policyBindings.map((binding) => ({ ...binding })),
    ok: receipts.every((receipt) => receipt.ready === true),
    githubReleaseReady: receipts.every((receipt) => receipt.ready === true),
    nonBlockingDistributionGuidance: {
      blocking: false,
      storeListingStatus: "not-configured",
      platformSigningStatus: "not-configured",
      notarizationStatus: "not-configured",
      publicDownloadStatus: "not-configured",
      updateChannelStatus: "not-configured",
      rollbackChannelStatus: "not-configured",
    },
    receipts,
    privacy: {
      redacted: true,
      absolutePathsIncluded: false,
      runtimeIdentityIncluded: false,
      deviceIdentifiersIncluded: false,
      deviceModelsIncluded: false,
      signingIdentitiesIncluded: false,
      keyMaterialIncluded: false,
      rawLogsIncluded: false,
    },
  };
  requireValue(new Set(receipts.map((receipt) => receipt.invocationNonceDigest)).size ===
    receipts.length, "receipt_invocation_nonce_reused");
  assertReceiptPrivacy(report);
  return report;
}

const forbiddenOutputKeys = new Set([
  "path",
  "absolutePath",
  "localPath",
  "deviceId",
  "deviceSerial",
  "deviceModel",
  "signingIdentity",
  "certificateSubject",
  "keyMaterial",
  "stdout",
  "stderr",
  "rawLog",
]);
const forbiddenOutputValues = [
  /\/(?:Users|home|private|tmp|var\/folders)\//u,
  /^[A-Za-z]:\\/u,
  /-----BEGIN|-----END/u,
  /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u,
];

export function assertReceiptPrivacy(value) {
  if (Array.isArray(value)) {
    for (const item of value) assertReceiptPrivacy(item);
    return true;
  }
  if (isPlainObject(value)) {
    for (const [key, nested] of Object.entries(value)) {
      requireValue(!isForbiddenOutputKey(key), "receipt_privacy_forbidden_field");
      assertReceiptPrivacy(nested);
    }
    return true;
  }
  if (typeof value === "string") {
    requireValue(forbiddenOutputValues.every((pattern) => !pattern.test(value)),
      "receipt_privacy_forbidden_value");
  }
  return true;
}

function isForbiddenOutputKey(key) {
  return forbiddenOutputKeys.has(key) ||
    /(?:(?:signer|certificate|team).*(?:digest|sha(?:256)?|fingerprint)|(?:digest|sha(?:256)?|fingerprint).*(?:signer|certificate|team))/iu.test(key);
}

function buildRelativeRef(ref) {
  const normalized = text(ref).replaceAll("\\", "/");
  requireValue(normalized.startsWith("build/") && !normalized.includes("../"),
    "receipt_build_ref_invalid");
  return normalized.slice("build/".length);
}

function invokeAndLoadTargetInput(
  spec,
  closureChallenge,
  closureStartedAt,
  { sourceStateDigest, productVersion, buildNumber },
) {
  const buildRoot = path.join(repoRoot, "build");
  const toolsRoot = path.join(repoRoot, "tools/scripts");
  const artifactPath = path.join(repoRoot, spec.artifactRef);
  const evidenceRef = buildRelativeRef(spec.evidenceRef);
  const evidencePath = path.join(buildRoot, evidenceRef);
  const producerPath = path.join(repoRoot, spec.evidenceProducer);
  const invocationScript = path.join(repoRoot, spec.evidenceInvocation.script);
  const input = {
    payload: {},
    artifactDigest: "",
    artifactManifestDigest: "",
    artifactLineageReady: false,
    evidenceArtifactDigest: "",
    evidenceProducerSourceDigest: "",
    evidenceReportDigest: "",
    invocationStartedAtMs: Number.NaN,
    invocationExitCode: -1,
    expectedInvocationNonceDigest: "",
    producerStable: false,
  };
  const invocationNonce = createReleaseInvocationNonce();
  input.expectedInvocationNonceDigest = releaseInvocationNonceDigest(invocationNonce);
  try {
    removeContainedReportIfExists(buildRoot, evidenceRef);
    const safeProducerPath = resolveContainedExistingPath(
      toolsRoot,
      producerPath,
      { expectedKind: "file" },
    );
    const safeInvocationScript = resolveContainedExistingPath(
      toolsRoot,
      invocationScript,
      { expectedKind: "file" },
    );
    const producerBefore = stableHashFileSnapshot(safeProducerPath, {
      maxBytes: maxProducerBytes,
    });
    const invocationBefore = stableHashFileSnapshot(safeInvocationScript, {
      maxBytes: maxProducerBytes,
    });
    input.invocationStartedAtMs = Date.now();
    const invocationArgs = spec.evidenceInvocation.args.map((arg) => {
      const replacements = {
        "{artifactRef}": spec.artifactRef,
        "{distributionManifestRef}": spec.distributionManifestRef,
        "{evidenceRef}": spec.evidenceRef,
        "{sourceStateDigest}": sourceStateDigest,
      };
      const value = replacements[arg] ?? String(arg);
      requireValue(!value.includes("{"), "receipt_evidence_argument_unresolved");
      return value;
    });
    const command = spawnSync(process.execPath, [
      safeInvocationScript,
      ...invocationArgs,
    ], {
      cwd: repoRoot,
      env: {
        ...process.env,
        ...releaseClosureEnvironment(closureChallenge, closureStartedAt),
        ...releaseInvocationEnvironment(invocationNonce),
        ...(spec.platform === "linux" ? {
          LICO_LINUX_VM_REPORT_ROOT: path.dirname(evidencePath),
        } : {}),
      },
      encoding: "utf8",
      stdio: "pipe",
      maxBuffer: 16 * 1024 * 1024,
      timeout: spec.evidenceInvocation.timeoutMs,
    });
    input.invocationExitCode = Number.isInteger(command.status) ? command.status : -1;
    const producerAfter = stableHashFileSnapshot(safeProducerPath, {
      maxBytes: maxProducerBytes,
    });
    const invocationAfter = stableHashFileSnapshot(safeInvocationScript, {
      maxBytes: maxProducerBytes,
    });
    input.producerStable = producerBefore.digest === producerAfter.digest &&
      producerBefore.device === producerAfter.device &&
      producerBefore.inode === producerAfter.inode &&
      invocationBefore.digest === invocationAfter.digest &&
      invocationBefore.device === invocationAfter.device &&
      invocationBefore.inode === invocationAfter.inode;
    input.evidenceProducerSourceDigest = producerBefore.digest;
    if (input.invocationExitCode !== 0) return input;
    const safeEvidencePath = resolveContainedExistingPath(buildRoot, evidencePath, {
      expectedKind: "file",
    });
    const evidenceSnapshot = stableReadFileSnapshot(safeEvidencePath, {
      maxBytes: maxJsonBytes,
    });
    input.payload = JSON.parse(evidenceSnapshot.bytes.toString("utf8"));
    input.evidenceReportDigest = sha256Buffer(evidenceSnapshot.bytes);
    if (existsSync(artifactPath)) {
      const safeArtifact = resolveContainedExistingPath(buildRoot, artifactPath, {
        expectedKind: spec.artifactDigestKind === "tree" ? "directory" : "file",
      });
      input.artifactDigest = spec.artifactDigestKind === "tree"
        ? artifactTreeDigest(safeArtifact)
        : sha256File(safeArtifact, { maxBytes: maxArtifactFileBytes });
    }
    if (text(spec.evidenceArtifactRef)) {
      const evidenceArtifactPath = path.join(repoRoot, spec.evidenceArtifactRef);
      const safeEvidenceArtifact = resolveContainedExistingPath(
        buildRoot,
        evidenceArtifactPath,
        {
          expectedKind: spec.evidenceArtifactDigestKind === "tree"
            ? "directory"
            : "file",
        },
      );
      input.evidenceArtifactDigest = spec.evidenceArtifactDigestKind === "tree"
        ? artifactTreeDigest(safeEvidenceArtifact)
        : sha256File(safeEvidenceArtifact, { maxBytes: maxArtifactFileBytes });
    }
    if (text(spec.distributionManifestRef)) {
      const manifestPath = resolveContainedExistingPath(
        buildRoot,
        path.join(repoRoot, spec.distributionManifestRef),
        { expectedKind: "file" },
      );
      const manifestSnapshot = stableReadFileSnapshot(manifestPath, {
        maxBytes: maxJsonBytes,
      });
      const manifest = JSON.parse(manifestSnapshot.bytes.toString("utf8"));
      input.artifactManifestDigest = sha256Buffer(manifestSnapshot.bytes);
      input.artifactLineageReady = distributionLineageReady(spec, manifest, {
        artifactPath,
        artifactDigest: input.artifactDigest,
        evidenceArtifactDigest: input.evidenceArtifactDigest,
        sourceStateDigest,
        productVersion,
        buildNumber,
      });
    }
  } catch {
    return input;
  }
  return input;
}

function distributionLineageReady(spec, manifest, context) {
  const commonReady = manifest?.targetId ===
      (spec.platform === "macos" ? "macos-arm64" : "linux-glibc-arm64") &&
    manifest?.platform === spec.platform &&
    manifest?.architecture === "arm64" &&
    manifest?.archive === path.basename(context.artifactPath) &&
    manifest?.sha256 === context.artifactDigest.slice("sha256:".length) &&
    manifest?.sourceStateDigest === context.sourceStateDigest &&
    manifest?.productVersion === context.productVersion &&
    manifest?.buildNumber === context.buildNumber &&
    manifest?.artifactReady === true &&
    manifest?.nonBlockingDistributionGuidance?.githubReleaseBlocked === false;
  if (!commonReady) return false;
  if (spec.platform === "macos") {
    return manifest.schemaVersion === "v0.0.1:client-macos:distribution-1" &&
      manifest.installArtifactKind === spec.evidenceArtifactKind &&
      digestPattern.test(text(context.evidenceArtifactDigest)) &&
      manifest.installArtifactDigest === context.evidenceArtifactDigest &&
      digestPattern.test(text(manifest.bundleManifestDigest));
  }
  return manifest.schemaVersion === "v0.0.1:client-linux:distribution-1" &&
    manifest.mode === "release" &&
    digestPattern.test(text(manifest.bundleManifestDigest));
}

function fixtureDigest(character) {
  return `sha256:${character.repeat(64)}`;
}

function fixtureMacos({
  sourceDigest,
  artifactDigest,
  productVersion,
  generatedAt,
  closureChallengeDigest,
  invocationNonceDigest,
}) {
  return {
    schemaVersion: "licolite.secure-mesh.macos-adaptive-capabilities-receipt.v3",
    verifier: "tools/scripts/client-secure-mesh-macos-capabilities.mjs",
    generatedAt,
    closureChallengeDigest,
    invocationNonceDigest,
    ok: true,
    platform: "macos",
    redacted: true,
    reportLeakScan: true,
    rawRuntimeOutputIncluded: false,
    rawPrivateMaterialIncluded: false,
    sourceStateDigest: sourceDigest,
    dependencies: [{
      id: "macos-user-presence-proof",
      ref: "build/reports/secure-mesh-macos-keychain-user-presence-proof.json",
      digest: fixtureDigest("f"),
    }],
    receipts: [{
      targetId: "macos-arm64",
      productVersion,
      buildNumber: 7,
      artifactKind: "macos-app-bundle",
      artifactDigest,
      runtimeExecutableDigest: fixtureDigest("4"),
      signatureKind: "local-identity-codesign",
      platformLocalSignatureReady: true,
      hardenedRuntime: true,
      nestedCodeMinimalEntitlements: true,
      entitlementsMatch: true,
      entitlementsDigest: fixtureDigest("e"),
      installedArtifactMatched: true,
      installReceiptReady: true,
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
}

function fixtureAndroid({
  sourceDigest,
  artifactDigest,
  productVersion,
  generatedAt,
  closureChallengeDigest,
  invocationNonceDigest,
}) {
  return {
    schemaVersion: "licolite.secure-mesh.android-physical-install-launch-report.v3",
    verifier: "tools/scripts/client-android-physical-install-launch.mjs",
    generatedAt,
    closureChallengeDigest,
    invocationNonceDigest,
    ok: true,
    targetId: "android-arm64",
    productVersion,
    buildNumber: 7,
    platform: "android",
    physicalDevice: true,
    packageName: "com.liko.arc",
    redacted: true,
    reportLeakScan: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    apk: { sha256: artifactDigest, nativeSecureMeshAbi: "arm64-v8a" },
    apkBinaryFacts: {
      packageName: "com.liko.arc",
      versionCode: "7",
      versionName: productVersion,
      debuggable: false,
      abis: ["arm64-v8a"],
      launchableActivity: "com.liko.arc.MainActivity",
      signerCount: 1,
      signatureSchemes: ["v2"],
      zipAligned: true,
      nativeSecureMeshLibrary: {
        path: "lib/arm64-v8a/liblico_client_native.so",
        contentDigest: fixtureDigest("d"),
        size: 4096,
        compressedSize: 4096,
        crc32: "12345678",
        compression: "stored",
        regular: true,
        unique: true,
        zipEntryCount: 10,
      },
    },
    sourceBuild: { sourceStateDigest: sourceDigest },
    evidenceBinding: {
      sourceStateDigest: sourceDigest,
      apkSha256: artifactDigest,
      signatureMatchedBuildManifest: true,
    },
    signing: {
      signingKind: "local-install-keystore",
      signatureVerified: true,
      signerIdentityVerified: true,
      signingPolicySatisfied: true,
      singleSigner: true,
      signatureMatchedBuildManifest: true,
    },
    install: {
      attempted: true,
      installedViaVerifier: true,
      packagePresentAfterInstall: true,
      installedArtifactMatched: true,
    },
    launch: {
      attempted: true,
      launchedViaVerifier: true,
      runtimeStatusFreshAfterLaunch: true,
    },
    summary: {
      installReady: true,
      launchReady: true,
      runtimeStatusReady: true,
      nativeRuntimeReady: true,
      androidCustodyReady: true,
      adaptiveAuthorizationReady: true,
      evidenceBindingReady: true,
      closureChallengeBound: true,
      invocationNonceBound: true,
    },
  };
}

function fixtureLinux({
  sourceDigest,
  artifactDigest,
  productVersion,
  generatedAt,
  closureChallengeDigest,
  invocationNonceDigest,
}) {
  return {
    schema: "licolite.secure-mesh.linux-vm-package-receipt",
    schemaVersion: 2,
    producer: "linux-vm-package-receipt",
    generatedAt,
    closureChallengeDigest,
    invocationNonceDigest,
    productVersion,
    buildNumber: 7,
    ok: true,
    target: "ubuntu-linux-arm64",
    sourceBinding: {
      sourceStateDigest: sourceDigest,
      archiveDigest: artifactDigest,
      nativeClientDigest: fixtureDigest("4"),
    },
    package: { validationSignature: true, signatureVerified: true },
    summary: {
      installReceiptReady: true,
      sessionLaunchReady: true,
      smokeReady: true,
      privacyReady: true,
    },
  };
}

function runSelfTest(config, { schemaFixture = false } = {}) {
  const nowMs = Date.parse("2030-01-01T00:00:00.000Z");
  const generatedAt = new Date(nowMs - 1000).toISOString();
  const sourceDigest = fixtureDigest("1");
  const closureChallengeDigest = fixtureDigest("9");
  const closureStartedAtMs = nowMs - 2_000;
  const productVersion = "1.2.3";
  const artifacts = {
    "macos-arm64": fixtureDigest("2"),
    "android-arm64": fixtureDigest("3"),
    "linux-glibc-arm64": fixtureDigest("4"),
  };
  const evidenceArtifacts = {
    "macos-arm64": fixtureDigest("7"),
  };
  const invocationDigests = {
    "macos-arm64": fixtureDigest("a"),
    "android-arm64": fixtureDigest("b"),
    "linux-glibc-arm64": fixtureDigest("c"),
  };
  const inputFor = (targetId, payload) => ({
    payload: { ...payload, invocationNonceDigest: invocationDigests[targetId] },
    artifactDigest: artifacts[targetId],
    artifactManifestDigest: config.targets[targetId].distributionManifestRef
      ? fixtureDigest("8")
      : "",
    artifactLineageReady: true,
    evidenceArtifactDigest: evidenceArtifacts[targetId] || "",
    evidenceProducerSourceDigest: fixtureDigest("5"),
    evidenceReportDigest: fixtureDigest("6"),
    invocationStartedAtMs: nowMs - 1_500,
    invocationExitCode: 0,
    producerStable: true,
    expectedInvocationNonceDigest: invocationDigests[targetId],
  });
  const readyInputs = {
    "macos-arm64": inputFor("macos-arm64", fixtureMacos({
      sourceDigest, artifactDigest: evidenceArtifacts["macos-arm64"], productVersion, generatedAt,
      closureChallengeDigest,
      invocationNonceDigest: invocationDigests["macos-arm64"],
    })),
    "android-arm64": inputFor("android-arm64", fixtureAndroid({
      sourceDigest, artifactDigest: artifacts["android-arm64"], productVersion, generatedAt,
      closureChallengeDigest,
      invocationNonceDigest: invocationDigests["android-arm64"],
    })),
    "linux-glibc-arm64": inputFor("linux-glibc-arm64", fixtureLinux({
      sourceDigest, artifactDigest: artifacts["linux-glibc-arm64"], productVersion,
      generatedAt, closureChallengeDigest,
      invocationNonceDigest: invocationDigests["linux-glibc-arm64"],
    })),
  };
  const build = (ids, inputs = readyInputs) => buildCanonicalReceiptReport({
    config,
    selectedTargetIds: ids,
    productVersion,
    buildNumber: 7,
    sourceStateDigest: sourceDigest,
    targetInputs: inputs,
    nowMs,
    closureChallengeDigest,
    closureStartedAtMs,
    policyBindings: [
      { id: "receipt-config", ref: configRef, digest: fixtureDigest("d") },
      { id: "client-version", ref: "tools/client-version.json", digest: fixtureDigest("e") },
    ],
    linuxValidator: () => ({ ok: true }),
  });

  const macOnly = build(["macos-arm64"]);
  requireValue(macOnly.ok && macOnly.receipts.length === 1,
    "self_test_single_target_failed");
  const allTargets = build(["macos-arm64", "android-arm64", "linux-glibc-arm64"]);
  if (schemaFixture) return allTargets;
  requireValue(allTargets.ok && allTargets.receipts.length === 3,
    "self_test_three_targets_failed");
  const androidOnly = build(["android-arm64"], { "android-arm64": readyInputs["android-arm64"] });
  requireValue(androidOnly.ok && androidOnly.selectedTargetIds.length === 1,
    "self_test_unselected_target_blocked");
  requireValue(androidOnly.githubReleaseReady === true &&
    androidOnly.nonBlockingDistributionGuidance.blocking === false,
  "self_test_distribution_guidance_blocked_github_release");

  const staleInputs = structuredClone(readyInputs);
  staleInputs["macos-arm64"].payload.generatedAt = new Date(
    closureStartedAtMs - config.maxClockSkewMs - 1,
  ).toISOString();
  requireValue(!build(["macos-arm64"], staleInputs).ok,
    "self_test_stale_evidence_accepted");
  const wrongArtifact = structuredClone(readyInputs);
  wrongArtifact["android-arm64"].artifactDigest = fixtureDigest("7");
  requireValue(!build(["android-arm64"], wrongArtifact).ok,
    "self_test_wrong_artifact_digest_accepted");
  const wrongSource = structuredClone(readyInputs);
  wrongSource["macos-arm64"].payload.sourceStateDigest = fixtureDigest("8");
  requireValue(!build(["macos-arm64"], wrongSource).ok,
    "self_test_wrong_source_digest_accepted");
  const wrongProducer = structuredClone(readyInputs);
  wrongProducer["android-arm64"].payload.verifier = "tools/scripts/unapproved-producer.mjs";
  requireValue(!build(["android-arm64"], wrongProducer).ok,
    "self_test_wrong_producer_accepted");
  const wrongTarget = structuredClone(readyInputs);
  wrongTarget["android-arm64"].payload.targetId = "macos-arm64";
  requireValue(!build(["android-arm64"], wrongTarget).ok,
    "self_test_wrong_target_accepted");
  const wrongVersion = structuredClone(readyInputs);
  wrongVersion["macos-arm64"].payload.receipts[0].productVersion = "9.9.9";
  requireValue(!build(["macos-arm64"], wrongVersion).ok,
    "self_test_wrong_version_accepted");
  const adhoc = structuredClone(readyInputs);
  adhoc["macos-arm64"].payload.receipts[0].signatureKind = "local-ad-hoc-codesign";
  requireValue(!build(["macos-arm64"], adhoc).ok,
    "self_test_adhoc_signature_accepted");
  const wrongChallenge = structuredClone(readyInputs);
  wrongChallenge["android-arm64"].payload.closureChallengeDigest = fixtureDigest("0");
  requireValue(!build(["android-arm64"], wrongChallenge).ok,
    "self_test_wrong_closure_challenge_accepted");
  const failedInvocation = structuredClone(readyInputs);
  failedInvocation["macos-arm64"].invocationExitCode = 1;
  requireValue(!build(["macos-arm64"], failedInvocation).ok,
    "self_test_failed_invocation_reused_old_green_report");
  const changedProducer = structuredClone(readyInputs);
  changedProducer["macos-arm64"].producerStable = false;
  requireValue(!build(["macos-arm64"], changedProducer).ok,
    "self_test_changed_producer_accepted");
  const wrongInvocationNonce = structuredClone(readyInputs);
  wrongInvocationNonce["android-arm64"].payload.invocationNonceDigest = fixtureDigest("f");
  requireValue(!build(["android-arm64"], wrongInvocationNonce).ok,
    "self_test_wrong_invocation_nonce_accepted");
  const duplicateInvocationNonce = structuredClone(readyInputs);
  duplicateInvocationNonce["android-arm64"].expectedInvocationNonceDigest =
    duplicateInvocationNonce["macos-arm64"].expectedInvocationNonceDigest;
  duplicateInvocationNonce["android-arm64"].payload.invocationNonceDigest =
    duplicateInvocationNonce["macos-arm64"].payload.invocationNonceDigest;
  let duplicateNonceRejected = false;
  try {
    build(["macos-arm64", "android-arm64"], duplicateInvocationNonce);
  } catch {
    duplicateNonceRejected = true;
  }
  requireValue(duplicateNonceRejected, "self_test_duplicate_invocation_nonce_accepted");
  const wrongBuild = structuredClone(readyInputs);
  wrongBuild["android-arm64"].payload.buildNumber = 8;
  requireValue(!build(["android-arm64"], wrongBuild).ok,
    "self_test_wrong_build_number_accepted");
  const wrongEntitlements = structuredClone(readyInputs);
  wrongEntitlements["macos-arm64"].payload.receipts[0].entitlementsMatch = false;
  requireValue(!build(["macos-arm64"], wrongEntitlements).ok,
    "self_test_wrong_entitlements_accepted");
  const wrongDistributionLineage = structuredClone(readyInputs);
  wrongDistributionLineage["macos-arm64"].artifactLineageReady = false;
  requireValue(!build(["macos-arm64"], wrongDistributionLineage).ok,
    "self_test_wrong_distribution_lineage_accepted");
  const debugApk = structuredClone(readyInputs);
  debugApk["android-arm64"].payload.apkBinaryFacts.debuggable = true;
  requireValue(!build(["android-arm64"], debugApk).ok,
    "self_test_debug_apk_accepted");
  const distributionMetadataChanged = structuredClone(readyInputs);
  distributionMetadataChanged["android-arm64"].payload.nonBlockingDistributionGuidance = {
    blocking: false,
    storeListingStatus: "planned",
  };
  requireValue(build(["android-arm64"], distributionMetadataChanged).ok,
    "self_test_distribution_guidance_blocked_github_release");
  const privacyKey = ["device", "Id"].join("");
  let privacyRejected = false;
  try {
    assertReceiptPrivacy({ ...macOnly, [privacyKey]: "fixture" });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected, "self_test_private_field_accepted");
  privacyRejected = false;
  try {
    const hostileCertificateDigestKey = ["certificate", "Identity", "Digest"].join("");
    assertReceiptPrivacy({ [hostileCertificateDigestKey]: fixtureDigest("f") });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected, "self_test_stable_signing_identity_accepted");
  const privateValue = ["", "Users", "fixture", "artifact"].join("/");
  privacyRejected = false;
  try {
    assertReceiptPrivacy({ ...macOnly, fixture: privateValue });
  } catch {
    privacyRejected = true;
  }
  requireValue(privacyRejected, "self_test_private_value_accepted");
  let emptyTokenRejected = false;
  try {
    selectedTargetIds({
      targets: "macos-arm64,",
      targetsSpecified: true,
    }, config);
  } catch {
    emptyTokenRejected = true;
  }
  requireValue(emptyTokenRejected, "receipt_explicit_empty_target_token_accepted");
  requireValue(JSON.stringify(selectedTargetIds({
    targets: "linux-glibc-arm64,macos-arm64",
    targetsSpecified: true,
  }, config)) === JSON.stringify(["macos-arm64", "linux-glibc-arm64"]),
  "receipt_target_authority_order_not_canonical");
  return { ok: true, caseCount: 28, privatePathsIncluded: false };
}

function main() {
  const argv = process.argv.slice(2);
  const selfTestRequested = argv.includes("--self-test");
  const schemaFixtureRequested = argv.includes("--schema-fixture");
  if (!selfTestRequested && !schemaFixtureRequested) {
    removeContainedReportIfExists(
      path.join(repoRoot, "build"),
      buildRelativeRef(canonicalReportRef),
    );
  }
  const options = parseArgs(argv);
  const safeConfigPath = resolveContainedExistingPath(
    path.join(repoRoot, "tools/scripts/config"),
    configPath,
    { expectedKind: "file" },
  );
  if (options.selfTest) {
    const config = validateConfig(readJson(safeConfigPath));
    console.log(JSON.stringify(runSelfTest(config)));
    return;
  }
  if (options.schemaFixture) {
    const config = validateConfig(readJson(safeConfigPath));
    console.log(JSON.stringify(runSelfTest(config, { schemaFixture: true })));
    return;
  }
  const sourceStateDigest = clientSourceStateDigest(
    repoRoot,
    CANONICAL_CLIENT_SOURCE_ROOTS,
  );
  const policySnapshots = [
    captureSourceBoundJsonPolicy({
      allowedRoot: path.join(repoRoot, "tools/scripts/config"),
      filePath: safeConfigPath,
      id: "receipt-config",
      ref: configRef,
    }),
    captureSourceBoundJsonPolicy({
      allowedRoot: path.join(repoRoot, "tools"),
      filePath: path.join(repoRoot, "tools/client-version.json"),
      id: "client-version",
      ref: "tools/client-version.json",
    }),
  ];
  const config = validateConfig(policySnapshots[0].payload);
  const reportRef = canonicalReportRef;
  const relativeReportRef = buildRelativeRef(reportRef);
  const targets = selectedTargetIds(options, config);
  const clientVersion = policySnapshots[1].payload;
  const productVersion = text(clientVersion.productVersion);
  const buildNumber = clientVersion.buildNumber;
  const inheritedChallenge = text(process.env.LICO_CLIENT_RELEASE_CLOSURE_CHALLENGE);
  const closureChallenge = inheritedChallenge
    ? requiredReleaseClosureChallenge()
    : createReleaseClosureChallenge();
  const inheritedStartedAt = text(process.env.LICO_CLIENT_RELEASE_CLOSURE_STARTED_AT);
  const closureStartedAt = inheritedStartedAt
    ? new Date(requiredReleaseClosureStartedAt().milliseconds)
    : new Date();
  const closureChallengeDigest = releaseClosureChallengeDigest(closureChallenge);
  const targetInputs = Object.fromEntries(targets.map((targetId) => [
    targetId,
    invokeAndLoadTargetInput(
      config.targets[targetId],
      closureChallenge,
      closureStartedAt,
      { sourceStateDigest, productVersion, buildNumber },
    ),
  ]));
  requireValue(sourceBoundPolicySnapshotsStable(policySnapshots),
    "receipt_policy_changed_during_closure");
  requireValue(clientSourceStateDigest(repoRoot, config.sourceRoots) === sourceStateDigest,
    "receipt_source_changed_during_closure");
  const report = buildCanonicalReceiptReport({
    config,
    selectedTargetIds: targets,
    productVersion,
    buildNumber,
    sourceStateDigest,
    targetInputs,
    closureChallengeDigest,
    closureStartedAtMs: closureStartedAt.getTime(),
    policyBindings: publicPolicyBindings(policySnapshots),
  });
  atomicWriteReportJson(path.join(repoRoot, "build"), relativeReportRef, report);
  console.log(JSON.stringify({
    ok: report.ok,
    selectedTargetIds: report.selectedTargetIds,
    receiptCount: report.receipts.length,
    readyCount: report.receipts.filter((receipt) => receipt.ready).length,
    report: reportRef,
    privatePathsIncluded: false,
  }));
  if (!report.ok) process.exitCode = 1;
}

try {
  main();
} catch (error) {
  console.error(JSON.stringify({
    ok: false,
    reason: error instanceof ReceiptValidationError
      ? error.code
      : "artifact_receipt_reducer_failed",
    privatePathsIncluded: false,
  }));
  process.exitCode = 1;
}
