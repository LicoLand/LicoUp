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
  markStoreFormatRunning,
  markStoreFormatCommitted,
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
import {
  isNativeAdmissionRequired,
  maintenanceConfirmationRequired,
} from "./native-owner.mjs";

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
  const { dryRun = false, writersStopped = false } = options;

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

    if (!writersStopped) {
      // The tool's lock excludes other tool runs, not a program that never
      // heard of it; only the operator can state that every writer stopped.
      throw maintenanceConfirmationRequired(`convert -> ${migrationPlan.targetVersion}`);
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
        pendingNativeAdmissionDomains: [],
        preservations: listPreservations(dataRoot),
      };
    }

    // Initialize durable journal for crash resilience
    initJournal(dataRoot, migrationPlan, {
      maintenanceConfirmedAt: new Date().toISOString(),
    });

    const executedSteps = [];
    const executedStoreFormatSteps = [];
    const pendingAuthorizationDomains = [];
    const pendingNativeAdmissionDomains = [];
    const domainVersions = {};

    // Populate baseline domain versions from probe
    const baseline = probeAllDomains(dataRoot);
    for (const [domainId, probe] of Object.entries(baseline)) {
      domainVersions[domainId] = probe.effectiveVersion !== undefined ? probe.effectiveVersion : probe.storeVersion;
    }

    // Store-format reverses first: a downgrade has to take the rows the older
    // shape cannot express out of the store *before* the domain step that drops
    // or rewrites that store runs.
    for (const step of (migrationPlan.storeFormatSteps ?? []).filter(
      (candidate) => candidate.direction === "reverse",
    )) {
      const codec = getCodec(step.domainId);
      markStoreFormatRunning(dataRoot, step.domainId, step.stepId);
      const result = codec.convertStoreFormat(dataRoot, step.fromFormat, step.toFormat, "reverse");
      codec.verifyStoreFormat(dataRoot, step.toFormat);
      markStoreFormatCommitted(dataRoot, step.domainId, step.toFormat);
      executedStoreFormatSteps.push({
        domainId: step.domainId,
        stepId: step.stepId,
        direction: "reverse",
        fromFormat: step.fromFormat,
        toFormat: step.toFormat,
        details: result?.details || "ok",
      });
    }

    // Execute planned steps
    for (const step of migrationPlan.steps) {
      const { domainId, direction, fromVersion, toVersion, stepId, deferredTo } = step;
      markStepRunning(dataRoot, domainId, stepId);

      if (deferredTo === "native-admission") {
        // The owner's move, planned and reported but not performed here. The
        // domain marker and ledger version stay where they are, so the native
        // admission still sees the step as owed and runs it under its own lock.
        markStepPending(dataRoot, domainId, "migration_requires_native_admission");
        if (!pendingNativeAdmissionDomains.includes(domainId)) {
          pendingNativeAdmissionDomains.push(domainId);
        }
        continue;
      }

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
        if (isNativeAdmissionRequired(err)) {
          // A codec refused a move only the owner can reproduce; same contract
          // as a planned deferral.
          markStepPending(dataRoot, domainId, "migration_requires_native_admission");
          if (!pendingNativeAdmissionDomains.includes(domainId)) {
            pendingNativeAdmissionDomains.push(domainId);
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

    // Store-format forwards last, for the mirror reason: the file only has the
    // shape to move from once the domain steps have produced the domain version
    // that publishes it.
    for (const step of (migrationPlan.storeFormatSteps ?? []).filter(
      (candidate) => candidate.direction === "forward",
    )) {
      if (pendingNativeAdmissionDomains.includes(step.domainId)) {
        // The shape these steps start from was not produced here; the owner
        // drives the store's own conversion under its own lock.
        continue;
      }
      const codec = getCodec(step.domainId);
      markStoreFormatRunning(dataRoot, step.domainId, step.stepId);
      let result;
      try {
        result = codec.convertStoreFormat(dataRoot, step.fromFormat, step.toFormat, "forward");
      } catch (err) {
        if (isNativeAdmissionRequired(err)) {
          // The store turned out to need the writer's typed move (documents to
          // canonicalize, run columns to backfill). Leave it exactly where it
          // is and report the domain, instead of advancing a version row over
          // work this tool cannot reproduce.
          markStoreFormatPending(dataRoot, step.domainId, "migration_requires_native_admission");
          if (!pendingNativeAdmissionDomains.includes(step.domainId)) {
            pendingNativeAdmissionDomains.push(step.domainId);
          }
          continue;
        }
        throw err;
      }
      codec.verifyStoreFormat(dataRoot, step.toFormat);
      markStoreFormatCommitted(dataRoot, step.domainId, step.toFormat);
      executedStoreFormatSteps.push({
        domainId: step.domainId,
        stepId: step.stepId,
        direction: "forward",
        fromFormat: step.fromFormat,
        toFormat: step.toFormat,
        mover: step.mover,
        details: result?.details || "ok",
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
      storeFormatSteps: executedStoreFormatSteps,
      skippedDomains: migrationPlan.skipped.map((s) => s.domainId),
      pendingAuthorizationDomains,
      pendingNativeAdmissionDomains,
      preservations: listPreservations(dataRoot),
    };
  });
}
