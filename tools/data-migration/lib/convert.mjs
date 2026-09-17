import path from "node:path";
import { withRootLock } from "./lock.mjs";
import { plan as computePlan } from "./plan.mjs";
import { getCodec } from "./codecs/index.mjs";
import {
  initJournal,
  openJournal,
  markStepRunning,
  markStepPending,
  markStepCommitted,
  finishJournal,
} from "./journal.mjs";
import {
  writeJsonAtomicSync,
  ensureDirectorySync,
} from "./fs-atomic.mjs";
import {
  DOMAIN_DEFINITIONS,
  DOMAIN_MARKER_SCHEMA,
  LEDGER_SCHEMA,
} from "./catalog.mjs";
import { listPreservations } from "./preservation.mjs";
import { getLedgerPath, getMarkerPath, probeAllDomains } from "./probe.mjs";

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
    const pendingJournal = openJournal(dataRoot);
    if (!dryRun && pendingJournal && pendingJournal.status === "in_progress") {
      throw new Error(
        "migration_interrupted: an earlier conversion did not complete; run 'licoup-migrate resume' for this data root"
      );
    }

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
      const baseline = probeAllDomains(dataRoot);
      const currentVersions = {};
      for (const [domainId, probe] of Object.entries(baseline)) {
        currentVersions[domainId] = probe.effectiveVersion !== undefined ? probe.effectiveVersion : probe.storeVersion;
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
        pendingAuthorizationDomains: [],
        preservations: listPreservations(dataRoot),
      };
    }

    // Initialize durable journal for crash resilience
    initJournal(dataRoot, migrationPlan);

    const executedSteps = [];
    const pendingAuthorizationDomains = [];
    const domainVersions = {};

    // Populate baseline domain versions from probe
    const baseline = probeAllDomains(dataRoot);
    for (const [domainId, probe] of Object.entries(baseline)) {
      domainVersions[domainId] = probe.effectiveVersion !== undefined ? probe.effectiveVersion : probe.storeVersion;
    }

    // Execute planned steps
    for (const step of migrationPlan.steps) {
      const { domainId, direction, fromVersion, toVersion, stepId } = step;
      markStepRunning(dataRoot, domainId, stepId);

      const codec = getCodec(domainId);
      let stepResult;
      try {
        if (direction === "forward") {
          stepResult = codec.forward(dataRoot, fromVersion, toVersion);
        } else {
          stepResult = codec.reverse(dataRoot, fromVersion, toVersion);
        }
      } catch (err) {
        if (err && err.code === "migration_authorization_required") {
          // Protected domains (platform credential custody) keep their
          // current marker/store untouched and are reported like the native
          // admission boundary reports pending_authorization_domain_ids.
          markStepPending(dataRoot, domainId, "migration_authorization_required");
          if (!pendingAuthorizationDomains.includes(domainId)) {
            pendingAuthorizationDomains.push(domainId);
          }
          continue;
        }
        throw err;
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
      pendingAuthorizationDomains,
      preservations: listPreservations(dataRoot),
    };
  });
}
