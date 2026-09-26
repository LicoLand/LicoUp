import {
  resolveTargetProfile,
  getDomainDefinition,
  resolveProfileStoreFormat,
} from "./catalog.mjs";
import { getCodec } from "./codecs/index.mjs";
import {
  STRATEGY_STORE_EDGES,
  strategyFormatForDomainVersion,
  strategyFormatPosition,
  strategyStorePath,
} from "./published-strategy-format.mjs";

/**
 * The one shape this tool adds on top of a published one. Named here so a
 * reverse step removes exactly what a forward step created, and so a renamed
 * edge fails a test instead of silently planning nothing.
 */
const noticeOutboxEdge = STRATEGY_STORE_EDGES.find(
  (edge) => edge.stepId === "adaptive-flywheel.strategy-store-notice-outbox",
);
import { probeAllDomains, readLedger } from "./probe.mjs";

export function plan(dataRoot, targetProfileOrVersion = "latest") {
  const target = resolveTargetProfile(targetProfileOrVersion);
  const observed = probeAllDomains(dataRoot);
  const ledger = readLedger(dataRoot);

  const steps = [];
  const skipped = [];
  const preservationsPlanned = [];
  const storeFormatSteps = [];
  // Domains whose frontier step the tool will not perform: the move belongs to
  // the native owner (the Conversation store's legacy import, the strategy
  // store's typed routing move). The step is still planned, so the journal and
  // the report name it; the store-format steps derived from the shape it would
  // have produced are not, because that shape is not reached here.
  const deferredDomains = new Set();

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
    const codec = getCodec(domainId);

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
      const deferredTo = codec.forwardOwner ? codec.forwardOwner(dataRoot) : null;
      if (deferredTo) deferredDomains.add(domainId);
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
          deferredTo,
        });
        cursor = edge.toSchemaVersion;
      }
    } else {
      // currentVersion > targetVersion (downgrade)
      if (codec.cannotReverse) {
        // Refused before anything is written: a half-downgraded root with no
        // way back is exactly what the old-or-new rule forbids.
        throw new Error(
          `migration_unsupported_downgrade: ${domainId} cannot be downgraded by this tool`,
        );
      }
      hasReverse = true;
      let cursor = currentVersion;
      while (cursor > targetVersion) {
        const edge = def.reverseSteps?.find((s) => s.fromSchemaVersion === cursor);
        if (!edge) {
          throw new Error(`migration_frontier_incomplete: missing reverse edge for ${domainId} from ${cursor}`);
        }
        // A downgrade whose result the older receiver cannot be shown to read
        // is refused here, before the journal or any store is touched: the plan
        // must not hand the caller a route the tool will not walk.
        const refusal = codec.reverseRefusal
          ? codec.reverseRefusal(dataRoot, cursor, edge.toSchemaVersion)
          : null;
        if (refusal) {
          throw new Error(
            `migration_unsupported_downgrade: ${domainId} ${edge.fromSchemaVersion} -> ${edge.toSchemaVersion}: ${refusal}`,
          );
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

  // Store-format steps: shapes one domain published under the same domain
  // version. They are planned separately from the frontier steps because they
  // do not move a domain version — the ledger stays exactly what the compiled
  // admission expects — and because a reverse one has to run before the domain
  // step that would drop the store the shape lives in.
  for (const [domainId, probeResult] of Object.entries(observed)) {
    const targetFormat = resolveProfileStoreFormat(target, domainId);
    if (targetFormat === null) continue;
    const codec = getCodec(domainId);
    // A domain whose store work belongs to the native owner keeps the shape it
    // has: the owner's move produces the shape these steps would start from,
    // and its open path creates whatever the file is missing.
    if (deferredDomains.has(domainId)) continue;
    if (codec.forwardOwner && codec.forwardOwner(dataRoot) === "native-admission") continue;
    // An absent store has no shape to move; the owner creates it at the
    // current format on first open.
    if ((probeResult.storeFormat ?? null) === null) continue;
    const targetVersion = target.domains[domainId] ?? 0;
    const observedFormat = probeResult.storeFormat ?? null;
    // The shape the *domain* steps leave behind: an upgrade to domain version 2
    // publishes the shape that version shipped, and the older shapes are that
    // same chain. Planning from here — rather than from the shape the file
    // holds now — is what keeps the store-format steps to the part the domain
    // steps do not already perform.
    const afterDomainSteps =
      targetVersion > 0 ? strategyFormatForDomainVersion(targetVersion).formatId : null;
    const forwardBase =
      afterDomainSteps === null
        ? observedFormat
        : observedFormat === null ||
            strategyFormatPosition(afterDomainSteps) > strategyFormatPosition(observedFormat)
          ? afterDomainSteps
          : observedFormat;
    if (forwardBase === null) continue;
    if (strategyFormatPosition(forwardBase) < strategyFormatPosition(targetFormat)) {
      for (const edge of strategyStorePath(forwardBase, targetFormat)) {
        storeFormatSteps.push({
          domainId,
          direction: "forward",
          stepId: edge.stepId,
          fromFormat: edge.from,
          toFormat: edge.to,
          mover: edge.mover,
        });
      }
      continue;
    }
    // Reverse: only the shape the tool itself added comes back out here. The
    // older shapes are the published writer's own domain moves, which the
    // domain steps already run, so a reverse step stops at the newest shape
    // this tool produced rather than at the profile's whole target.
    if (
      observedFormat !== null &&
      strategyFormatPosition(observedFormat) > strategyFormatPosition(noticeOutboxEdge.from) &&
      strategyFormatPosition(targetFormat) < strategyFormatPosition(observedFormat)
    ) {
      storeFormatSteps.push({
        domainId,
        direction: "reverse",
        stepId: noticeOutboxEdge.stepId,
        fromFormat: observedFormat,
        toFormat: noticeOutboxEdge.from,
        mover: "tool",
      });
      preservationsPlanned.push({
        domainId,
        fromFormat: observedFormat,
        toFormat: noticeOutboxEdge.from,
        note: `${domainId} delivery rows the published shape cannot express`,
      });
    }
  }

  let direction = "noop";
  if (hasForward && hasReverse) direction = "mixed";
  else if (hasForward) direction = "upgrade";
  else if (hasReverse) direction = "downgrade";
  if (direction === "noop" && storeFormatSteps.length > 0) {
    direction = storeFormatSteps.some((step) => step.direction === "reverse")
      ? "downgrade"
      : "upgrade";
  }

  return {
    targetName: targetProfileOrVersion,
    targetVersion: target.productVersion,
    targetFrontierId: target.frontierId,
    targetProfileLabel: target.label,
    direction,
    isNoOp: steps.length === 0 && storeFormatSteps.length === 0,
    steps,
    storeFormatSteps,
    skipped,
    preservationsPlanned,
    currentHighestAdmittedVersion: ledger ? ledger.highestAdmittedProductVersion : "0.0.0",
    targetHighestAdmittedVersion: target.productVersion,
  };
}
