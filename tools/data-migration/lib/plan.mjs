import { resolveTargetProfile, getDomainDefinition } from "./catalog.mjs";
import { probeAllDomains, readLedger } from "./probe.mjs";

export function plan(dataRoot, targetProfileOrVersion = "latest") {
  const target = resolveTargetProfile(targetProfileOrVersion);
  const observed = probeAllDomains(dataRoot);
  const ledger = readLedger(dataRoot);

  const steps = [];
  const skipped = [];
  const preservationsPlanned = [];

  let hasForward = false;
  let hasReverse = false;

  for (const [domainId, probeResult] of Object.entries(observed)) {
    if (probeResult.error) {
      // Never plan conversions over a store the probe rejected; the native
      // admission boundary fails the same shapes as unsupported_state_shape.
      throw new Error(`unsupported_state_shape: probe failed for ${domainId}: ${probeResult.error}`);
    }
    const currentVersion = probeResult.effectiveVersion !== undefined ? probeResult.effectiveVersion : probeResult.storeVersion;
    const targetVersion = target.domains[domainId] !== undefined ? target.domains[domainId] : 0;
    const def = getDomainDefinition(domainId);

    if (currentVersion === targetVersion) {
      skipped.push({
        domainId,
        currentVersion,
        targetVersion,
        reason: "already_at_target",
      });
      continue;
    }

    if (currentVersion < targetVersion) {
      hasForward = true;
      let cursor = currentVersion;
      while (cursor < targetVersion) {
        const edge = def.steps.find((s) => s.fromSchemaVersion === cursor);
        if (!edge) {
          throw new Error(`migration_frontier_incomplete: missing forward edge for ${domainId} from ${cursor}`);
        }
        steps.push({
          domainId,
          direction: "forward",
          fromVersion: cursor,
          toVersion: edge.toSchemaVersion,
          stepId: edge.stepId,
        });
        cursor = edge.toSchemaVersion;
      }
    } else {
      // currentVersion > targetVersion (downgrade)
      hasReverse = true;
      let cursor = currentVersion;
      while (cursor > targetVersion) {
        const edge = def.reverseSteps?.find((s) => s.fromSchemaVersion === cursor);
        if (!edge) {
          throw new Error(`migration_frontier_incomplete: missing reverse edge for ${domainId} from ${cursor}`);
        }
        steps.push({
          domainId,
          direction: "reverse",
          fromVersion: cursor,
          toVersion: edge.toSchemaVersion,
          stepId: edge.stepId,
        });
        preservationsPlanned.push({
          domainId,
          fromVersion: cursor,
          toVersion: edge.toSchemaVersion,
          note: `Preserve ${domainId} records/metadata not expressible in schema ${edge.toSchemaVersion}`,
        });
        cursor = edge.toSchemaVersion;
      }
    }
  }

  let direction = "noop";
  if (hasForward && hasReverse) direction = "mixed";
  else if (hasForward) direction = "upgrade";
  else if (hasReverse) direction = "downgrade";

  return {
    targetName: targetProfileOrVersion,
    targetVersion: target.productVersion,
    targetFrontierId: target.frontierId,
    targetProfileLabel: target.label,
    direction,
    isNoOp: steps.length === 0,
    steps,
    skipped,
    preservationsPlanned,
    currentHighestAdmittedVersion: ledger ? ledger.highestAdmittedProductVersion : "0.0.0",
    targetHighestAdmittedVersion: target.productVersion,
  };
}
