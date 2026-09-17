import { withRootLock } from "./lock.mjs";
import { openJournal, markStepRunning, markStepCommitted, finishJournal } from "./journal.mjs";
import { getCodec } from "./codecs/index.mjs";
import { writeDomainMarker, writeLedger } from "./convert.mjs";
import { probeAllDomains } from "./probe.mjs";
import { listPreservations } from "./preservation.mjs";
import { DOMAIN_DEFINITIONS } from "./catalog.mjs";

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
    const domainVersions = {};

    // Baseline observed state
    const currentProbes = probeAllDomains(dataRoot);
    for (const [dId, probe] of Object.entries(currentProbes)) {
      domainVersions[dId] = probe.storeVersion;
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
      if (currentVer < targetVer) {
        stepResult = codec.forward(dataRoot, currentVer, targetVer);
      } else if (currentVer > targetVer) {
        stepResult = codec.reverse(dataRoot, currentVer, targetVer);
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
      preservations: listPreservations(dataRoot),
    };
  });
}
