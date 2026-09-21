import { withRootLock } from "./lock.mjs";
import {
  openJournal,
  markStepRunning,
  markStepPending,
  markStepCommitted,
  markStoreFormatRunning,
  markStoreFormatCommitted,
  markStoreFormatPending,
  finishJournal,
} from "./journal.mjs";
import { getCodec } from "./codecs/index.mjs";
import { writeDomainMarker, writeLedger } from "./convert.mjs";
import { probeAllDomains } from "./probe.mjs";
import { listPreservations } from "./preservation.mjs";
import {
  isNativeAdmissionRequired,
  maintenanceConfirmationRequired,
} from "./native-owner.mjs";

export function resume(dataRoot, options = {}) {
  const { writersStopped = false } = options;

  return withRootLock(dataRoot, () => {
    const journal = openJournal(dataRoot);
    if (!journal) {
      return {
        status: "no_op",
        message: "No interrupted migration journal found at this data root",
      };
    }

    if (!writersStopped) {
      throw maintenanceConfirmationRequired(`resume -> ${journal.targetVersion}`);
    }

    const resumedSteps = [];
    const pendingAuthorizationDomains = [];
    const pendingNativeAdmissionDomains = [];
    const domainVersions = {};

    // Store-format steps resume from the physical shape the file holds: the
    // journal says a step was in flight, the file says what actually happened,
    // and each conversion is idempotent. A reverse has to run before the domain
    // step that would drop the store it preserves rows out of, so the two
    // halves are ordered around the domain loop exactly as `convert` orders
    // them.
    const storeFormatEntries = Object.entries(journal.storeFormats ?? {});
    const reverseStoreFormats = storeFormatEntries.filter(
      ([, entry]) => entry.direction === "reverse",
    );
    const forwardStoreFormats = storeFormatEntries.filter(
      ([, entry]) => entry.direction !== "reverse",
    );
    const resumeStoreFormats = (entries) => {
      for (const [domainId, entry] of entries) {
        const codec = getCodec(domainId);
        if (entry.status === "committed") {
          try {
            codec.verifyStoreFormat(dataRoot, entry.toFormat);
            resumedSteps.push({
              domainId,
              status: "already_committed",
              storeFormat: entry.toFormat,
            });
            continue;
          } catch {
            // The store is not where the journal claims; re-run the conversion.
          }
        }
        markStoreFormatRunning(dataRoot, domainId, entry.stepId);
        let result;
        try {
          result = codec.convertStoreFormat(
            dataRoot,
            entry.fromFormat,
            entry.toFormat,
            entry.direction,
          );
        } catch (err) {
          if (isNativeAdmissionRequired(err)) {
            markStoreFormatPending(dataRoot, domainId, "migration_requires_native_admission");
            if (!pendingNativeAdmissionDomains.includes(domainId)) {
              pendingNativeAdmissionDomains.push(domainId);
            }
            resumedSteps.push({
              domainId,
              status: "pending_native_admission",
              storeFormat: entry.toFormat,
            });
            continue;
          }
          throw err;
        }
        if (result?.applied) codec.verifyStoreFormat(dataRoot, entry.toFormat);
        markStoreFormatCommitted(dataRoot, domainId, entry.toFormat);
        resumedSteps.push({
          domainId,
          status: "resumed_and_committed",
          storeFormat: entry.toFormat,
          details: result?.details || "ok",
        });
      }
    };
    resumeStoreFormats(reverseStoreFormats);

    // Baseline observed state (effective authoritative version, as in plan)
    const currentProbes = probeAllDomains(dataRoot);
    for (const [dId, probe] of Object.entries(currentProbes)) {
      if (probe.error) {
        throw new Error(`unsupported_state_shape: probe failed for ${dId}: ${probe.error}`);
      }
      domainVersions[dId] = probe.effectiveVersion !== undefined ? probe.effectiveVersion : probe.storeVersion;
    }

    for (const [domainId, entry] of Object.entries(journal.domains)) {
      const codec = getCodec(domainId);
      const targetVer = entry.toVersion !== undefined ? entry.toVersion : entry.committedVersion;

      if (entry.deferredTo === "native-admission") {
        // Planned for the native owner; a resume must not execute it here.
        markStepPending(dataRoot, domainId, "migration_requires_native_admission");
        if (!pendingNativeAdmissionDomains.includes(domainId)) {
          pendingNativeAdmissionDomains.push(domainId);
        }
        resumedSteps.push({
          domainId,
          status: "pending_native_admission",
          version: targetVer,
        });
        continue;
      }

      if (entry.status === "committed") {
        // Step was committed before interruption; verify postcondition
        try {
          codec.verifyPostcondition(dataRoot, targetVer);
          domainVersions[domainId] = targetVer;
          resumedSteps.push({
            domainId,
            status: "already_committed",
            version: targetVer,
          });
          continue;
        } catch {
          // Postcondition failed; re-execute step
        }
      }

      // Execute or re-execute pending/running step
      markStepRunning(dataRoot, domainId, entry.stepId);
      const currentVer = domainVersions[domainId] !== undefined ? domainVersions[domainId] : 0;
      let stepResult;
      try {
        if (currentVer < targetVer) {
          stepResult = codec.forward(dataRoot, currentVer, targetVer);
        } else if (currentVer > targetVer) {
          stepResult = codec.reverse(dataRoot, currentVer, targetVer);
        }
      } catch (err) {
        if (err && err.code === "migration_authorization_required") {
          markStepPending(dataRoot, domainId, "migration_authorization_required");
          if (!pendingAuthorizationDomains.includes(domainId)) {
            pendingAuthorizationDomains.push(domainId);
          }
          continue;
        }
        if (isNativeAdmissionRequired(err)) {
          markStepPending(dataRoot, domainId, "migration_requires_native_admission");
          if (!pendingNativeAdmissionDomains.includes(domainId)) {
            pendingNativeAdmissionDomains.push(domainId);
          }
          continue;
        }
        throw err;
      }

      codec.verifyPostcondition(dataRoot, targetVer);
      writeDomainMarker(dataRoot, domainId, targetVer);
      domainVersions[domainId] = targetVer;
      markStepCommitted(dataRoot, domainId, targetVer);

      resumedSteps.push({
        domainId,
        status: "resumed_and_committed",
        version: targetVer,
        details: stepResult?.details || "ok",
      });
    }

    // Store-format forwards resume last, for the same reason `convert` runs
    // them last: the file only holds the shape to move from once the domain
    // steps have produced the domain version that publishes it. A domain the
    // native owner still owes keeps its shape here.
    resumeStoreFormats(
      forwardStoreFormats.filter(
        ([domainId]) => !pendingNativeAdmissionDomains.includes(domainId),
      ),
    );

    // Finalize ledger
    writeLedger(
      dataRoot,
      journal.targetVersion,
      journal.targetFrontierId,
      domainVersions
    );

    // Remove journal
    finishJournal(dataRoot);

    return {
      status: "success",
      targetVersion: journal.targetVersion,
      resumedSteps,
      pendingAuthorizationDomains,
      pendingNativeAdmissionDomains,
      preservations: listPreservations(dataRoot),
    };
  });
}
