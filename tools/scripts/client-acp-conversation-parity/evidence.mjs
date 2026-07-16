import { createHash, randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { CONDITIONAL_CHECK_IDS, CONTRACT_VERSION, CORE_CHECK_IDS, EVIDENCE_SCHEMA_VERSION, adapterManifestDigestFor, adapterEvidenceDigestFor, driverInventoryDigestFor, packagedAgentIds, registryDigestFor } from "../client-agent-conversation-parity-reducer.mjs";
import { productContinuityBindingDigest } from "../lib/agent-conversation-release-binding.mjs";
import { dispatchLaneHarnessVersion, driversInventoryPath, evidenceManifestPath, packagingRegistryPath, strictRoundCount } from "./constants.mjs";
import { digest, requireFact } from "./errors.mjs";

export function assertEvidenceHygiene(evidence) {
  const text = JSON.stringify(evidence);
  const forbidden = [
    ["", "Users", ""].join("/"),
    ["", "home", ""].join("/"),
    "BEGIN PRIVATE",
    "password",
    "Authorization:",
  ];
  for (const needle of forbidden) {
    requireFact(!text.includes(needle), "evidence_hygiene_failed");
  }
}

export function createSanitizedSelfTestEvidenceReceipt(probeStamp) {
  // Fixture/self-test evidence is diagnostic only. It must never mutate the
  // checked-in live-evidence authority or make the readiness reducer stale.
  let existingAdapters = [];
  try {
    const existing = JSON.parse(readFileSync(evidenceManifestPath, "utf8"));
    if (Array.isArray(existing?.adapters)) {
      existingAdapters = existing.adapters;
    }
  } catch {
    existingAdapters = [];
  }
  const evidence = {
    schemaVersion: "v0.0.1:client-agent-conversation-parity-evidence-1",
    contractVersion: "CL-06",
    harnessVersion: dispatchLaneHarnessVersion,
    toolVersionClass: probeStamp.toolVersionClass || dispatchLaneHarnessVersion,
    generatedAt: probeStamp.generatedAt || new Date().toISOString(),
    adapters: existingAdapters,
  };
  assertEvidenceHygiene(evidence);
  assertEvidenceHygiene(probeStamp);
  return {
    persisted: false,
    harnessVersion: evidence.harnessVersion,
    generatedAt: evidence.generatedAt,
    toolVersionClass: evidence.toolVersionClass,
    laneFamiliesCovered: probeStamp.laneFamiliesCovered,
    coreProbesCovered: probeStamp.coreProbesCovered,
    adapterCount: existingAdapters.length,
  };
}

export function binaryDigest(binaryPath) {
  if (!binaryPath || !existsSync(binaryPath)) {
    return `sha256:${"0".repeat(64)}`;
  }
  const bytes = readFileSync(binaryPath);
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

export function conditionalResultForSupported(proven) {
  if (proven === true) return "pass";
  if (proven === false) return "fail";
  return "unverified";
}

export function conditionalChecksFromMatrix(matrix, probes = {}) {
  const supportedStreaming = matrix?.streaming === true;
  const supportedApprovals = matrix?.approvals === true;
  const supportedMultimodal = matrix?.multimodal === true;
  const supportedUsage = matrix?.usageStatus === true;
  const supportedStructured = matrix?.structuredEvents === true;
  // Supported conditionals stay unverified until this harness records a direct
  // release-UI stream probe — never inherit external CLI-only streamingSeen.
  return {
    "C-01": supportedStreaming
      ? {
        nativeSupport: "supported",
        result: conditionalResultForSupported(probes.streaming),
      }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-02": supportedStructured
      ? {
        nativeSupport: "supported",
        result: conditionalResultForSupported(probes.structured),
      }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-03": supportedApprovals
      ? { nativeSupport: "supported", result: "unverified" }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-04": supportedMultimodal
      ? { nativeSupport: "supported", result: "unverified" }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-05": { nativeSupport: "unsupported", result: "unsupported-by-native" },
    "C-06": supportedUsage
      ? { nativeSupport: "supported", result: "unverified" }
      : { nativeSupport: "unsupported", result: "unsupported-by-native" },
  };
}

export function coreChecksFromAggregate(aggregate) {
  const passOrFail = (ready) => (ready ? "pass" : "fail");
  return {
    "P-01": passOrFail(aggregate.officialNativeLane === true),
    "P-02": passOrFail(aggregate.realSessionIds === true),
    "P-03": passOrFail(aggregate.nativeToArc === true && aggregate.arcToNative === true),
    "P-04": passOrFail(aggregate.finalCanaries === true),
    "P-05": passOrFail(aggregate.settingsParity === true && aggregate.cwdParity === true),
    "P-06": passOrFail(aggregate.historyReadback === true),
    "P-07": passOrFail(
      aggregate.errorFailClosed === true && aggregate.permissionFailClosed === true,
    ),
    "P-08": passOrFail(aggregate.privacyPassed === true),
    "P-09": passOrFail(aggregate.cleanupPassed === true),
    "P-10": passOrFail(aggregate.releaseUiPassed === true),
  };
}

export function writeReleaseUiAdapterEvidence(aggregate, context) {
  // Core-only CLI receipts (exactContinue/streamingSeen) never write here.
  // Only a full release-UI paired aggregate may upsert an adapter evidence row.
  if (aggregate?.status !== "release-ui-passed" || aggregate?.releaseUiPassed !== true) {
    return { written: false, reason: "release_ui_not_passed" };
  }
  if (aggregate.consecutivePasses < strictRoundCount) {
    return { written: false, reason: "consecutive_passes_incomplete" };
  }
  const packagingRegistry = JSON.parse(readFileSync(packagingRegistryPath, "utf8"));
  const inventory = JSON.parse(readFileSync(driversInventoryPath, "utf8"));
  const driver = inventory.drivers.find((row) => row.agentId === aggregate.agent);
  requireFact(Boolean(driver), "driver_inventory_missing_agent");
  const agentIds = packagedAgentIds(packagingRegistry);
  const registryDigest = registryDigestFor(agentIds);
  const inventoryDigest = driverInventoryDigestFor(inventory);
  const capabilitySnapshotDigest = `sha256:${digest(driver.capabilityMatrix)}`;
  const runtimeVersionDigest = binaryDigest(context.binary);
  const sidecarDigest = binaryDigest(context.sidecar);
  const conditionalRaw = conditionalChecksFromMatrix(driver.capabilityMatrix, {
    streaming: aggregate.streamingProven === true
      ? true
      : (aggregate.streamingProven === false ? false : undefined),
    structured: aggregate.structuredProven === true
      ? true
      : (aggregate.structuredProven === false ? false : undefined),
  });
  const conditionalChecks = Object.fromEntries(
    CONDITIONAL_CHECK_IDS.map((id) => [id, conditionalRaw[id]]),
  );
  const adapter = {
    agentId: aggregate.agent,
    driverId: driver.driverId,
    runtimeProtocol: driver.runtimeProtocol,
    harnessVersion: dispatchLaneHarnessVersion,
    runtimeVersionClass: "verified-release",
    runtimeVersionDigest,
    capabilitySnapshotDigest,
    adapterManifestDigest: adapterManifestDigestFor(aggregate.agent),
    releaseArtifactDigest: aggregate.productArtifactDigest,
    releaseSidecarDigest: sidecarDigest,
    productContinuityBindingDigest: aggregate.productContinuityBindingDigest,
    runtimeSourceClass: "discovered-binary",
    registryDigest,
    driverInventoryDigest: inventoryDigest,
    evidenceDigest: "",
    officialNativeLane: aggregate.officialNativeLane === true,
    consecutivePasses: aggregate.consecutivePasses,
    releaseUiPassed: true,
    cleanupPassed: aggregate.cleanupPassed === true,
    privacyPassed: aggregate.privacyPassed === true,
    coreChecks: coreChecksFromAggregate(aggregate),
    conditionalChecks,
  };
  adapter.evidenceDigest = adapterEvidenceDigestFor(adapter);
  assertEvidenceHygiene(adapter);
  requireFact(
    CORE_CHECK_IDS.every((id) => Object.hasOwn(adapter.coreChecks, id)),
    "evidence_core_checks_incomplete",
  );
  requireFact(
    CONDITIONAL_CHECK_IDS.every((id) => Object.hasOwn(adapter.conditionalChecks, id)),
    "evidence_conditional_checks_incomplete",
  );

  let evidence;
  try {
    evidence = JSON.parse(readFileSync(evidenceManifestPath, "utf8"));
  } catch {
    evidence = {
      schemaVersion: EVIDENCE_SCHEMA_VERSION,
      contractVersion: CONTRACT_VERSION,
      harnessVersion: dispatchLaneHarnessVersion,
      toolVersionClass: dispatchLaneHarnessVersion,
      generatedAt: new Date().toISOString(),
      adapters: [],
    };
  }
  if (!Array.isArray(evidence.adapters)) evidence.adapters = [];
  evidence.schemaVersion = EVIDENCE_SCHEMA_VERSION;
  evidence.contractVersion = CONTRACT_VERSION;
  evidence.harnessVersion = dispatchLaneHarnessVersion;
  evidence.toolVersionClass = dispatchLaneHarnessVersion;
  evidence.generatedAt = new Date().toISOString();
  evidence.adapters = [
    ...evidence.adapters.filter((row) => row?.agentId !== aggregate.agent),
    adapter,
  ].sort((left, right) => String(left.agentId).localeCompare(String(right.agentId)));
  assertEvidenceHygiene(evidence);
  const temporaryEvidencePath = `${evidenceManifestPath}.tmp-${process.pid}-${randomUUID()}`;
  writeFileSync(temporaryEvidencePath, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporaryEvidencePath, evidenceManifestPath);
  return {
    written: true,
    agentId: aggregate.agent,
    consecutivePasses: aggregate.consecutivePasses,
    evidenceDigest: adapter.evidenceDigest,
  };
}
