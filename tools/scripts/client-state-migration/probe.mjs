import { closeSync, constants, lstatSync, openSync, readSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

import { MigrationStateError } from "./errors.mjs";
import {
  asText,
  asU64,
  isPlainObject,
  readBoundedText,
  readJsonArtifact,
  regularFileExists,
  requireValue,
} from "./util.mjs";

export const GATEWAY_CUSTODY_DOMAIN = "gateway-credential-custody";

// Every constant below is the admission's own contract, mirrored read-only.
// The final test in `tests/contract/client/client-state-migration-diagnostic.test.mjs`
// fails if this file drifts from the Rust admission.
const CLIENT_STATE_SCHEMA_VERSION = "v0.0.1:schema:definition-1";
const CLIENT_STATE_COLLECTIONS = Object.freeze([
  "settings",
  "targets",
  "target-discovery-cache",
  "pairings",
  "skills",
  "pins",
  "identities",
  "conversation-archive-profiles",
  "agent-usage-reports",
  "provider-quota-snapshots",
  "skill-usage",
  "collaboration-plugins",
  "local-server-assemblies",
  "local-server-assembly-cleanup",
  "local-server-assembly-transaction",
  "mcp-install-transactions",
]);
const CONVERSATION_SCHEMA_VERSION = "15";
const CONVERSATION_COMPLETION_MARKER = "schema=v5\nstatus=complete\n";
const ADAPTIVE_FLYWHEEL_SCHEMA_VERSIONS = Object.freeze({ "3": 2, "2": 1 });
const MOBILE_RELAY_SCHEMA_VERSION = 2;
const MOBILE_RELAY_E2EE_PROTOCOL_VERSION =
  "licomesh.mobile-relay.e2ee.pqxdh-mlkem1024.v1";
const SQLITE_HEADER = `SQLite format 3${String.fromCharCode(0)}`;

/**
 * The durable shapes this tool understands, keyed by domain. `document` is the
 * domain's own schema marker; `schemaVersion` is the value the admission stamps
 * into it. A domain is repairable only when that stamped value is the frontier's
 * own step target, so the frontier alone defines the repair.
 */
export const DURABLE_SHAPES = Object.freeze({
  "gateway-credential-custody": Object.freeze({ kind: "native-custody" }),
  "client-state": Object.freeze({ kind: "collections", directory: "client-state" }),
  "canonical-conversation": Object.freeze({ kind: "conversation-store" }),
  "adaptive-flywheel": Object.freeze({ kind: "sqlite-meta" }),
  "workspace-manifest": Object.freeze({
    kind: "json-document",
    document: ".licoup-workspace.json",
    schemaVersion: 1,
    policy: "current-only",
  }),
  "appearance-presentation": Object.freeze({
    kind: "json-document",
    document: "client-state/appearance-preferences.json",
    schemaVersion: 1,
    policy: "missing-is-legacy",
  }),
  "mobile-relay": Object.freeze({
    kind: "mobile-relay",
    document: "client-state/mobile-relay/config.json",
    schemaVersion: MOBILE_RELAY_SCHEMA_VERSION,
    policy: "current-only",
  }),
  "agent-tab-order": Object.freeze({
    kind: "agent-tab-order",
    document: "client-state/agent-tab-order.json",
    schemaVersion: 1,
    policy: "current-only",
  }),
  "agent-tool-allowlist": Object.freeze({
    kind: "json-document",
    document: "client-state/agent-tool-allowlists.json",
    schemaVersion: 1,
    policy: "current-only",
  }),
  "current-view": Object.freeze({
    kind: "json-document",
    document: "client-state/current-client-view.json",
    schemaVersion: 1,
    policy: "current-only",
  }),
  "mobile-home-layout": Object.freeze({
    kind: "json-document",
    document: "client-state/mobile-home-layout.json",
    schemaVersion: 2,
    policy: "current-only",
  }),
  "skill-hub-preferences": Object.freeze({
    kind: "json-document",
    document: "client-state/skill-hub-preferences.json",
    schemaVersion: 1,
    policy: "current-only",
  }),
});

export function shapeFor(domainId) {
  return DURABLE_SHAPES[domainId] ?? null;
}

export function documentPath(root, shape) {
  return path.join(root, shape.document);
}

/**
 * A repair is only defined when the admission stamps this shape's own schema
 * marker with the frontier's step target. Where the two numbers differ
 * (`mobile-home-layout` stamps 2 for domain version 1) the frontier does not
 * carry the definition, so the step is refused rather than guessed.
 */
export function isRepairableShape(shape, toSchemaVersion) {
  return (
    shape !== null &&
    Number.isInteger(shape.schemaVersion) &&
    shape.schemaVersion === toSchemaVersion &&
    (shape.kind === "json-document" || shape.kind === "agent-tab-order")
  );
}

function jsonDocumentProbe(root, shape) {
  const document = readJsonArtifact(documentPath(root, shape));
  if (document === null) return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
  requireValue(isPlainObject(document), "unsupported_state_shape");
  // Serde reads this field as a `u64`. A string, a float or a negative number
  // is therefore *not* a version at all, which is what makes a document with a
  // non-numeric marker legacy under the `MissingIsLegacy` policy.
  const version = asU64(document.schemaVersion);
  if (version === shape.schemaVersion) {
    return { storeSchemaVersion: 1, present: true, documentSchemaVersion: version };
  }
  if (version === undefined && shape.policy === "missing-is-legacy") {
    return { storeSchemaVersion: 0, present: true, documentSchemaVersion: null };
  }
  if (version !== undefined && version > shape.schemaVersion) {
    throw new MigrationStateError("state_newer_than_binary");
  }
  throw new MigrationStateError("unsupported_state_shape");
}

function agentTabOrderProbe(root, shape) {
  const document = readJsonArtifact(documentPath(root, shape));
  if (document === null) return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
  if (Array.isArray(document)) {
    return { storeSchemaVersion: 0, present: true, documentSchemaVersion: null };
  }
  return jsonDocumentProbe(root, shape);
}

function mobileRelayProbe(root, shape) {
  const document = readJsonArtifact(documentPath(root, shape));
  if (document === null) return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
  requireValue(isPlainObject(document), "unsupported_state_shape");
  const version = asU64(document.schemaVersion);
  // The admission reads the version first and only validates the pairing
  // protocol for a version it knows; a newer document reports `ahead` whatever
  // the protocol says.
  if (version === shape.schemaVersion) {
    requireValue(!protocolIsIncompatible(document), "unsupported_state_shape");
    return { storeSchemaVersion: 1, present: true, documentSchemaVersion: version };
  }
  if (version === 0 || version === 1) {
    requireValue(!protocolIsIncompatible(document), "unsupported_state_shape");
    return { storeSchemaVersion: 0, present: true, documentSchemaVersion: version };
  }
  if (version !== undefined && version > shape.schemaVersion) {
    throw new MigrationStateError("state_newer_than_binary");
  }
  throw new MigrationStateError("unsupported_state_shape");
}

function protocolIsIncompatible(document) {
  const state = document.mobileRelayE2ee;
  if (!isPlainObject(state)) return false;
  const protocol = state.protocolVersion;
  if (typeof protocol !== "string") return false;
  return protocol.trim() !== MOBILE_RELAY_E2EE_PROTOCOL_VERSION;
}

function collectionsProbe(root, shape) {
  const directory = path.join(root, shape.directory);
  let found = false;
  let legacy = false;
  let current = false;
  for (const collection of CLIENT_STATE_COLLECTIONS) {
    const documentPathname = path.join(directory, `${collection}.json`);
    if (!regularFileExists(documentPathname)) continue;
    found = true;
    const document = readJsonArtifact(documentPathname, 16 * 1024 * 1024);
    requireValue(isPlainObject(document), "unsupported_state_shape");
    // The collection marker is a string in the admission, so a numeric one is
    // a legacy document rather than an unknown shape.
    const version = asText(document.schemaVersion);
    if (version === CLIENT_STATE_SCHEMA_VERSION) {
      requireValue(document.collection === collection, "unsupported_state_shape");
      current = true;
      continue;
    }
    if (version === undefined) {
      requireValue(
        document.collection === undefined || document.collection === collection,
        "unsupported_state_shape",
      );
      legacy = true;
      continue;
    }
    throw new MigrationStateError("unsupported_state_shape");
  }
  return {
    storeSchemaVersion: found && !legacy ? 1 : 0,
    present: found,
    documentSchemaVersion: current && !legacy ? CLIENT_STATE_SCHEMA_VERSION : null,
  };
}

function conversationStoreProbe(root) {
  const database = path.join(root, "client-state/conversations/conversations.sqlite3");
  const completion = path.join(root, "client-state/conversations/migration-v5.complete");
  const databasePresent = regularFileExists(database);
  const completionPresent = regularFileExists(completion);
  const legacyPresent = canonicalLegacyStatePresent(root);
  const inner = databasePresent
    ? readSqliteMeta(database, "schema_meta", "version", CONVERSATION_SCHEMA_VERSION)
    : { available: true, value: null, code: null };
  if (inner.code !== null) throw new MigrationStateError(inner.code);
  if (!databasePresent) {
    requireValue(!completionPresent, "unsupported_state_shape");
    return { storeSchemaVersion: 0, present: legacyPresent, documentSchemaVersion: null };
  }
  if (!completionPresent) {
    return { storeSchemaVersion: 0, present: true, documentSchemaVersion: null };
  }
  requireValue(!legacyPresent, "unsupported_state_shape");
  requireValue(
    readBoundedText(completion) === CONVERSATION_COMPLETION_MARKER,
    "unsupported_state_shape",
  );
  return {
    storeSchemaVersion: 1,
    present: true,
    documentSchemaVersion: null,
    unverified: inner.available ? null : "inner_store_schema",
  };
}

function adaptiveFlywheelProbe(root) {
  const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
  if (!regularFileExists(database)) {
    return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
  }
  const inner = readSqliteMeta(database, "strategy_meta", "version", null);
  if (!inner.available) {
    throw new MigrationStateError("unsupported_state_shape");
  }
  if (inner.code !== null) throw new MigrationStateError(inner.code);
  const mapped = ADAPTIVE_FLYWHEEL_SCHEMA_VERSIONS[inner.value];
  if (mapped !== undefined) {
    return { storeSchemaVersion: mapped, present: true, documentSchemaVersion: Number(inner.value) };
  }
  const numeric = Number(inner.value);
  if (Number.isInteger(numeric) && numeric < 2) {
    return { storeSchemaVersion: 0, present: true, documentSchemaVersion: numeric };
  }
  if (Number.isInteger(numeric) && numeric > 3) {
    throw new MigrationStateError("state_newer_than_binary");
  }
  throw new MigrationStateError("unsupported_state_shape");
}

function canonicalLegacyStatePresent(root) {
  const stateRoot = path.join(root, "client-state");
  for (const name of ["agent-conversation-projections.json", "adaptive-flywheel.toml"]) {
    if (regularFileExists(path.join(stateRoot, name))) return true;
  }
  const metadata = lstatSync(path.join(stateRoot, "group-conversations"), {
    throwIfNoEntry: false,
  });
  if (metadata === undefined) return false;
  requireValue(metadata.isDirectory() && !metadata.isSymbolicLink(), "unsupported_state_shape");
  return true;
}

/** A SQLite file is recognised by its header, so garbage is never opened. */
function hasSqliteHeader(pathname) {
  let handle;
  try {
    handle = openSync(pathname, constants.O_RDONLY | constants.O_NOFOLLOW);
  } catch {
    return false;
  }
  try {
    const buffer = Buffer.alloc(SQLITE_HEADER.length);
    const read = readSync(handle, buffer, 0, buffer.length, 0);
    return read === buffer.length && buffer.toString("latin1") === SQLITE_HEADER;
  } catch {
    return false;
  } finally {
    closeSync(handle);
  }
}

let sqliteModule;
let sqliteResolved = false;

function sqliteOrNull() {
  if (!sqliteResolved) {
    sqliteResolved = true;
    try {
      sqliteModule = createRequire(import.meta.url)("node:sqlite");
    } catch {
      sqliteModule = null;
    }
  }
  return sqliteModule;
}

/**
 * Reads a `key`/`value` marker table the way `probe_sqlite_meta` does. When the
 * runtime has no SQLite reader the caller is told the probe is unavailable and
 * decides for itself whether that is a fail-closed condition.
 */
function readSqliteMeta(pathname, table, key, current) {
  const module = sqliteOrNull();
  if (module === null) return { available: false, value: null, code: null };
  if (!hasSqliteHeader(pathname)) {
    return { available: true, value: null, code: "unsupported_state_shape" };
  }
  let database;
  try {
    database = new module.DatabaseSync(pathname, { readOnly: true });
  } catch {
    return { available: true, value: null, code: "unsupported_state_shape" };
  }
  try {
    const row = database.prepare(`SELECT value FROM ${table} WHERE key = ?`).get(key);
    const value = row === undefined || row.value === null ? null : String(row.value);
    if (current === null) {
      return value === null
        ? { available: true, value: null, code: "unsupported_state_shape" }
        : { available: true, value, code: null };
    }
    if (value === current) return { available: true, value, code: null };
    const numeric = Number(value);
    if (Number.isInteger(numeric) && numeric < Number(current)) {
      return { available: true, value, code: null };
    }
    return {
      available: true,
      value,
      code: Number.isInteger(numeric) && numeric > Number(current)
        ? "state_newer_than_binary"
        : "unsupported_state_shape",
    };
  } catch {
    return { available: true, value: null, code: "unsupported_state_shape" };
  } finally {
    database.close();
  }
}

/**
 * Read-only observation of one domain's authoritative store plus its migration
 * marker. `storeSchemaVersion` is the frontier's own domain version, which
 * is not always the store's internal schema marker.
 */
export function probeDomain({ root, domain, platform }) {
  const shape = shapeFor(domain.domainId);
  const base = {
    shape: shape?.kind ?? "unknown",
    storeSchemaVersion: null,
    present: false,
    documentSchemaVersion: null,
    unverified: null,
    code: null,
    markerSchemaVersion: null,
  };
  if (domain.durability === "derived") {
    // A derived domain has no durable store to read; only its marker counts.
    return { ...base, storeSchemaVersion: 0 };
  }
  if (shape === null) {
    // A frontier domain this tool has no durable shape for is never assumed
    // healthy: the admission knows shapes this tool may not.
    return { ...base, code: "unsupported_state_shape" };
  }
  try {
    const observation = probeShape({ root, domain, shape });
    return { ...base, ...observation, code: observation.code ?? null };
  } catch (error) {
    if (error instanceof MigrationStateError) {
      return { ...base, code: error.code };
    }
    throw error;
  }
}

function probeShape({ root, domain, shape, platform }) {
  switch (shape.kind) {
    case "native-custody":
      // The admission never reads custody state at startup: only the explicit
      // protected operation can complete this domain.
      return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
    case "collections":
      return collectionsProbe(root, shape);
    case "conversation-store":
      return conversationStoreProbe(root);
    case "sqlite-meta":
      return adaptiveFlywheelProbe(root);
    case "mobile-relay":
      return mobileRelayProbe(root, shape);
    case "agent-tab-order":
      return agentTabOrderProbe(root, shape);
    case "json-document":
      return jsonDocumentProbe(root, shape);
    default:
      throw new MigrationStateError("unsupported_state_shape");
  }
}
