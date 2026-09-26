import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { ensureDirectorySync, isRegularFileSync } from "../fs-atomic.mjs";
import {
  PUBLISHED_STRATEGY_FORMATS,
  applyNoticeOutbox,
  applyOrdinalBindings,
  applyWorkflowRouting,
  currentStrategyFormat,
  missingPublishedCoreTables,
  readPublishedDomainVersion,
  readPublishedFormat,
  restoreNoticeOutbox,
  reverseNoticeOutbox,
  strategyDatabasePath,
  strategyFormatPosition,
  strategyStorePath,
  workflowRoutingNeedsNative,
  writeStrategyStoreArtifact,
} from "../published-strategy-format.mjs";
import { nativeAdmissionRequired, unsupportedDowngrade } from "../native-owner.mjs";

const DOMAIN_ID = "adaptive-flywheel";

export function getDatabasePath(dataRoot) {
  return strategyDatabasePath(dataRoot);
}

export function getLegacyTomlPath(dataRoot) {
  return path.join(dataRoot, "client-state", "adaptive-flywheel.toml");
}

export function readStrategyMetaVersion(dbPath) {
  if (!isRegularFileSync(dbPath)) {
    return null;
  }
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const row = db.prepare("SELECT value FROM strategy_meta WHERE key = ?").get("version");
    return row ? String(row.value) : null;
  } catch {
    return null;
  } finally {
    if (db) {
      try { db.close(); } catch {}
    }
  }
}

export function probe(dataRoot) {
  const dbPath = getDatabasePath(dataRoot);
  const tomlPath = getLegacyTomlPath(dataRoot);

  if (isRegularFileSync(dbPath)) {
    // The published-format codec answers both questions at once: which shape
    // the file holds, and which frontier domain version that shape answers to.
    const storeFormat = readPublishedFormat(dbPath);
    return {
      version: readPublishedDomainVersion(dbPath),
      present: true,
      storeFormat: storeFormat.formatId,
    };
  }

  if (isRegularFileSync(tomlPath)) {
    return { version: 0, present: true, storeFormat: null };
  }

  return { version: 0, present: false, storeFormat: null };
}

/**
 * The forward owner of this domain's transition, or `null` when this tool can
 * perform it.
 *
 * Store absence is a state the owner itself admits without a file (the
 * published writer creates the store on its first open), so the marker-only
 * steps stay with the tool. A present file whose path to the current published
 * shape needs the writer's typed moves — the workflow compiler or the run
 * query-column backfill — is routed to the native admission, which drives the
 * store's own migrations. A file at a shape this tool can reproduce (the
 * delivery tables, or a store the writer already backfilled) stays here.
 */
export function forwardOwner(dataRoot) {
  const dbPath = getDatabasePath(dataRoot);
  if (!isRegularFileSync(dbPath)) return null;
  // A store missing the published writer's own schema is not one this tool can
  // move: the ordinary client open validates the version and creates only the
  // auxiliary tables, so a version move here would be the thing that made an
  // incomplete file look current.
  if (missingPublishedCoreTables(dbPath).length > 0) return "native-admission";
  const format = readPublishedFormat(dbPath);
  if (format.formatId === currentStrategyFormat().formatId) return null;
  return workflowRoutingNeedsNative(dbPath) === null ? null : "native-admission";
}

export function forward(dataRoot, fromVer, toVer) {
  const dbPath = getDatabasePath(dataRoot);
  ensureDirectorySync(path.dirname(dbPath));

  if (!isRegularFileSync(dbPath)) {
    // No file: the frontier's 0->1 step reconciles the ledger without a store,
    // exactly as the native admission does. Creating a partial database here
    // would declare a shape no published writer wrote and no reader expects;
    // the owner creates the store at the current shape on its first open. The
    // retired `adaptive-flywheel.toml` document is left for the conversation
    // owner's legacy import, which removes it with the other retired sources.
    return {
      converted: true,
      details: "store absent; the published writer creates it on first open",
    };
  }

  const missingCore = missingPublishedCoreTables(dbPath);
  if (missingCore.length > 0) {
    throw nativeAdmissionRequired(
      DOMAIN_ID,
      `(the store is missing ${missingCore.join(", ")}; the published writer's open path creates the full schema)`,
    );
  }

  if (fromVer === 0 && toVer === 1) {
    // A published file that predates ordinal bindings. Its rows move through
    // the writer's own rebuild rather than a version-row flip, so a converted
    // store is the shape the version claims.
    const ordinal = applyOrdinalBindings(dbPath);
    return {
      converted: true,
      details: `migrated adaptive flywheel to schema 2: ${ordinal.details}`,
    };
  }

  if (fromVer === 1 && toVer === 2) {
    // The published writer's own routing move. The tool performs it only where
    // it can be reproduced without the compiler or the typed run backfill: a
    // store that still needs either is refused with a stable code, so the
    // caller routes the domain to the native admission instead of handing a
    // later reader a shape nobody produced.
    const routing = applyWorkflowRouting(dbPath);
    return {
      converted: true,
      details: `migrated adaptive flywheel to schema 3 (workflow routing): ${routing.details}`,
    };
  }

  if (fromVer === 0 && toVer === 2) {
    forward(dataRoot, 0, 1);
    return forward(dataRoot, 1, 2);
  }

  throw new Error(`Unsupported forward migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

/**
 * A downgrade this tool refuses before writing anything, or `null`.
 *
 * Domain 1 -> 0 means the version-1 published shape: bindings without
 * `ordinal`, no per-slot multiplicity, and a receiver that predates the run,
 * event and command tables. Expressing the current rows in it would drop
 * ordinals and execution history; there is no published downgrade for that and
 * no receiver to verify it against, so the tool refuses instead of handing an
 * older client a file whose metadata it cannot honour. An absent store is a
 * valid state at every version, so reverse edges over absence are no-ops.
 */
export function reverseRefusal(dataRoot, fromVersion, toVersion) {
  if (toVersion !== 0) return null;
  if (!isRegularFileSync(getDatabasePath(dataRoot))) return null;
  return (
    "the version-1 shape has no ordinal bindings and cannot hold the runs, " +
    "events and commands the current store does"
  );
}

/**
 * Reverse edges this tool performs, and the evidence that makes each a truthful
 * metadata claim rather than a version row over data the older receiver cannot
 * read.
 *
 * Domain 2 -> 1 (`strategy-store-3` -> `strategy-store-2`) is supported. The
 * version-2 writer itself stored `serde_json::to_string(&compiled.definition)`
 * and its reader deserialized `WorkflowDefinition` (see
 * `b4777f47^:crates/licoup-native/src/domain/adaptive_flywheel/store.rs`,
 * `register_definition` and the definition load path), and the definition IR
 * has not changed since that revision — so every definition row a version-3
 * store holds is already in the exact form version 2 wrote and read. The move
 * therefore changes the version row and nothing else: no document is rewritten,
 * no row is dropped, and nothing needs a preservation area. Re-upgrading that
 * store is the published writer's own routing move (the native admission),
 * because deciding that a document needs canonicalizing is the compiler's call,
 * not this tool's.
 */
export function reverse(dataRoot, fromVer, toVer) {
  const refusal = reverseRefusal(dataRoot, fromVer, toVer);
  if (refusal !== null) {
    throw unsupportedDowngrade(DOMAIN_ID, `(${refusal})`);
  }

  const dbPath = getDatabasePath(dataRoot);
  if (!isRegularFileSync(dbPath)) {
    return { converted: true, details: "database absent" };
  }

  if (fromVer === 2 && toVer === 1) {
    const observed = readPublishedFormat(dbPath);
    if (observed !== null && observed.formatId === "strategy-store-2") {
      return { converted: true, details: "store is already the version-2 shape" };
    }
    if (observed === null || observed.formatId !== "strategy-store-3") {
      throw unsupportedDowngrade(
        DOMAIN_ID,
        `(the store is ${observed === null ? "not a published shape" : observed.formatId}, not strategy-store-3)`,
      );
    }
    let db;
    try {
      db = new DatabaseSync(dbPath);
      db.exec("BEGIN IMMEDIATE");
      db.exec("UPDATE strategy_meta SET value='2' WHERE key='version'");
      db.exec("COMMIT");
    } catch (error) {
      try {
        db?.exec("ROLLBACK");
      } catch {
        // The transaction never opened, or SQLite already rolled it back.
      }
      throw error;
    } finally {
      if (db) {
        try {
          db.close();
        } catch {}
      }
    }
    return {
      converted: true,
      details:
        "version row moved to 2; every definition, binding, authorization and run row is unchanged",
    };
  }

  throw new Error(`Unsupported reverse migration edge for ${DOMAIN_ID}: ${fromVer} -> ${toVer}`);
}

/**
 * One store-format conversion, driven by the plan's own store-format step.
 *
 * This is the part of the adaptive-flywheel domain that does not move the
 * frontier domain version: the current format adds tables under the same
 * `strategy_meta` version, so the plan carries it as a store-format step and it
 * is executed here, under the root lock and with a journal entry, instead of
 * being left to whatever the next process that opens the database decides to
 * create.
 */
export function convertStoreFormat(dataRoot, fromFormat, toFormat, direction) {
  const dbPath = getDatabasePath(dataRoot);
  const observed = readPublishedFormat(dbPath);
  if (observed === null) {
    // No store at all: nothing to convert, and nothing a downgrade could have
    // left unrepresentable. The published writer creates the store at the
    // current shape on its first open, so there is no shape to move a version
    // row toward.
    return { applied: false, details: "store absent" };
  }
  const currentFormatId = currentStrategyFormat().formatId;
  if (direction === "reverse") {
    if (observed.formatId !== fromFormat) {
      // Already downgraded, or never upgraded: nothing unrepresentable here.
      return { applied: false, details: `store is ${observed.formatId}` };
    }
    const result = reverseNoticeOutbox(dataRoot, dbPath);
    // The record says a conversion toward the current shape is still owed,
    // which is exactly what a downgraded store is.
    writeStrategyStoreArtifact(dataRoot, {
      fromFormat: observed.formatId,
      targetFormat: toFormat,
      appliedStepIds: [noticeOutboxStepId()],
      status: toFormat === currentFormatId ? "applied" : "pending",
    });
    return { applied: true, details: result.details };
  }
  if (observed.formatId === toFormat) {
    return { applied: false, details: `store is already ${toFormat}` };
  }
  const missingCore = missingPublishedCoreTables(dbPath);
  if (missingCore.length > 0) {
    throw nativeAdmissionRequired(
      DOMAIN_ID,
      `(the store is missing ${missingCore.join(", ")}; the published writer's open path creates the full schema)`,
    );
  }
  if (strategyFormatPosition(observed.formatId) > strategyFormatPosition(toFormat)) {
    throw new Error(`state_newer_than_binary in ${DOMAIN_ID}`);
  }
  const applied = [];
  for (const edge of strategyStorePath(observed.formatId, toFormat)) {
    if (edge.mover === "typed-store") {
      // The published writer's routing move is reproducible here, and
      // `applyWorkflowRouting` refuses the cases that are not: documents that
      // need the compiler, or runs whose query columns still need the typed
      // backfill.
      applyWorkflowRouting(dbPath);
    } else {
      applyNoticeOutbox(dbPath);
    }
    applied.push(edge.stepId);
  }
  // A downgrade that preserved delivery rows leaves them here; re-upgrading
  // merges them back without overwriting anything recorded in the meantime.
  const restored = restoreNoticeOutbox(dataRoot, dbPath);
  writeStrategyStoreArtifact(dataRoot, {
    fromFormat: observed.formatId,
    targetFormat: toFormat,
    appliedStepIds: applied,
    // "Applied" means the store is at the shape this tool calls current: a
    // conversion that stopped at an older shape still owes the rest, and the
    // record must not read as finished.
    status: toFormat === currentFormatId ? "applied" : "pending",
  });
  return {
    applied: applied.length > 0,
    details: `${applied.join(", ")}${restored.applied ? `; ${restored.details}` : ""}`,
  };
}

function noticeOutboxStepId() {
  return "adaptive-flywheel.strategy-store-notice-outbox";
}

export function verifyStoreFormat(dataRoot, expectedFormat) {
  const dbPath = getDatabasePath(dataRoot);
  const observed = readPublishedFormat(dbPath);
  if (observed === null) {
    throw new Error(`migration_postcondition_failed: ${DOMAIN_ID} store absent`);
  }
  if (observed.formatId !== expectedFormat) {
    throw new Error(
      `migration_postcondition_failed: ${DOMAIN_ID} expected ${expectedFormat}, observed ${observed.formatId}`,
    );
  }
  return true;
}

export function verifyPostcondition(dataRoot, targetVersion) {
  const result = probe(dataRoot);
  if (result.present && result.version !== targetVersion) {
    throw new Error(`migration_postcondition_failed: ${DOMAIN_ID} expected version ${targetVersion}, observed ${result.version}`);
  }
  return true;
}

export { PUBLISHED_STRATEGY_FORMATS, currentStrategyFormat };
