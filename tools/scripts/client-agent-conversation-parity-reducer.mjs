#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const CONTRACT_VERSION = "CL-06";
export const EVIDENCE_SCHEMA_VERSION =
  "v0.0.1:client-agent-conversation-parity-evidence-1";
export const READINESS_SCHEMA_VERSION =
  "v0.0.1:client-agent-conversation-readiness-1";
export const INVENTORY_SCHEMA_VERSION =
  "v0.0.1:client-agent-conversation-drivers-1";
export const MINIMUM_CONSECUTIVE_PASSES = 3;

export const CORE_CHECK_IDS = Object.freeze([
  "P-01",
  "P-02",
  "P-03",
  "P-04",
  "P-05",
  "P-06",
  "P-07",
  "P-08",
  "P-09",
  "P-10",
]);

export const CONDITIONAL_CHECK_IDS = Object.freeze([
  "C-01",
  "C-02",
  "C-03",
  "C-04",
  "C-05",
  "C-06",
]);

const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = resolve(SCRIPT_DIRECTORY, "../..");
const PACKAGING_REGISTRY_FILE = resolve(
  REPOSITORY_ROOT,
  "apps/desktop/packaging.modules.json",
);
const DRIVER_INVENTORY_FILE = resolve(
  REPOSITORY_ROOT,
  "crates/lico-client-native/resources/agent-conversation-drivers.json",
);
const READINESS_FILE = resolve(
  REPOSITORY_ROOT,
  "crates/lico-client-native/resources/agent-conversation-readiness.json",
);
const CANONICAL_EVIDENCE_FILE = resolve(
  REPOSITORY_ROOT,
  "crates/lico-client-native/resources/agent-conversation-evidence.json",
);

const SAFE_CODE = /^[a-z0-9][a-z0-9._:+-]{0,127}$/;
const SHA256_DIGEST = /^sha256:[a-f0-9]{64}$/;
const CORE_RESULTS = new Set(["pass", "fail", "unverified"]);
const NATIVE_SUPPORT_RESULTS = new Set(["supported", "unsupported", "unknown"]);
const CONDITIONAL_RESULTS = new Set([
  "pass",
  "fail",
  "gap",
  "unverified",
  "unsupported-by-native",
]);
const DRIVER_MODES = new Set(["conversation", "blocked", "history-only"]);
const EVIDENCE_BLOCKING_CODES = new Set([
  "authorized_test_environment_missing",
  "canonical_driver_missing",
  "official_native_lane_missing",
  "safe_cleanup_unavailable",
  "exact_session_resume_unavailable",
]);
const INVENTORY_BLOCKING_CODES = new Set([
  ...EVIDENCE_BLOCKING_CODES,
  "antigravity_public_transport_unavailable",
]);

const SENSITIVE_KEY_FRAGMENTS = Object.freeze([
  "prompt",
  "response",
  "path",
  "session",
  "thread",
  "argv",
  "account",
  "credential",
  "stderr",
  "stdout",
  "message",
  "content",
  "payload",
  "attachment",
  "secret",
  "token",
  "cookie",
  "password",
  "passwd",
  "privatekey",
  "authorization",
  "username",
  "hostname",
  "rawlog",
  "logtext",
  "conversationid",
  "turnid",
  "workingdirectory",
  "cwd",
]);

const EVIDENCE_TOP_LEVEL_FIELDS = new Set([
  "schemaVersion",
  "contractVersion",
  "harnessVersion",
  "toolVersionClass",
  "generatedAt",
  "adapters",
]);
const ADAPTER_EVIDENCE_FIELDS = new Set([
  "agentId",
  "driverId",
  "runtimeProtocol",
  "harnessVersion",
  "runtimeVersionClass",
  "runtimeVersionDigest",
  "capabilitySnapshotDigest",
  "runtimeSourceClass",
  "registryDigest",
  "driverInventoryDigest",
  "evidenceDigest",
  "officialNativeLane",
  "consecutivePasses",
  "releaseUiPassed",
  "cleanupPassed",
  "privacyPassed",
  "coreChecks",
  "conditionalChecks",
  "blockingCode",
]);
const CONDITIONAL_EVIDENCE_FIELDS = new Set(["nativeSupport", "result"]);
const INVENTORY_TOP_LEVEL_FIELDS = new Set([
  "schemaVersion",
  "contractVersion",
  "evidenceContract",
  "drivers",
]);
const INVENTORY_CONTRACT_FIELDS = new Set([
  "minimumConsecutivePasses",
  "coreChecks",
  "conditionalChecks",
  "requiredBooleans",
  "requiredCounts",
  "requiredDigests",
  "requiredBindings",
]);
const INVENTORY_DRIVER_FIELDS = new Set([
  "agentId",
  "driverId",
  "runtimeProtocol",
  "officialNativeLaneKind",
  "historyReadable",
  "driverMode",
  "blockerCodes",
  "capabilityMatrix",
]);

const CAPABILITY_MATRIX_FIELDS = new Set([
  "laneFamily",
  "openNew",
  "exactResume",
  "streaming",
  "cancel",
  "structuredEvents",
  "approvals",
  "multimodal",
  "usageStatus",
  "officialLane",
]);

const LANE_FAMILIES = new Set([
  "acp",
  "app-server",
  "stream-json",
  "unavailable",
]);

export class ReducerError extends Error {
  constructor(code) {
    super(code);
    this.name = "ReducerError";
    this.code = SAFE_CODE.test(code) ? code : "reducer_error";
  }
}

function fail(code) {
  throw new ReducerError(code);
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function normalizedKey(key) {
  return key.toLowerCase().replaceAll(/[^a-z0-9]/g, "");
}

export function assertNoSensitiveFields(value) {
  const pending = [value];
  while (pending.length > 0) {
    const current = pending.pop();
    if (Array.isArray(current)) {
      pending.push(...current);
      continue;
    }
    if (!isPlainObject(current)) {
      continue;
    }
    for (const [key, nested] of Object.entries(current)) {
      const candidate = normalizedKey(key);
      if (SENSITIVE_KEY_FRAGMENTS.some((fragment) => candidate.includes(fragment))) {
        fail("sensitive_evidence_field_rejected");
      }
      pending.push(nested);
    }
  }
}

function assertOnlyFields(value, allowedFields, errorCode) {
  if (!isPlainObject(value)) {
    fail(errorCode);
  }
  for (const key of Object.keys(value)) {
    if (!allowedFields.has(key)) {
      fail(errorCode);
    }
  }
}

function canonicalJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  if (isPlainObject(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function digest(value) {
  return `sha256:${createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
}

function parseJson(text, errorCode) {
  try {
    return JSON.parse(text);
  } catch {
    fail(errorCode);
  }
}

export function packagedAgentIds(packagingRegistry) {
  const ids = packagingRegistry?.modules?.["target-adapters"]?.targetAdapters;
  if (
    !Array.isArray(ids) ||
    ids.length === 0 ||
    ids.some((id) => typeof id !== "string" || !SAFE_CODE.test(id)) ||
    new Set(ids).size !== ids.length
  ) {
    fail("packaging_registry_invalid");
  }
  return [...ids];
}

function inventoryDigestValue(inventory) {
  return {
    schemaVersion: inventory.schemaVersion,
    contractVersion: inventory.contractVersion,
    evidenceContract: inventory.evidenceContract,
    drivers: [...inventory.drivers].sort((left, right) =>
      left.agentId.localeCompare(right.agentId),
    ),
  };
}

export function registryDigestFor(agentIds) {
  return digest([...agentIds].sort());
}

export function driverInventoryDigestFor(inventory) {
  return digest(inventoryDigestValue(inventory));
}

export function adapterEvidenceDigestFor(adapterEvidence) {
  if (!isPlainObject(adapterEvidence)) {
    fail("evidence_schema_invalid");
  }
  const { evidenceDigest: ignored, ...digestibleEvidence } = adapterEvidence;
  return digest(digestibleEvidence);
}

export function validateDriverInventory(inventory, agentIds) {
  assertNoSensitiveFields(inventory);
  assertOnlyFields(inventory, INVENTORY_TOP_LEVEL_FIELDS, "driver_inventory_invalid");
  if (
    inventory.schemaVersion !== INVENTORY_SCHEMA_VERSION ||
    inventory.contractVersion !== CONTRACT_VERSION ||
    !Array.isArray(inventory.drivers)
  ) {
    fail("driver_inventory_invalid");
  }

  assertOnlyFields(
    inventory.evidenceContract,
    INVENTORY_CONTRACT_FIELDS,
    "driver_inventory_invalid",
  );
  const contract = inventory.evidenceContract;
  if (
    contract.minimumConsecutivePasses !== MINIMUM_CONSECUTIVE_PASSES ||
    canonicalJson(contract.coreChecks) !== canonicalJson(CORE_CHECK_IDS) ||
    canonicalJson(contract.conditionalChecks) !== canonicalJson(CONDITIONAL_CHECK_IDS) ||
    canonicalJson(contract.requiredBooleans) !==
      canonicalJson([
        "officialNativeLane",
        "releaseUiPassed",
        "cleanupPassed",
        "privacyPassed",
      ]) ||
    canonicalJson(contract.requiredCounts) !== canonicalJson(["consecutivePasses"]) ||
    canonicalJson(contract.requiredDigests) !==
      canonicalJson([
        "runtimeVersionDigest",
        "capabilitySnapshotDigest",
        "registryDigest",
        "driverInventoryDigest",
        "evidenceDigest",
      ]) ||
    canonicalJson(contract.requiredBindings) !==
      canonicalJson([
        "agentId",
        "driverId",
        "runtimeProtocol",
        "harnessVersion",
        "runtimeVersionClass",
        "runtimeSourceClass",
      ])
  ) {
    fail("driver_inventory_invalid");
  }

  const inventoryIds = [];
  for (const driver of inventory.drivers) {
    assertOnlyFields(driver, INVENTORY_DRIVER_FIELDS, "driver_inventory_invalid");
    if (
      !SAFE_CODE.test(driver.agentId ?? "") ||
      !SAFE_CODE.test(driver.driverId ?? "") ||
      !SAFE_CODE.test(driver.runtimeProtocol ?? "") ||
      !SAFE_CODE.test(driver.officialNativeLaneKind ?? "") ||
      typeof driver.historyReadable !== "boolean" ||
      !DRIVER_MODES.has(driver.driverMode) ||
      !Array.isArray(driver.blockerCodes) ||
      driver.blockerCodes.some((code) => !INVENTORY_BLOCKING_CODES.has(code))
    ) {
      fail("driver_inventory_invalid");
    }
    if (driver.driverMode === "blocked" && driver.blockerCodes.length === 0) {
      fail("driver_inventory_invalid");
    }
    if (driver.driverMode !== "blocked" && driver.blockerCodes.length > 0) {
      fail("driver_inventory_invalid");
    }
    if (driver.capabilityMatrix !== undefined) {
      if (!isPlainObject(driver.capabilityMatrix)) {
        fail("driver_inventory_invalid");
      }
      assertOnlyFields(
        driver.capabilityMatrix,
        CAPABILITY_MATRIX_FIELDS,
        "driver_inventory_invalid",
      );
      if (
        !LANE_FAMILIES.has(driver.capabilityMatrix.laneFamily) ||
        typeof driver.capabilityMatrix.openNew !== "boolean" ||
        typeof driver.capabilityMatrix.exactResume !== "boolean" ||
        typeof driver.capabilityMatrix.streaming !== "boolean" ||
        typeof driver.capabilityMatrix.cancel !== "boolean" ||
        typeof driver.capabilityMatrix.structuredEvents !== "boolean" ||
        typeof driver.capabilityMatrix.approvals !== "boolean" ||
        typeof driver.capabilityMatrix.multimodal !== "boolean" ||
        typeof driver.capabilityMatrix.usageStatus !== "boolean" ||
        typeof driver.capabilityMatrix.officialLane !== "boolean"
      ) {
        fail("driver_inventory_invalid");
      }
    }
    inventoryIds.push(driver.agentId);
  }

  if (new Set(inventoryIds).size !== inventoryIds.length) {
    fail("driver_inventory_duplicate_agent");
  }
  const canonical = [...agentIds].sort();
  const inventoried = [...inventoryIds].sort();
  if (canonicalJson(canonical) !== canonicalJson(inventoried)) {
    fail("registry_inventory_mismatch");
  }
  return inventory;
}

function indexEvidence(evidence, agentIds) {
  if (evidence === undefined || evidence === null) {
    return { byAgent: new Map(), globalIssue: "evidence_missing" };
  }

  assertNoSensitiveFields(evidence);
  assertOnlyFields(evidence, EVIDENCE_TOP_LEVEL_FIELDS, "evidence_schema_invalid");
  if (
    evidence.schemaVersion !== EVIDENCE_SCHEMA_VERSION ||
    evidence.contractVersion !== CONTRACT_VERSION ||
    !Array.isArray(evidence.adapters)
  ) {
    return { byAgent: new Map(), globalIssue: "evidence_schema_mismatch" };
  }

  const canonicalAgents = new Set(agentIds);
  const byAgent = new Map();
  for (const adapter of evidence.adapters) {
    assertOnlyFields(adapter, ADAPTER_EVIDENCE_FIELDS, "evidence_schema_invalid");
    if (!SAFE_CODE.test(adapter.agentId ?? "")) {
      fail("evidence_schema_invalid");
    }
    if (!canonicalAgents.has(adapter.agentId)) {
      fail("evidence_registry_mismatch");
    }
    if (byAgent.has(adapter.agentId)) {
      fail("evidence_duplicate_agent");
    }
    if (isPlainObject(adapter.coreChecks)) {
      for (const key of Object.keys(adapter.coreChecks)) {
        if (!CORE_CHECK_IDS.includes(key)) {
          fail("evidence_schema_invalid");
        }
      }
    }
    if (isPlainObject(adapter.conditionalChecks)) {
      for (const [key, conditional] of Object.entries(adapter.conditionalChecks)) {
        if (!CONDITIONAL_CHECK_IDS.includes(key)) {
          fail("evidence_schema_invalid");
        }
        assertOnlyFields(
          conditional,
          CONDITIONAL_EVIDENCE_FIELDS,
          "evidence_schema_invalid",
        );
      }
    }
    byAgent.set(adapter.agentId, adapter);
  }
  return { byAgent, globalIssue: null };
}

function evidenceBindingIsCurrent(evidence, driver, registryDigest, inventoryDigest) {
  return (
    SAFE_CODE.test(evidence.driverId ?? "") &&
    evidence.driverId === driver.driverId &&
    SAFE_CODE.test(evidence.runtimeProtocol ?? "") &&
    evidence.runtimeProtocol === driver.runtimeProtocol &&
    SAFE_CODE.test(evidence.harnessVersion ?? "") &&
    SAFE_CODE.test(evidence.runtimeVersionClass ?? "") &&
    SHA256_DIGEST.test(evidence.runtimeVersionDigest ?? "") &&
    SHA256_DIGEST.test(evidence.capabilitySnapshotDigest ?? "") &&
    SAFE_CODE.test(evidence.runtimeSourceClass ?? "") &&
    SHA256_DIGEST.test(evidence.registryDigest ?? "") &&
    evidence.registryDigest === registryDigest &&
    SHA256_DIGEST.test(evidence.driverInventoryDigest ?? "") &&
    evidence.driverInventoryDigest === inventoryDigest &&
    SHA256_DIGEST.test(evidence.evidenceDigest ?? "") &&
    evidence.evidenceDigest === adapterEvidenceDigestFor(evidence)
  );
}

function coreCounts(evidence) {
  const checks = isPlainObject(evidence?.coreChecks) ? evidence.coreChecks : {};
  return {
    passed: CORE_CHECK_IDS.filter((id) => checks[id] === "pass").length,
    failed: CORE_CHECK_IDS.filter((id) => checks[id] === "fail").length,
    complete: CORE_CHECK_IDS.every((id) => CORE_RESULTS.has(checks[id])),
    allPassed: CORE_CHECK_IDS.every((id) => checks[id] === "pass"),
  };
}

function conditionalCounts(evidence) {
  const checks = isPlainObject(evidence?.conditionalChecks)
    ? evidence.conditionalChecks
    : {};
  let nativeSupported = 0;
  let passed = 0;
  let gaps = 0;
  let failed = 0;
  let unverified = 0;
  let complete = true;

  for (const id of CONDITIONAL_CHECK_IDS) {
    const check = checks[id];
    if (
      !isPlainObject(check) ||
      !NATIVE_SUPPORT_RESULTS.has(check.nativeSupport) ||
      !CONDITIONAL_RESULTS.has(check.result)
    ) {
      complete = false;
      unverified += 1;
      continue;
    }
    if (check.nativeSupport === "supported") {
      nativeSupported += 1;
      if (check.result === "pass") passed += 1;
      else if (check.result === "fail") failed += 1;
      else if (check.result === "gap") gaps += 1;
      else unverified += 1;
      if (check.result === "unsupported-by-native") complete = false;
    } else if (check.nativeSupport === "unsupported") {
      if (check.result !== "unsupported-by-native") complete = false;
    } else {
      if (check.result !== "unverified") complete = false;
      unverified += 1;
    }
  }
  return { nativeSupported, passed, gaps, failed, unverified, complete };
}

function cleanPassCount(value) {
  return Number.isInteger(value) && value >= 0 && value <= 1_000 ? value : 0;
}

function adapterResult({
  driver,
  evidence,
  globalIssue,
  registryDigest,
  inventoryDigest,
}) {
  const core = coreCounts(evidence);
  const conditional = conditionalCounts(evidence);
  const consecutivePasses = cleanPassCount(evidence?.consecutivePasses);
  let status = "unverified";
  let summaryCodes = [globalIssue ?? "evidence_missing"];
  let evidenceBinding = null;

  if (driver.driverMode === "history-only") {
    status = "history-only";
    summaryCodes = ["history_only_driver"];
  } else if (driver.driverMode === "blocked") {
    status = "blocked";
    summaryCodes = [...driver.blockerCodes];
  } else if (evidence) {
    const bindingCurrent = evidenceBindingIsCurrent(
      evidence,
      driver,
      registryDigest,
      inventoryDigest,
    );
    if (bindingCurrent) {
      evidenceBinding = {
        agentId: evidence.agentId,
        driverId: evidence.driverId,
        runtimeProtocol: evidence.runtimeProtocol,
        harnessVersion: evidence.harnessVersion,
        runtimeVersionClass: evidence.runtimeVersionClass,
        runtimeVersionDigest: evidence.runtimeVersionDigest,
        capabilitySnapshotDigest: evidence.capabilitySnapshotDigest,
        runtimeSourceClass: evidence.runtimeSourceClass,
        registryDigest: evidence.registryDigest,
        driverInventoryDigest: evidence.driverInventoryDigest,
        evidenceDigest: evidence.evidenceDigest,
      };
    }
    if (!bindingCurrent) {
      summaryCodes = ["evidence_stale_or_incomplete"];
    } else if (
      evidence.blockingCode !== undefined &&
      !EVIDENCE_BLOCKING_CODES.has(evidence.blockingCode)
    ) {
      summaryCodes = ["evidence_incomplete"];
    } else if (typeof evidence.blockingCode === "string") {
      status = "blocked";
      summaryCodes = [evidence.blockingCode];
    } else if (evidence.officialNativeLane === false) {
      status = "blocked";
      summaryCodes = ["official_native_lane_missing"];
    } else if (
      core.failed > 0 ||
      conditional.failed > 0 ||
      evidence.releaseUiPassed === false ||
      evidence.cleanupPassed === false ||
      evidence.privacyPassed === false
    ) {
      status = "failed";
      summaryCodes = [];
      if (core.failed > 0) summaryCodes.push("core_check_failed");
      if (conditional.failed > 0) summaryCodes.push("conditional_check_failed");
      if (evidence.releaseUiPassed === false) summaryCodes.push("release_ui_failed");
      if (evidence.cleanupPassed === false) summaryCodes.push("cleanup_failed");
      if (evidence.privacyPassed === false) summaryCodes.push("privacy_failed");
    } else {
      const requiredEvidenceComplete =
        evidence.officialNativeLane === true &&
        typeof evidence.releaseUiPassed === "boolean" &&
        typeof evidence.cleanupPassed === "boolean" &&
        typeof evidence.privacyPassed === "boolean" &&
        Number.isInteger(evidence.consecutivePasses) &&
        evidence.consecutivePasses >= MINIMUM_CONSECUTIVE_PASSES &&
        core.complete &&
        core.allPassed &&
        conditional.complete;

      if (!requiredEvidenceComplete || conditional.unverified > 0) {
        summaryCodes = ["evidence_incomplete"];
      } else if (conditional.gaps > 0) {
        status = "partial";
        summaryCodes = ["native_capability_gap"];
      } else if (
        conditional.nativeSupported === conditional.passed &&
        evidence.releaseUiPassed === true &&
        evidence.cleanupPassed === true &&
        evidence.privacyPassed === true
      ) {
        status = "ready";
        summaryCodes = ["all_required_evidence_passed"];
      }
    }
  }

  return {
    agentId: driver.agentId,
    status,
    sendEnabled: status === "ready",
    officialNativeLaneProven: evidence?.officialNativeLane === true,
    releaseUiPassed: evidence?.releaseUiPassed === true,
    cleanupPassed: evidence?.cleanupPassed === true,
    privacyPassed: evidence?.privacyPassed === true,
    consecutivePasses,
    coreChecks: {
      required: CORE_CHECK_IDS.length,
      passed: core.passed,
      failed: core.failed,
    },
    conditionalChecks: {
      total: CONDITIONAL_CHECK_IDS.length,
      nativeSupported: conditional.nativeSupported,
      passed: conditional.passed,
      gaps: conditional.gaps,
      failed: conditional.failed,
    },
    evidenceBinding,
    summaryCodes,
  };
}

export function reduceConversationParity({ packagingRegistry, inventory, evidence }) {
  const agentIds = packagedAgentIds(packagingRegistry);
  validateDriverInventory(inventory, agentIds);
  const registryDigest = registryDigestFor(agentIds);
  const inventoryDigest = driverInventoryDigestFor(inventory);
  const evidenceIndex = indexEvidence(evidence, agentIds);
  const drivers = new Map(inventory.drivers.map((driver) => [driver.agentId, driver]));

  const adapters = agentIds.map((agentId) =>
    adapterResult({
      driver: drivers.get(agentId),
      evidence: evidenceIndex.byAgent.get(agentId),
      globalIssue: evidenceIndex.globalIssue,
      registryDigest,
      inventoryDigest,
    }),
  );

  const statusCount = (status) => adapters.filter((item) => item.status === status).length;
  return {
    schemaVersion: READINESS_SCHEMA_VERSION,
    contractVersion: CONTRACT_VERSION,
    minimumConsecutivePasses: MINIMUM_CONSECUTIVE_PASSES,
    summary: {
      total: adapters.length,
      ready: statusCount("ready"),
      partial: statusCount("partial"),
      failed: statusCount("failed"),
      blocked: statusCount("blocked"),
      unverified: statusCount("unverified"),
      historyOnly: statusCount("history-only"),
      sendEnabled: adapters.filter((item) => item.sendEnabled).length,
    },
    adapters,
  };
}

export function loadCanonicalInputs() {
  return {
    packagingRegistry: parseJson(
      readFileSync(PACKAGING_REGISTRY_FILE, "utf8"),
      "packaging_registry_invalid",
    ),
    inventory: parseJson(
      readFileSync(DRIVER_INVENTORY_FILE, "utf8"),
      "driver_inventory_invalid",
    ),
    evidence: parseJson(
      readFileSync(CANONICAL_EVIDENCE_FILE, "utf8"),
      "evidence_json_invalid",
    ),
  };
}

function parseArguments(argv) {
  const options = { evidenceFile: null, write: false, check: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--evidence") {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) fail("cli_arguments_invalid");
      options.evidenceFile = value;
      index += 1;
    } else if (argument === "--write") {
      options.write = true;
    } else if (argument === "--check") {
      options.check = true;
    } else {
      fail("cli_arguments_invalid");
    }
  }
  if (options.write && options.check) fail("cli_arguments_invalid");
  return options;
}

function receipt(operation, result) {
  return {
    schemaVersion: "v0.0.1:client-agent-conversation-readiness-receipt-1",
    ok: true,
    operation,
    summary: result.summary,
  };
}

export function assertReadinessMatchesReduction(current, reduced) {
  if (canonicalJson(current) !== canonicalJson(reduced)) {
    fail("readiness_resource_mismatch");
  }
}

export function runCli(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  const canonical = loadCanonicalInputs();
  const evidence = options.evidenceFile
    ? parseJson(readFileSync(resolve(options.evidenceFile), "utf8"), "evidence_json_invalid")
    : canonical.evidence;
  const result = reduceConversationParity({
    packagingRegistry: canonical.packagingRegistry,
    inventory: canonical.inventory,
    evidence,
  });

  if (options.write) {
    writeFileSync(READINESS_FILE, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
    return receipt("write", result);
  }
  if (options.check) {
    const current = parseJson(
      readFileSync(READINESS_FILE, "utf8"),
      "readiness_resource_invalid",
    );
    assertReadinessMatchesReduction(current, result);
    return receipt("check", result);
  }
  return result;
}

function sanitizedFailure(error) {
  return {
    schemaVersion: "v0.0.1:client-agent-conversation-readiness-receipt-1",
    ok: false,
    errorCode: error instanceof ReducerError ? error.code : "reducer_error",
  };
}

const invokedDirectly =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;

if (invokedDirectly) {
  try {
    process.stdout.write(`${JSON.stringify(runCli())}\n`);
  } catch (error) {
    process.stderr.write(`${JSON.stringify(sanitizedFailure(error))}\n`);
    process.exitCode = 1;
  }
}
