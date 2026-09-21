import path from "node:path";
import fs from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { isRegularFileSync } from "../fs-atomic.mjs";
import { nativeAdmissionRequired, unsupportedDowngrade } from "../native-owner.mjs";

// The canonical Conversation domain is owned by the client's Conversation
// store, and this tool does not fabricate it.
//
// The published format is a SQLite store whose writer imports the legacy
// projection/group documents through typed semantics (provenance rows, stable
// source identities, memberships, event parts, runtime bindings) and whose
// schema advances through in-store migrations. A second implementation here
// would be a second definition of that owner, and a file that merely declares
// the version would be indistinguishable from the real thing to every later
// reader. What this codec does instead is what the native admission boundary
// does: read the real files, answer the same `unsupported_state_shape` /
// `state_newer_than_binary` refusals, and route the transition to the owner.
//
// Schema facts below are pinned against the publishing crate by
// `tests/conversation-owner-boundary.test.mjs`.

const DOMAIN_ID = "canonical-conversation";

/**
 * `licoup_conversation::store::CURRENT_SCHEMA_VERSION`.
 *
 * A store whose inner schema is ahead of this is refused rather than read; a
 * store behind it is upgraded by the store's own open path when the native
 * admission runs.
 */
export const CURRENT_SQLITE_SCHEMA_VERSION = "17";

const COMPLETION_MARKER_CONTENT = "schema=v5\nstatus=complete\n";

/**
 * The oldest shape every published generation shares: the version row and the
 * conversation identity columns. Deliberately not the full table list — older
 * published stores predate most tables, and the in-store migration owns the
 * rest. What it rejects is a database with no conversation table at all.
 */
export const PUBLISHED_STORE_CORE = Object.freeze([
  Object.freeze({ table: "schema_meta", columns: Object.freeze(["key", "value"]) }),
  Object.freeze({ table: "conversations", columns: Object.freeze(["id", "title"]) }),
]);

/** The tool cannot express a canonical store in the legacy projection shape. */
export const cannotReverse = true;

export function getDatabasePath(dataRoot) {
  return path.join(dataRoot, "client-state", "conversations", "conversations.sqlite3");
}

export function getCompletionMarkerPath(dataRoot) {
  return path.join(dataRoot, "client-state", "conversations", "migration-v5.complete");
}

export function getLegacyProjectionPath(dataRoot) {
  return path.join(dataRoot, "client-state", "agent-conversation-projections.json");
}

export function getLegacyGroupPath(dataRoot) {
  return path.join(dataRoot, "client-state", "group-conversations", "lico-group-default.json");
}

export function hasLegacyFiles(dataRoot) {
  const stateRoot = path.join(dataRoot, "client-state");
  const projection = path.join(stateRoot, "agent-conversation-projections.json");
  const flywheelToml = path.join(stateRoot, "adaptive-flywheel.toml");
  const groupDir = path.join(stateRoot, "group-conversations");

  return (
    isRegularFileSync(projection) ||
    isRegularFileSync(flywheelToml) ||
    isDirectoryPresent(groupDir)
  );
}

function isDirectoryPresent(dirPath) {
  try {
    const stat = fs.lstatSync(dirPath);
    return stat.isDirectory() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function tableColumns(database, table) {
  return database
    .prepare(`PRAGMA table_info(${table})`)
    .all()
    .map((row) => String(row.name));
}

/**
 * Refuse a database that is not a conversation store at all.
 *
 * The native probe applies the same check before it trusts the completion
 * marker: without it, a file carrying only a version row and a marker would be
 * admitted as the canonical owner's state.
 */
function ensurePublishedStoreShape(databasePath) {
  let database;
  try {
    database = new DatabaseSync(databasePath, { readOnly: true });
  } catch {
    throw new Error(`unsupported_state_shape in ${DOMAIN_ID}: database is unreadable`);
  }
  try {
    for (const { table, columns } of PUBLISHED_STORE_CORE) {
      const present = tableColumns(database, table);
      const complete =
        present.length > 0 && columns.every((column) => present.includes(column));
      if (!complete) {
        throw new Error(
          `unsupported_state_shape in ${DOMAIN_ID}: ${table} is not the published table`,
        );
      }
    }
  } finally {
    database.close();
  }
}

function readPublishedSqliteVersion(databasePath) {
  let database;
  try {
    database = new DatabaseSync(databasePath, { readOnly: true });
  } catch {
    throw new Error(`unsupported_state_shape in ${DOMAIN_ID}: database is unreadable`);
  }
  try {
    let row;
    try {
      row = database.prepare("SELECT value FROM schema_meta WHERE key = ?").get("version");
    } catch {
      throw new Error(`unsupported_state_shape in ${DOMAIN_ID}: schema_meta is unreadable`);
    }
    if (row === undefined || row === null) {
      throw new Error(`unsupported_state_shape in ${DOMAIN_ID}: schema_meta has no version`);
    }
    return String(row.value);
  } finally {
    database.close();
  }
}

export function probe(dataRoot) {
  const dbPath = getDatabasePath(dataRoot);
  const markerPath = getCompletionMarkerPath(dataRoot);
  const dbPresent = isRegularFileSync(dbPath);
  const markerPresent = isRegularFileSync(markerPath);
  const legacyPresent = hasLegacyFiles(dataRoot);

  if (!dbPresent) {
    if (markerPresent) {
      throw new Error(
        `unsupported_state_shape in ${DOMAIN_ID}: completion marker present without database`,
      );
    }
    return { version: 0, present: legacyPresent };
  }

  ensurePublishedStoreShape(dbPath);
  const sqliteVersion = readPublishedSqliteVersion(dbPath);
  if (!/^\d+$/.test(sqliteVersion)) {
    throw new Error(
      `unsupported_state_shape in ${DOMAIN_ID}: schema version is not numeric`,
    );
  }
  if (Number(sqliteVersion) > Number(CURRENT_SQLITE_SCHEMA_VERSION)) {
    throw new Error(`state_newer_than_binary in ${DOMAIN_ID}`);
  }

  if (!markerPresent) {
    // A database without the cutover marker is a store the legacy import still
    // owes; the domain version stays 0 so the owner performs it.
    return { version: 0, present: true, sqliteVersion };
  }
  if (legacyPresent) {
    throw new Error(
      `unsupported_state_shape in ${DOMAIN_ID}: legacy sources and a completed store coexist`,
    );
  }
  const markerText = fs.readFileSync(markerPath, "utf8");
  if (markerText !== COMPLETION_MARKER_CONTENT) {
    throw new Error(
      `unsupported_state_shape in ${DOMAIN_ID}: completion marker content mismatch`,
    );
  }

  // The completion marker is authoritative for the domain version; the inner
  // SQLite schema advances through in-store upgrades owned by the client.
  return { version: 1, present: true, sqliteVersion };
}

/**
 * The domain's transition belongs to the native owner in both directions:
 * legacy projection/group documents in, canonical store out.
 */
export function forwardOwner() {
  return "native-admission";
}

export function forward() {
  throw nativeAdmissionRequired(
    DOMAIN_ID,
    "(the Conversation store imports legacy state and owns the canonical schema)",
  );
}

export function reverse() {
  throw unsupportedDowngrade(
    DOMAIN_ID,
    "(the tool cannot express a canonical store as the legacy projection, and the Conversation owner has no downgrade path)",
  );
}

export function verifyPostcondition(dataRoot, targetVersion) {
  const result = probe(dataRoot);
  if (result.present && result.version !== targetVersion) {
    throw new Error(
      `migration_postcondition_failed: ${DOMAIN_ID} expected version ${targetVersion}, observed ${result.version}`,
    );
  }
  return true;
}
