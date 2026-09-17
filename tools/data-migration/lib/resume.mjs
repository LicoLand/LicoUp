import { withRootLock } from "./lock.mjs";
import { openJournal, markStepRunning, markStepPending, markStepCommitted, finishJournal } from "./journal.mjs";
import { getCodec } from "./codecs/index.mjs";
import { writeDomainMarker, writeLedger } from "./convert.mjs";
import { probeAllDomains } from "./probe.mjs";
import { listPreservations } from "./preservation.mjs";

export function resume(dataRoot) {
  return withRootLock(dataRoot, () => {
    const journal = openJournal(dataRoot);
    if (!journal) {
      return {
        status: "no_op",
        message: "No interrupted migration journal found at this data root",
      };
    }

    const resumedSteps = [];
    const pendingAuthorizationDomains = [];
    const domainVersions = {};

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
      preservations: listPreservations(dataRoot),
    };
  });
}
