import { validateCapabilityReport } from "./secure-mesh-capability-report.mjs";
import { SAFE_REPORT_WRITE_STAGES } from "./safe-report-io.mjs";

export const linuxVmPackageReceiptSchema = "licolite.secure-mesh.linux-vm-package-receipt";
export const linuxNodeMatrixSchema = "licolite.secure-mesh.linux-node-matrix";
export const linuxVmPackageReceiptSchemaVersion = 2;
export const linuxEvidenceSchemaVersion = 1;

const VM_KEYS = Object.freeze([
  "schema",
  "schemaVersion",
  "ok",
  "producer",
  "generatedAt",
  "closureChallengeDigest",
  "invocationNonceDigest",
  "productVersion",
  "buildNumber",
  "artifactKind",
  "target",
  "redacted",
  "reportLeakScan",
  "rawPrivateMaterialIncluded",
  "rawPlaintextIncluded",
  "rawPublicWireBytesIncluded",
  "sourceBinding",
  "package",
  "session",
  "smoke",
  "capabilityReport",
  "privacy",
  "nonBlockingDistributionGuidance",
  "summary"
]);
const NODE_KEYS = Object.freeze([
  "schema",
  "schemaVersion",
  "ok",
  "producer",
  "artifactKind",
  "target",
  "redacted",
  "reportLeakScan",
  "rawPrivateMaterialIncluded",
  "rawPlaintextIncluded",
  "rawPublicWireBytesIncluded",
  "sourceBinding",
  "runtime",
  "isolation",
  "pairwise",
  "restart",
  "teardown",
  "capabilityReport",
  "privacy",
  "summary"
]);
const FORBIDDEN_KEYS = new Set([
  "host",
  "hostname",
  "username",
  "userName",
  "containerId",
  "runtimeId",
  "processId",
  "pid",
  "port",
  "dbusAddress",
  "objectPath",
  "itemPath",
  "localPath",
  "absolutePath",
  "stateRoot",
  "installRoot",
  "archivePath",
  "bundlePath",
  "rawLog",
  "stdout",
  "stderr",
  "plaintextSample",
  "ciphertextSample",
  "secretValue",
  "tokenValue"
]);
const FORBIDDEN_VALUES = Object.freeze([
  /(?:^|["'\s])unix:(?:path|abstract)=/iu,
  /\/org\/freedesktop\/(?:DBus|secrets)(?:\/|$)/u,
  /\/(?:Users|home|private|tmp|run|var\/folders)\//u,
  /[A-Za-z]:\\/u,
  /-----BEGIN|-----END/u,
  /Bearer\s+(?!\[redacted\])\S+/u,
  /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u
]);
const LINUX_EVIDENCE_FAILURE_CATEGORIES = new Set([
  "artifact",
  "binding",
  "capability",
  "privacy",
  "producer",
  "readiness",
  "schema",
  "session",
]);
const LINUX_EVIDENCE_RULE_ID = /^[a-z][a-z0-9_]{2,95}$/u;
const LINUX_VM_FAILURE_PHASES = new Set([
  "input_validation",
  "archive_binding",
  "archive_install",
  "cli_smoke",
  "gui_session",
  "gui_display",
  "gui_process",
  "gui_window",
  "gui_interaction",
  "gui_shutdown",
  "gui_stderr",
  "receipt_validation",
  "receipt_write",
]);

export class LinuxEvidenceValidationError extends Error {
  constructor(ruleId, category) {
    super("Linux evidence validation failed");
    this.name = "LinuxEvidenceValidationError";
    this.ruleId = ruleId;
    this.category = category;
  }
}

function assertRule(condition, ruleId, category) {
  if (!condition) throw new LinuxEvidenceValidationError(ruleId, category);
}

export function classifyLinuxEvidenceValidationFailure(
  error,
  fallbackRuleId = "linux_evidence_validation_unclassified",
) {
  const ruleId = error instanceof LinuxEvidenceValidationError &&
    LINUX_EVIDENCE_RULE_ID.test(String(error.ruleId || ""))
    ? error.ruleId
    : fallbackRuleId;
  const category = error instanceof LinuxEvidenceValidationError &&
    LINUX_EVIDENCE_FAILURE_CATEGORIES.has(error.category)
    ? error.category
    : "schema";
  return Object.freeze({ ruleId, category });
}

export function createLinuxVmPackageFailureRecord(phase, failure) {
  assertRule(LINUX_VM_FAILURE_PHASES.has(phase),
    "linux_vm_failure_phase_valid", "schema");
  assertRule(failure && LINUX_EVIDENCE_RULE_ID.test(String(failure.ruleId || "")),
    "linux_vm_failure_rule_id_valid", "schema");
  assertRule(LINUX_EVIDENCE_FAILURE_CATEGORIES.has(failure.category),
    "linux_vm_failure_category_valid", "schema");
  return Object.freeze({
    schema: linuxVmPackageReceiptSchema,
    schemaVersion: linuxVmPackageReceiptSchemaVersion,
    ok: false,
    artifactKind: "linux-vm-installed-client",
    reason: "linux_vm_package_receipt_incomplete",
    phase,
    validationRuleId: failure.ruleId,
    failureCategory: failure.category,
    redacted: true,
    reportLeakScan: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    privacy: linuxEvidencePrivacyRecord(),
  });
}

export function classifyLinuxVmProducerFailure(phase, error) {
  if (phase === "receipt_validation") {
    return classifyLinuxEvidenceValidationFailure(
      error,
      "linux_vm_receipt_validation_unclassified",
    );
  }
  if (phase === "receipt_write" && error instanceof LinuxEvidenceValidationError) {
    return classifyLinuxEvidenceValidationFailure(
      error,
      "linux_vm_producer_receipt_write_failed",
    );
  }
  const phaseRules = Object.freeze({
    input_validation: "linux_vm_producer_input_validation_failed",
    archive_binding: "linux_vm_producer_archive_binding_failed",
    archive_install: "linux_vm_producer_archive_install_failed",
    cli_smoke: "linux_vm_producer_cli_smoke_failed",
    gui_session: "linux_vm_producer_gui_session_failed",
    gui_display: "linux_vm_producer_gui_display_failed",
    gui_process: "linux_vm_producer_gui_process_failed",
    gui_window: "linux_vm_producer_gui_window_failed",
    gui_interaction: "linux_vm_producer_gui_interaction_failed",
    gui_shutdown: "linux_vm_producer_gui_shutdown_failed",
    gui_stderr: "linux_vm_producer_gui_stderr_failed",
    receipt_write: "linux_vm_producer_receipt_write_failed",
  });
  return Object.freeze({
    ruleId: phaseRules[phase] || "linux_vm_producer_unclassified_failure",
    category: "producer",
  });
}

export function linuxVmReceiptWriteFailure(stage) {
  if (!SAFE_REPORT_WRITE_STAGES.includes(stage)) {
    return new LinuxEvidenceValidationError(
      "linux_vm_receipt_write_stage_invalid",
      "producer",
    );
  }
  return new LinuxEvidenceValidationError(
    `linux_vm_receipt_write_${stage}_failed`,
    "producer",
  );
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
}

function assertExactKeys(value, expected, label) {
  assert(isPlainObject(value), `${label} must be an object`);
  const keys = Object.keys(value);
  assert(
    keys.length === expected.length && expected.every((key) => keys.includes(key)),
    `${label} fields are not exact`
  );
}

function assertDigest(value, label) {
  assert(/^sha256:[a-f0-9]{64}$/u.test(String(value || "")), `${label} is invalid`);
}

function scanPrivacy(value) {
  if (Array.isArray(value)) {
    for (const item of value) scanPrivacy(item);
    return;
  }
  if (isPlainObject(value)) {
    for (const [key, nested] of Object.entries(value)) {
      assert(!FORBIDDEN_KEYS.has(key), "Linux evidence contains a forbidden runtime field");
      scanPrivacy(nested);
    }
    return;
  }
  if (typeof value === "string") {
    assert(
      FORBIDDEN_VALUES.every((pattern) => !pattern.test(value)),
      "Linux evidence contains machine-local, runtime, or credential data"
    );
  }
}

function validatePrivacyRecord(privacy) {
  assertExactKeys(privacy, [
    "redacted",
    "runtimeIdentityIncluded",
    "localPathIncluded",
    "dbusOrObjectDataIncluded",
    "rawLogsIncluded",
    "rawPlaintextIncluded",
    "rawCiphertextIncluded",
    "rawSecretsIncluded"
  ], "Linux evidence privacy record");
  assert(privacy.redacted === true, "Linux evidence is not marked redacted");
  for (const key of Object.keys(privacy).filter((key) => key !== "redacted")) {
    assert(privacy[key] === false, `Linux evidence privacy field ${key} must be false`);
  }
}

function validateRootRedaction(report) {
  assert(report.redacted === true && report.reportLeakScan === true,
    "Linux evidence root redaction declaration is incomplete");
  for (const key of [
    "rawPrivateMaterialIncluded",
    "rawPlaintextIncluded",
    "rawPublicWireBytesIncluded"
  ]) {
    assert(report[key] === false, `Linux evidence root field ${key} must be false`);
  }
}

function validateSourceBinding(binding, expectedSourceDigest) {
  assertExactKeys(binding, [
    "sourceStateDigest",
    "sourceStateDigestProvenance",
    "archiveDigest",
    "bundleManifestDigest",
    "nativeClientDigest",
    "stale"
  ], "Linux evidence source binding");
  assertDigest(binding.sourceStateDigest, "Linux evidence source-state digest");
  assertDigest(binding.archiveDigest, "Linux evidence archive digest");
  assertDigest(binding.bundleManifestDigest, "Linux evidence bundle-manifest digest");
  assertDigest(binding.nativeClientDigest, "Linux evidence native-client digest");
  assert(
    ["git-worktree", "vm-orchestrator-verified"].includes(binding.sourceStateDigestProvenance),
    "Linux evidence source-state provenance is invalid"
  );
  assert(binding.stale === false, "Linux evidence is stale");
  if (expectedSourceDigest) {
    assertDigest(expectedSourceDigest, "Expected Linux source-state digest");
    assert(binding.sourceStateDigest === expectedSourceDigest, "Linux evidence source binding is stale");
  }
}

export function validateLinuxVmPackageReceipt(
  report,
  expectedSourceDigest = "",
  expectedProductVersion = "",
  expectedBuildNumber = 0,
) {
  try {
    return validateLinuxVmPackageReceiptInternal(
      report,
      expectedSourceDigest,
      expectedProductVersion,
      expectedBuildNumber,
    );
  } catch (error) {
    if (error instanceof LinuxEvidenceValidationError) throw error;
    throw new LinuxEvidenceValidationError(
      "linux_vm_validator_internal_operation_failed",
      "schema",
    );
  }
}

function validateLinuxVmPackageReceiptInternal(
  report,
  expectedSourceDigest,
  expectedProductVersion,
  expectedBuildNumber,
) {
  assertRule(isPlainObject(report) && Object.keys(report).length === VM_KEYS.length &&
    VM_KEYS.every((key) => Object.hasOwn(report, key)),
  "linux_vm_receipt_fields_exact", "schema");
  assertRule(report.schema === linuxVmPackageReceiptSchema,
    "linux_vm_receipt_schema_match", "schema");
  assertRule(report.schemaVersion === linuxVmPackageReceiptSchemaVersion,
    "linux_vm_receipt_schema_version_match", "schema");
  assertRule(Number.isFinite(Date.parse(String(report.generatedAt || ""))),
    "linux_vm_receipt_generated_at_valid", "schema");
  assertRule(/^sha256:[a-f0-9]{64}$/u.test(String(report.closureChallengeDigest || "")),
    "linux_vm_closure_challenge_digest_valid", "binding");
  assertRule(/^sha256:[a-f0-9]{64}$/u.test(String(report.invocationNonceDigest || "")),
    "linux_vm_invocation_nonce_digest_valid", "binding");
  assertRule(typeof report.productVersion === "string" && report.productVersion.trim() !== "",
    "linux_vm_product_version_present", "binding");
  assertRule(Number.isInteger(report.buildNumber) && report.buildNumber > 0,
    "linux_vm_build_number_valid", "binding");
  if (expectedProductVersion) {
    assertRule(report.productVersion === expectedProductVersion,
      "linux_vm_product_version_match", "binding");
  }
  if (expectedBuildNumber) {
    assertRule(report.buildNumber === expectedBuildNumber,
      "linux_vm_build_number_match", "binding");
  }
  assertRule(report.nonBlockingDistributionGuidance?.blocking === false,
    "linux_vm_distribution_guidance_non_blocking", "readiness");
  assertRule(report.redacted === true && report.reportLeakScan === true,
    "linux_vm_root_redaction_declared", "privacy");
  for (const key of [
    "rawPrivateMaterialIncluded",
    "rawPlaintextIncluded",
    "rawPublicWireBytesIncluded",
  ]) {
    assertRule(report[key] === false, `linux_vm_root_${key.replaceAll(/([A-Z])/gu, "_$1").toLowerCase()}_false`,
      "privacy");
  }
  const binding = report.sourceBinding;
  const bindingKeys = [
    "sourceStateDigest",
    "sourceStateDigestProvenance",
    "archiveDigest",
    "bundleManifestDigest",
    "nativeClientDigest",
    "stale",
  ];
  assertRule(isPlainObject(binding) && Object.keys(binding).length === bindingKeys.length &&
    bindingKeys.every((key) => Object.hasOwn(binding, key)),
  "linux_vm_source_binding_fields_exact", "schema");
  for (const [key, ruleId] of [
    ["sourceStateDigest", "linux_vm_source_state_digest_valid"],
    ["archiveDigest", "linux_vm_archive_digest_valid"],
    ["bundleManifestDigest", "linux_vm_bundle_manifest_digest_valid"],
    ["nativeClientDigest", "linux_vm_native_client_digest_valid"],
  ]) {
    assertRule(/^sha256:[a-f0-9]{64}$/u.test(String(binding[key] || "")), ruleId, "binding");
  }
  assertRule(["git-worktree", "vm-orchestrator-verified"].includes(
    binding.sourceStateDigestProvenance),
  "linux_vm_source_provenance_valid", "binding");
  assertRule(binding.stale === false, "linux_vm_source_not_stale", "binding");
  if (expectedSourceDigest) {
    assertRule(/^sha256:[a-f0-9]{64}$/u.test(String(expectedSourceDigest)),
      "linux_vm_expected_source_digest_valid", "binding");
    assertRule(binding.sourceStateDigest === expectedSourceDigest,
      "linux_vm_expected_source_digest_match", "binding");
  }
  const packageKeys = [
    "format",
    "layoutClasses",
    "executableCount",
    "signaturePresent",
    "validationSignature",
    "signatureVerified",
    "archiveDigestVerified",
    "bundleManifestDigestVerified",
    "installedFromArchive",
  ];
  assertRule(isPlainObject(report.package) &&
    Object.keys(report.package).length === packageKeys.length &&
    packageKeys.every((key) => Object.hasOwn(report.package, key)),
  "linux_vm_package_fields_exact", "schema");
  assertRule(report.package.format === "tar.gz", "linux_vm_archive_format_valid", "artifact");
  assertRule(
    JSON.stringify(report.package.layoutClasses) === JSON.stringify([
      "desktop_executable",
      "native_sidecar",
      "flutter_assets",
      "package_metadata"
    ]), "linux_vm_archive_layout_valid", "artifact"
  );
  assertRule(report.package.executableCount === 2,
    "linux_vm_package_executable_count_valid", "artifact");
  for (const key of [
    "signaturePresent",
    "validationSignature",
    "signatureVerified",
    "archiveDigestVerified",
    "bundleManifestDigestVerified",
    "installedFromArchive"
  ]) {
    const snake = key.replaceAll(/([A-Z])/gu, "_$1").toLowerCase();
    assertRule(report.package[key] === true, `linux_vm_package_${snake}_ready`, "artifact");
  }
  const sessionKeys = [
    "kind",
    "clientStarted",
    "visibleWindow",
    "interactionSmoke",
    "boundedShutdown",
  ];
  assertRule(isPlainObject(report.session) &&
    Object.keys(report.session).length === sessionKeys.length &&
    sessionKeys.every((key) => Object.hasOwn(report.session, key)),
  "linux_vm_session_fields_exact", "schema");
  assertRule(report.session.kind === "x11_virtual_display",
    "linux_vm_session_kind_valid", "session");
  for (const key of ["clientStarted", "visibleWindow", "interactionSmoke", "boundedShutdown"]) {
    const snake = key.replaceAll(/([A-Z])/gu, "_$1").toLowerCase();
    assertRule(report.session[key] === true, `linux_vm_session_${snake}_ready`, "session");
  }
  const smokeKeys = ["cliTargetScan", "guiSession", "exactCapabilitySchema"];
  assertRule(isPlainObject(report.smoke) && Object.keys(report.smoke).length === smokeKeys.length &&
    smokeKeys.every((key) => Object.hasOwn(report.smoke, key)),
  "linux_vm_smoke_fields_exact", "schema");
  for (const key of smokeKeys) {
    const snake = key.replaceAll(/([A-Z])/gu, "_$1").toLowerCase();
    assertRule(report.smoke[key] === true, `linux_vm_smoke_${snake}_ready`, "readiness");
  }
  try {
    validateCapabilityReport(report.capabilityReport);
  } catch {
    throw new LinuxEvidenceValidationError("linux_vm_capability_report_valid", "capability");
  }
  const privacyKeys = [
    "redacted",
    "runtimeIdentityIncluded",
    "localPathIncluded",
    "dbusOrObjectDataIncluded",
    "rawLogsIncluded",
    "rawPlaintextIncluded",
    "rawCiphertextIncluded",
    "rawSecretsIncluded",
  ];
  assertRule(isPlainObject(report.privacy) &&
    Object.keys(report.privacy).length === privacyKeys.length &&
    privacyKeys.every((key) => Object.hasOwn(report.privacy, key)),
  "linux_vm_privacy_fields_exact", "schema");
  assertRule(report.privacy.redacted === true, "linux_vm_privacy_redacted", "privacy");
  for (const key of privacyKeys.filter((key) => key !== "redacted")) {
    const snake = key.replaceAll(/([A-Z])/gu, "_$1").toLowerCase();
    assertRule(report.privacy[key] === false, `linux_vm_privacy_${snake}_false`, "privacy");
  }
  const summaryKeys = [
    "currentSourceArchive",
    "installReceiptReady",
    "sessionLaunchReady",
    "smokeReady",
    "privacyReady",
  ];
  assertRule(isPlainObject(report.summary) &&
    Object.keys(report.summary).length === summaryKeys.length &&
    summaryKeys.every((key) => Object.hasOwn(report.summary, key)),
  "linux_vm_summary_fields_exact", "schema");
  for (const key of summaryKeys) {
    const snake = key.replaceAll(/([A-Z])/gu, "_$1").toLowerCase();
    assertRule(report.summary[key] === true, `linux_vm_summary_${snake}`, "readiness");
  }
  assertRule(report.ok === true, "linux_vm_receipt_ready", "readiness");
  try {
    scanPrivacy(report);
  } catch {
    throw new LinuxEvidenceValidationError("linux_vm_privacy_value_scan_clean", "privacy");
  }
  return Object.freeze({ ok: true, sourceStateDigest: report.sourceBinding.sourceStateDigest });
}

export function validateLinuxNodeMatrixReport(report, expectedSourceDigest = "") {
  assertExactKeys(report, NODE_KEYS, "Linux node matrix report");
  assert(report.schema === linuxNodeMatrixSchema, "Linux node matrix schema is invalid");
  assert(report.schemaVersion === linuxEvidenceSchemaVersion,
    "Linux node matrix schema version is invalid");
  validateRootRedaction(report);
  validateSourceBinding(report.sourceBinding, expectedSourceDigest);
  assertExactKeys(report.runtime, [
    "kind",
    "nodeCount",
    "currentClientArchive",
    "publicOperationsOnly",
    "eventDrivenReadiness"
  ], "Linux node runtime record");
  assert(report.runtime.kind === "isolated_linux_containers" && report.runtime.nodeCount === 3,
    "Linux node runtime shape is invalid");
  assert(report.runtime.currentClientArchive === true && report.runtime.publicOperationsOnly === true &&
    report.runtime.eventDrivenReadiness === true, "Linux node runtime proof is incomplete");
  assertExactKeys(report.isolation, [
    "participantLabels",
    "distinctStateRoots",
    "noSharedSecretVolume",
    "uniquePublicIdentityCount",
    "crossNodeStateReadRejected",
    "containerIsolation"
  ], "Linux node isolation record");
  assert(
    JSON.stringify(report.isolation.participantLabels) ===
      JSON.stringify(["linux-a", "linux-b", "linux-c"]),
    "Linux node participant labels are invalid"
  );
  assert(report.isolation.uniquePublicIdentityCount === 3,
    "Linux nodes did not prove three unique public identities");
  for (const key of [
    "distinctStateRoots",
    "noSharedSecretVolume",
    "crossNodeStateReadRejected",
    "containerIsolation"
  ]) {
    assert(report.isolation[key] === true, `Linux node isolation field ${key} is incomplete`);
  }
  assertExactKeys(report.pairwise, [
    "exchangeCount",
    "allNodesParticipated",
    "secureSessionsEstablished",
    "opaqueRelay",
    "relayPlaintextObserved",
    "relayCiphertextIncludedInReport"
  ], "Linux node pairwise record");
  assert(report.pairwise.exchangeCount >= 2 && report.pairwise.allNodesParticipated === true &&
    report.pairwise.secureSessionsEstablished === true && report.pairwise.opaqueRelay === true &&
    report.pairwise.relayPlaintextObserved === false &&
    report.pairwise.relayCiphertextIncludedInReport === false,
  "Linux node pairwise proof is incomplete");
  assertExactKeys(report.restart, [
    "restartedParticipant",
    "restartedProcessCount",
    "restartRequiresRePairRekey",
    "unaffectedParticipantCount",
    "postRestartExchangeReady",
    "stateContaminationDetected"
  ], "Linux node restart record");
  assert(report.restart.restartedParticipant === "linux-a" &&
    report.restart.restartedProcessCount === 1 &&
    report.restart.restartRequiresRePairRekey === true &&
    report.restart.unaffectedParticipantCount === 2 &&
    report.restart.postRestartExchangeReady === true &&
    report.restart.stateContaminationDetected === false,
  "Linux node restart isolation proof is incomplete");
  assertExactKeys(report.teardown, [
    "bounded",
    "nodeCount",
    "allProcessesStopped",
    "allContainersRemoved",
    "ephemeralStateRemoved"
  ], "Linux node teardown record");
  assert(report.teardown.bounded === true && report.teardown.nodeCount === 3 &&
    report.teardown.allProcessesStopped === true &&
    report.teardown.allContainersRemoved === true &&
    report.teardown.ephemeralStateRemoved === true,
  "Linux node teardown proof is incomplete");
  validateCapabilityReport(report.capabilityReport);
  validatePrivacyRecord(report.privacy);
  assertExactKeys(report.summary, [
    "currentSourceNodes",
    "isolationReady",
    "pairwiseReady",
    "restartIsolationReady",
    "teardownReady",
    "privacyReady"
  ], "Linux node summary");
  assert(Object.values(report.summary).every((value) => value === true),
    "Linux node matrix summary is incomplete");
  assert(report.ok === true, "Linux node matrix report is not ready");
  scanPrivacy(report);
  return Object.freeze({ ok: true, sourceStateDigest: report.sourceBinding.sourceStateDigest });
}

export function linuxEvidencePrivacyRecord() {
  return Object.freeze({
    redacted: true,
    runtimeIdentityIncluded: false,
    localPathIncluded: false,
    dbusOrObjectDataIncluded: false,
    rawLogsIncluded: false,
    rawPlaintextIncluded: false,
    rawCiphertextIncluded: false,
    rawSecretsIncluded: false
  });
}
