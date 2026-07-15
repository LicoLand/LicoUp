#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  CONDITIONAL_CHECK_IDS,
  CONTRACT_VERSION,
  CORE_CHECK_IDS,
  EVIDENCE_SCHEMA_VERSION,
  ReducerError,
  adapterManifestDigestFor,
  adapterEvidenceDigestFor,
  assertReadinessMatchesReduction,
  capabilityMatrixDigestFor,
  driverInventoryDigestFor,
  packagedAgentIds,
  reduceConversationParity,
  registryDigestFor,
  runCli,
} from "../../../tools/scripts/client-agent-conversation-parity-reducer.mjs";

const TEST_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = resolve(TEST_DIRECTORY, "../../..");
const packagingRegistry = JSON.parse(
  readFileSync(resolve(REPOSITORY_ROOT, "apps/desktop/packaging.modules.json"), "utf8"),
);
const inventory = JSON.parse(
  readFileSync(
    resolve(
      REPOSITORY_ROOT,
      "crates/lico-client-native/resources/agent-conversation-drivers.json",
    ),
    "utf8",
  ),
);
const readinessResource = JSON.parse(
  readFileSync(
    resolve(
      REPOSITORY_ROOT,
      "crates/lico-client-native/resources/agent-conversation-readiness.json",
    ),
    "utf8",
  ),
);
const canonicalEvidence = JSON.parse(
  readFileSync(
    resolve(
      REPOSITORY_ROOT,
      "crates/lico-client-native/resources/agent-conversation-evidence.json",
    ),
    "utf8",
  ),
);

const agentIds = packagedAgentIds(packagingRegistry);
const registryDigest = registryDigestFor(agentIds);
const inventoryDigest = driverInventoryDigestFor(inventory);

function fullEvidence(agentId = "codex") {
  const driver = inventory.drivers.find((item) => item.agentId === agentId);
  const conditionalCapability = {
    "C-01": "streaming",
    "C-02": "structuredEvents",
    "C-03": "approvals",
    "C-04": "multimodal",
    "C-05": "interruptSteer",
    "C-06": "usageStatus",
  };
  const evidence = {
    schemaVersion: EVIDENCE_SCHEMA_VERSION,
    contractVersion: CONTRACT_VERSION,
    adapters: [
      {
        agentId,
        driverId: driver.driverId,
        runtimeProtocol: driver.runtimeProtocol,
        harnessVersion: "acceptance-v1",
        runtimeVersionClass: "verified-release",
        runtimeVersionDigest: `sha256:${"b".repeat(64)}`,
        capabilitySnapshotDigest: capabilityMatrixDigestFor(driver),
        adapterManifestDigest: adapterManifestDigestFor(agentId),
        releaseArtifactDigest: `sha256:${"d".repeat(64)}`,
        releaseSidecarDigest: `sha256:${"e".repeat(64)}`,
        productContinuityBindingDigest: `sha256:${"f".repeat(64)}`,
        runtimeSourceClass: "discovered-binary",
        registryDigest,
        driverInventoryDigest: inventoryDigest,
        evidenceDigest: "",
        officialNativeLane: true,
        consecutivePasses: 3,
        releaseUiPassed: true,
        cleanupPassed: true,
        privacyPassed: true,
        coreChecks: Object.fromEntries(CORE_CHECK_IDS.map((id) => [id, "pass"])),
        conditionalChecks: Object.fromEntries(
          CONDITIONAL_CHECK_IDS.map((id) => [
            id,
            driver.capabilityMatrix[conditionalCapability[id]] === true
              ? { nativeSupport: "supported", result: "pass" }
              : { nativeSupport: "unsupported", result: "unsupported-by-native" },
          ]),
        ),
      },
    ],
  };
  evidence.adapters[0].evidenceDigest = adapterEvidenceDigestFor(evidence.adapters[0]);
  return evidence;
}

function refreshDigest(evidence) {
  evidence.adapters[0].evidenceDigest = adapterEvidenceDigestFor(evidence.adapters[0]);
  return evidence;
}

function resultFor(result, agentId = "codex") {
  return result.adapters.find((item) => item.agentId === agentId);
}

const tests = [];
function test(name, body) {
  tests.push({ name, body });
}

test("complete evidence is the only route to ready", () => {
  const result = reduceConversationParity({
    packagingRegistry,
    inventory,
    evidence: fullEvidence(),
  });
  const codex = resultFor(result);
  assert.equal(codex.status, "ready");
  assert.equal(codex.sendEnabled, true);
  assert.equal(codex.coreChecks.passed, 10);
  assert.equal(codex.conditionalChecks.nativeSupported, 2);
  assert.equal(codex.conditionalChecks.passed, 2);
  assert.equal(codex.evidenceBinding.agentId, "codex");
  assert.equal(codex.evidenceBinding.driverId, "codex-app-server");
  assert.equal(result.summary.ready, 1);
  assert.equal(result.summary.sendEnabled, 1);
});

test("capability evidence cannot overclaim inventory support or reuse a stale snapshot", () => {
  const overclaimed = fullEvidence();
  overclaimed.adapters[0].conditionalChecks["C-03"] = {
    nativeSupport: "supported",
    result: "pass",
  };
  refreshDigest(overclaimed);
  const overclaimResult = reduceConversationParity({
    packagingRegistry,
    inventory,
    evidence: overclaimed,
  });
  assert.equal(resultFor(overclaimResult).status, "unverified");
  assert.deepEqual(resultFor(overclaimResult).summaryCodes, [
    "evidence_stale_or_incomplete",
  ]);

  const stale = fullEvidence();
  stale.adapters[0].capabilitySnapshotDigest = `sha256:${"c".repeat(64)}`;
  refreshDigest(stale);
  const staleResult = reduceConversationParity({
    packagingRegistry,
    inventory,
    evidence: stale,
  });
  assert.equal(resultFor(staleResult).status, "unverified");

  const staleManifest = fullEvidence();
  staleManifest.adapters[0].adapterManifestDigest = `sha256:${"a".repeat(64)}`;
  refreshDigest(staleManifest);
  const staleManifestResult = reduceConversationParity({
    packagingRegistry,
    inventory,
    evidence: staleManifest,
  });
  assert.equal(resultFor(staleManifestResult).status, "unverified");
});

test("missing evidence and missing checks never pass", () => {
  const absent = reduceConversationParity({ packagingRegistry, inventory });
  assert.equal(resultFor(absent).status, "unverified");
  assert.equal(resultFor(absent).sendEnabled, false);

  const incompleteEvidence = fullEvidence();
  delete incompleteEvidence.adapters[0].coreChecks["P-10"];
  refreshDigest(incompleteEvidence);
  const incomplete = reduceConversationParity({
    packagingRegistry,
    inventory,
    evidence: incompleteEvidence,
  });
  assert.equal(resultFor(incomplete).status, "unverified");
  assert.equal(resultFor(incomplete).sendEnabled, false);

  const tooFewRuns = fullEvidence();
  tooFewRuns.adapters[0].consecutivePasses = 2;
  refreshDigest(tooFewRuns);
  const shortRun = reduceConversationParity({
    packagingRegistry,
    inventory,
    evidence: tooFewRuns,
  });
  assert.equal(resultFor(shortRun).status, "unverified");
});

test("an executed mandatory failure reduces to failed", () => {
  const evidence = fullEvidence();
  evidence.adapters[0].coreChecks["P-07"] = "fail";
  refreshDigest(evidence);
  const result = reduceConversationParity({ packagingRegistry, inventory, evidence });
  const codex = resultFor(result);
  assert.equal(codex.status, "failed");
  assert.equal(codex.sendEnabled, false);
  assert.deepEqual(codex.summaryCodes, ["core_check_failed"]);
});

test("a known native-supported capability gap reduces to partial", () => {
  const evidence = fullEvidence();
  evidence.adapters[0].conditionalChecks["C-02"] = {
    nativeSupport: "supported",
    result: "gap",
  };
  refreshDigest(evidence);
  const result = reduceConversationParity({ packagingRegistry, inventory, evidence });
  const codex = resultFor(result);
  assert.equal(codex.status, "partial");
  assert.equal(codex.sendEnabled, false);
  assert.equal(codex.conditionalChecks.gaps, 1);
});

test("inventory and official-lane blockers reduce to blocked", () => {
  const baseline = reduceConversationParity({ packagingRegistry, inventory });
  const antigravity = resultFor(baseline, "antigravity");
  assert.equal(antigravity.status, "blocked");
  assert.equal(antigravity.sendEnabled, false);

  const evidence = fullEvidence();
  evidence.adapters[0].officialNativeLane = false;
  refreshDigest(evidence);
  const missingLane = reduceConversationParity({ packagingRegistry, inventory, evidence });
  assert.equal(resultFor(missingLane).status, "blocked");
});

test("no-persistence cleanup can promote while declared unsafe cleanup stays blocked", () => {
  const claude = reduceConversationParity({
    packagingRegistry,
    inventory,
    evidence: fullEvidence("claude-code"),
  });
  assert.equal(resultFor(claude, "claude-code").status, "ready");
  assert.equal(resultFor(claude, "claude-code").sendEnabled, true);
  assert.deepEqual(resultFor(claude, "claude-code").summaryCodes, [
    "all_required_evidence_passed",
  ]);

  const cursorBlocked = reduceConversationParity({
    packagingRegistry,
    inventory,
    evidence: fullEvidence("cursor"),
  });
  assert.equal(resultFor(cursorBlocked, "cursor").status, "blocked");
  assert.equal(resultFor(cursorBlocked, "cursor").sendEnabled, false);
  assert.deepEqual(resultFor(cursorBlocked, "cursor").summaryCodes, [
    "safe_cleanup_unavailable",
  ]);

  const cleanupBlockedInventory = structuredClone(inventory);
  const openclaw = cleanupBlockedInventory.drivers.find(
    (item) => item.agentId === "openclaw",
  );
  openclaw.driverMode = "blocked";
  openclaw.blockerCodes = ["safe_cleanup_unavailable"];
  const cleanupBlocked = reduceConversationParity({
    packagingRegistry,
    inventory: cleanupBlockedInventory,
    evidence: fullEvidence("openclaw"),
  });
  assert.equal(resultFor(cleanupBlocked, "openclaw").status, "blocked");
  assert.equal(resultFor(cleanupBlocked, "openclaw").sendEnabled, false);
});

test("inventory discloses current native transports and fail-closed capability gaps", () => {
  const byId = new Map(inventory.drivers.map((driver) => [driver.agentId, driver]));
  assert.equal(byId.get("cursor")?.driverId, "cursor-acp");
  assert.equal(byId.get("cursor")?.runtimeProtocol, "cursor-acp-v1-stdio-jsonrpc");
  assert.equal(byId.get("cursor")?.driverMode, "blocked");
  assert.deepEqual(byId.get("cursor")?.blockerCodes, ["safe_cleanup_unavailable"]);

  assert.equal(byId.get("claude-code")?.driverMode, "conversation");
  assert.equal(byId.get("claude-code")?.capabilityMatrix?.exactResume, true);
  assert.equal(byId.get("claude-code")?.capabilityMatrix?.cancel, true);
  assert.equal(
    byId.get("claude-code")?.capabilityMatrix?.processLocalContinuation,
    true,
  );
  assert.deepEqual(byId.get("claude-code")?.blockerCodes, []);

  assert.equal(byId.get("opencode")?.driverId, "opencode-serve");
  assert.equal(byId.get("opencode")?.capabilityMatrix?.laneFamily, "serve-http");
  assert.equal(byId.get("kilo-code")?.driverId, "kilo-code-serve");
  assert.equal(byId.get("kilo-code")?.capabilityMatrix?.laneFamily, "serve-http");

  assert.equal(byId.get("hermes")?.driverMode, "conversation");
  assert.equal(byId.get("hermes")?.capabilityMatrix?.exactResume, true);
  assert.equal(byId.get("hermes")?.capabilityMatrix?.cancel, true);
  assert.deepEqual(byId.get("hermes")?.blockerCodes, []);
  assert.equal(byId.get("kimi-code")?.driverMode, "conversation");
  assert.deepEqual(byId.get("kimi-code")?.blockerCodes, []);
  assert.equal(byId.get("pi")?.driverMode, "conversation");
  assert.deepEqual(byId.get("pi")?.blockerCodes, []);

  for (const driver of inventory.drivers) {
    if (["hermes", "claude-code", "cursor"].includes(driver.agentId)) continue;
    assert.equal(
      driver.capabilityMatrix?.cancel,
      false,
      `${driver.agentId} must not advertise cancel before the product owns an active turn handle`,
    );
  }
});

test("history-only is read-only and never enables send", () => {
  const historyInventory = structuredClone(inventory);
  const codex = historyInventory.drivers.find((item) => item.agentId === "codex");
  codex.driverMode = "history-only";
  const result = reduceConversationParity({
    packagingRegistry,
    inventory: historyInventory,
  });
  assert.equal(resultFor(result).status, "history-only");
  assert.equal(resultFor(result).sendEnabled, false);
});

test("sensitive fields are rejected recursively without redisclosure", () => {
  const evidence = fullEvidence();
  evidence.adapters[0].diagnostic = {
    nested: {
      prompt: "private-canary",
    },
  };
  assert.throws(
    () => reduceConversationParity({ packagingRegistry, inventory, evidence }),
    (error) =>
      error instanceof ReducerError &&
      error.code === "sensitive_evidence_field_rejected" &&
      !error.message.includes("private-canary"),
  );
});

test("driver inventory drift from packaging is rejected", () => {
  const driftedInventory = structuredClone(inventory);
  driftedInventory.drivers.pop();
  assert.throws(
    () =>
      reduceConversationParity({
        packagingRegistry,
        inventory: driftedInventory,
      }),
    (error) => error instanceof ReducerError && error.code === "registry_inventory_mismatch",
  );
});

test("checked-in readiness is the honest canonical-evidence reduction", () => {
  const result = reduceConversationParity({
    packagingRegistry,
    inventory,
    evidence: canonicalEvidence,
  });
  assert.deepEqual(result, readinessResource);
  assert.deepEqual(result.summary, {
    total: 11,
    ready: 0,
    partial: 0,
    failed: 0,
    blocked: 2,
    unverified: 9,
    historyOnly: 0,
    sendEnabled: 0,
  });
  const receipt = runCli(["--check"]);
  assert.equal(receipt.ok, true);
  assert.equal(receipt.operation, "check");
});

test("a fully forged ready resource is rejected by the release check", () => {
  const forged = structuredClone(readinessResource);
  const codex = resultFor(forged);
  codex.status = "ready";
  codex.sendEnabled = true;
  codex.officialNativeLaneProven = true;
  codex.releaseUiPassed = true;
  codex.cleanupPassed = true;
  codex.privacyPassed = true;
  codex.consecutivePasses = 3;
  codex.coreChecks.passed = codex.coreChecks.required;
  codex.conditionalChecks.nativeSupported = 0;
  codex.conditionalChecks.passed = 0;
  codex.evidenceBinding = {
    driverId: "codex-app-server",
    runtimeProtocol: "codex-app-server-stdio-jsonrpc",
    harnessVersion: "forged-v1",
    runtimeVersionClass: "forged-release",
    runtimeVersionDigest: `sha256:${"a".repeat(64)}`,
    capabilitySnapshotDigest: `sha256:${"b".repeat(64)}`,
    runtimeSourceClass: "forged-binary",
    registryDigest: `sha256:${"c".repeat(64)}`,
    driverInventoryDigest: `sha256:${"d".repeat(64)}`,
    evidenceDigest: `sha256:${"e".repeat(64)}`,
  };
  codex.summaryCodes = ["all_required_evidence_passed"];
  forged.summary.ready = 1;
  forged.summary.unverified -= 1;
  forged.summary.sendEnabled = 1;

  assert.throws(
    () => assertReadinessMatchesReduction(forged, readinessResource),
    (error) =>
      error instanceof ReducerError && error.code === "readiness_resource_mismatch",
  );
});

let passed = 0;
let failed = 0;
for (const { name, body } of tests) {
  try {
    await body();
    passed += 1;
    process.stdout.write(`PASS ${name}\n`);
  } catch (error) {
    failed += 1;
    process.stderr.write(`FAIL ${name}\n`);
  }
}
process.stdout.write(`${failed === 0 ? "PASS" : "FAIL"} self-test summary: ${passed}/${tests.length}\n`);
if (failed > 0) process.exitCode = 1;
