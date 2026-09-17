import path from "node:path";
import { withRootLock } from "./lock.mjs";
import { plan as computePlan } from "./plan.mjs";
import { getCodec } from "./codecs/index.mjs";
import {
  initJournal,
  markStepRunning,
  markStepCommitted,
  finishJournal,
} from "./journal.mjs";
import {
  writeJsonAtomicSync,
  ensureDirectorySync,
  readJsonSync,
} from "./fs-atomic.mjs";
import {
  DOMAIN_DEFINITIONS,
  DOMAIN_MARKER_SCHEMA,
  LEDGER_SCHEMA,
} from "./catalog.mjs";
import { listPreservations } from "./preservation.mjs";
import { getLedgerPath, getMarkerPath } from "./probe.mjs";

export function writeDomainMarker(dataRoot, domainId, authoritativeSchemaVersion) {
  const markerPath = getMarkerPath(dataRoot, domainId);
  ensureDirectorySync(path.dirname(markerPath));
  writeJsonAtomicSync(markerPath, {
    schemaVersion: DOMAIN_MARKER_SCHEMA,
    domainId,
    authoritativeSchemaVersion,
  });
}

export function writeLedger(dataRoot, targetVersion, frontierId, domainVersions) {
  const ledgerPath = getLedgerPath(dataRoot);
  ensureDirectorySync(path.dirname(ledgerPath));

  const existingLedger = readJsonSync(ledgerPath) || {};
  const domains = {};

  for (const def of DOMAIN_DEFINITIONS) {
    const domainId = def.domainId;
    const version = domainVersions[domainId] !== undefined
      ? domainVersions[domainId]
      : (def.targetSchemaVersion || 0);

    const completedStepIds = def.steps
      .filter((s) => s.toSchemaVersion <= version)
      .map((s) => s.stepId);

    domains[domainId] = {
      schemaVersion: version,
      completedStepIds,
    };
  }

  const ledger = {
    schemaVersion: LEDGER_SCHEMA,
    highestAdmittedProductVersion: targetVersion,
    frontierId,
    domains,
  };

  writeJsonAtomicSync(ledgerPath, ledger);
  return ledger;
}

export function convert(dataRoot, targetProfileOrVersion = "latest", options = {}) {
  const { dryRun = false } = options;

  return withRootLock(dataRoot, () => {
    const migrationPlan = computePlan(dataRoot, targetProfileOrVersion);

    if (dryRun) {
      return {
        status: "dry_run",
        targetVersion: migrationPlan.targetVersion,
        direction: migrationPlan.direction,
        isNoOp: migrationPlan.isNoOp,
        plannedSteps: migrationPlan.steps,
        skipped: migrationPlan.skipped,
        preservationsPlanned: migrationPlan.preservationsPlanned,
      };
    }

    if (migrationPlan.isNoOp) {
      // Reconcile ledger metadata to target version if needed
      const currentVersions = {};
      for (const def of DOMAIN_DEFINITIONS) {
        const codec = getCodec(def.domainId);
        try {
          currentVersions[def.domainId] = codec.probe(dataRoot).version;
        } catch {
          currentVersions[def.domainId] = 0;
        }
      }
      writeLedger(
        dataRoot,
        migrationPlan.targetVersion,
        migrationPlan.targetFrontierId,
        currentVersions
      );

      return {
        status: "success",
        targetVersion: migrationPlan.targetVersion,
        direction: "noop",
        convertedSteps: [],
        skippedDomains: migrationPlan.skipped.map((s) => s.domainId),
        preservations: listPreservations(dataRoot),
      };
    }

    // Initialize durable journal for crash resilience
    initJournal(dataRoot, migrationPlan);

    const executedSteps = [];
    const domainVersions = {};

    // Populate baseline domain versions from probe
    for (const def of DOMAIN_DEFINITIONS) {
      const codec = getCodec(def.domainId);
      try {
        domainVersions[def.domainId] = codec.probe(dataRoot).version;
      } catch {
        domainVersions[def.domainId] = 0;
      }
    }

    // Execute planned steps
    for (const step of migrationPlan.steps) {
      const { domainId, direction, fromVersion, toVersion, stepId } = step;
      markStepRunning(dataRoot, domainId, stepId);

      const codec = getCodec(domainId);
      let stepResult;
      if (direction === "forward") {
        stepResult = codec.forward(dataRoot, fromVersion, toVersion);
      } else {
        stepResult = codec.reverse(dataRoot, fromVersion, toVersion);
      }

      // Verify postcondition on actual storage
      codec.verifyPostcondition(dataRoot, toVersion);

      // Write authoritative domain marker
      writeDomainMarker(dataRoot, domainId, toVersion);

      domainVersions[domainId] = toVersion;
      markStepCommitted(dataRoot, domainId, toVersion);

      executedSteps.push({
        domainId,
        direction,
        fromVersion,
        toVersion,
        stepId,
        details: stepResult?.details || "ok",
      });
    }

    // Reconcile and write final ledger
    writeLedger(
      dataRoot,
      migrationPlan.targetVersion,
      migrationPlan.targetFrontierId,
      domainVersions
    );

    // Clean up journal on verified completion
    finishJournal(dataRoot);

    return {
      status: "success",
      targetVersion: migrationPlan.targetVersion,
      direction: migrationPlan.direction,
      convertedSteps: executedSteps,
      skippedDomains: migrationPlan.skipped.map((s) => s.domainId),
      preservations: listPreservations(dataRoot),
    };
  });
}
