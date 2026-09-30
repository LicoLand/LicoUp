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
// The Conversation owner's own `CURRENT_SCHEMA_VERSION` in
// `crates/licoup-conversation/src/store/mod.rs`.
const CONVERSATION_SCHEMA_VERSION = "18";
const CONVERSATION_COMPLETION_MARKER = "schema=v5\nstatus=complete\n";
export const ADAPTIVE_FLYWHEEL_SCHEMA_VERSIONS = Object.freeze({ "3": 2, "2": 1 });
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

// The Conversation owner's own layout contract in
// `crates/licoup-conversation/src/store/schema.rs`: `validate_current_schema_shape`
// for the current schema, and the owner's released schema-12 layout
// (`validate_released_schema_shape`). A version row on anything less than these
// physical layouts is not a store.
export const CONVERSATION_CURRENT_TABLES = Object.freeze([
  "schema_meta",
  "principals",
  "conversations",
  "memberships",
  "membership_profiles",
  "events",
  "event_parts",
  "direct_turns",
  "event_search",
  "source_links",
  "runtime_bindings",
  "conversation_dispatches",
  "subagent_dispatch_claims",
  "subagent_mcp_inbound",
  "subagent_dispatch_deliveries",
  "migration_provenance",
  "archived_native_sessions",
  "conversation_native_sessions",
]);
export const CONVERSATION_CURRENT_COLUMNS = Object.freeze({
  schema_meta: Object.freeze(["key", "value"]),
  conversations: Object.freeze(["id", "revision", "updated_at"]),
  events: Object.freeze([
    "id",
    "conversation_id",
    "sequence",
    "author_membership_id",
    "correlation_id",
    "kind",
    "finalized",
  ]),
  event_parts: Object.freeze(["event_id", "ordinal", "kind", "content", "created_at"]),
  direct_turns: Object.freeze(["id", "state"]),
  event_search: Object.freeze(["event_id", "conversation_id", "content"]),
  conversation_dispatches: Object.freeze([
    "id",
    "conversation_id",
    "membership_id",
    "state",
    "created_at",
    "error_code",
    "updated_at",
  ]),
  subagent_dispatch_claims: Object.freeze([
    "id",
    "conversation_id",
    "caller_membership_id",
    "state",
    "updated_at",
  ]),
  subagent_dispatch_deliveries: Object.freeze([
    "claim_id",
    "kind",
    "conversation_id",
    "recipient_membership_id",
    "state",
    "terminal_state",
    "payload",
    "attempt_count",
    "created_at",
    "updated_at",
  ]),
});
const CONVERSATION_RELEASED_SCHEMA_VERSION = "12";
export const CONVERSATION_RELEASED_MEMBERSHIP_INDEX = "memberships_principal_unique";
export const CONVERSATION_RELEASED_TABLES = Object.freeze({
  conversation_dispatches: Object.freeze([
    "id",
    "conversation_id",
    "membership_id",
    "operation",
    "state",
    "session_mode",
    "runtime_conversation_path",
    "error_code",
    "created_at",
    "updated_at",
  ]),
  conversations: Object.freeze([
    "id",
    "title",
    "archived",
    "pinned",
    "is_group",
    "strategy_revision",
    "assistant_membership_id",
    "revision",
    "created_at",
    "updated_at",
  ]),
  direct_turns: Object.freeze([
    "id",
    "conversation_id",
    "source_event_id",
    "membership_id",
    "state",
    "ordinal",
  ]),
  event_parts: Object.freeze([
    "id",
    "event_id",
    "ordinal",
    "kind",
    "content",
    "runtime_cursor",
    "created_at",
  ]),
  events: Object.freeze([
    "id",
    "conversation_id",
    "sequence",
    "author_membership_id",
    "kind",
    "causation_id",
    "correlation_id",
    "created_at",
    "finalized",
  ]),
  membership_profiles: Object.freeze([
    "membership_id",
    "revision",
    "responsibility",
    "required_capabilities",
    "preferred_capabilities",
    "skill_references",
    "preferred_model",
    "preferred_reasoning_effort",
    "preferred_environment",
    "updated_at",
  ]),
  memberships: Object.freeze([
    "id",
    "conversation_id",
    "principal_id",
    "access",
    "status",
    "joined_at",
    "left_at",
  ]),
  migration_provenance: Object.freeze(["source_kind", "source_identity", "conversation_id"]),
  principals: Object.freeze(["id", "kind", "display_name", "agent_id", "created_at"]),
  runtime_bindings: Object.freeze([
    "id",
    "conversation_id",
    "membership_id",
    "lane",
    "availability",
    "safe_reason",
    "runtime_session_id",
    "runtime_conversation_path",
    "working_directory",
  ]),
  source_links: Object.freeze(["id", "conversation_id", "source_kind", "native_identity"]),
  subagent_dispatch_claims: Object.freeze([
    "id",
    "conversation_id",
    "caller_membership_id",
    "target_membership_id",
    "parent_dispatch_id",
    "depth",
    "state",
    "created_at",
    "updated_at",
    "watchdog_deadline_unix_ms",
  ]),
  subagent_mcp_inbound: Object.freeze([
    "id",
    "conversation_id",
    "caller_membership_id",
    "target_membership_id",
    "tool",
    "outcome",
    "created_at",
  ]),
});

// The strategy store's exact core layout, mirrored from the owner's
// `validate_published_core_layout` in
// `crates/licoup-native/src/domain/workflow_store/store.rs`. The released
// schema 2 and the current schema 3 create the same seven tables, keys,
// foreign keys and uniqueness constraints; only `strategy_meta.version`
// differs.
export const STRATEGY_CORE_TABLES = Object.freeze([
  Object.freeze({
    name: "strategy_meta",
    columns: Object.freeze([
      ["key", "TEXT", false, 1],
      ["value", "TEXT", true, 0],
    ]),
    foreignKeys: Object.freeze([]),
    uniqueSets: Object.freeze([Object.freeze([Object.freeze(["key"]), false])]),
    indexes: Object.freeze([]),
  }),
  Object.freeze({
    name: "strategy_definitions",
    columns: Object.freeze([
      ["definition_id", "TEXT", true, 0],
      ["revision_digest", "TEXT", false, 1],
      ["semantics_digest", "TEXT", true, 0],
      ["name", "TEXT", true, 0],
      ["version", "TEXT", true, 0],
      ["workflow_json", "TEXT", true, 0],
      ["asset_count", "INTEGER", true, 0],
      ["imported_at", "INTEGER", true, 0],
    ]),
    foreignKeys: Object.freeze([]),
    uniqueSets: Object.freeze([Object.freeze([Object.freeze(["revision_digest"]), false])]),
    indexes: Object.freeze([
      Object.freeze([
        "strategy_definitions_id_idx",
        Object.freeze(["definition_id", "imported_at"]),
        false,
        false,
        "",
      ]),
    ]),
  }),
  Object.freeze({
    name: "strategy_bindings",
    columns: Object.freeze([
      ["revision_digest", "TEXT", true, 1],
      ["slot_id", "TEXT", true, 2],
      ["ordinal", "INTEGER", true, 3],
      ["value_id", "TEXT", true, 0],
      ["model", "TEXT", true, 0],
      ["reasoning_effort", "TEXT", true, 0],
      ["revision", "INTEGER", true, 0],
    ]),
    foreignKeys: Object.freeze([
      Object.freeze(["revision_digest", "strategy_definitions", "revision_digest", "CASCADE"]),
    ]),
    uniqueSets: Object.freeze([
      Object.freeze([
        Object.freeze(["revision_digest", "slot_id", "ordinal"]),
        false,
      ]),
    ]),
    indexes: Object.freeze([]),
  }),
  Object.freeze({
    name: "strategy_authorizations",
    columns: Object.freeze([
      ["revision_digest", "TEXT", true, 1],
      ["revision", "INTEGER", true, 2],
      ["semantics_digest", "TEXT", true, 0],
      ["binding_digest", "TEXT", true, 0],
      ["authorization_digest", "TEXT", true, 0],
      ["active", "INTEGER", true, 0],
      ["created_at", "INTEGER", true, 0],
    ]),
    foreignKeys: Object.freeze([
      Object.freeze(["revision_digest", "strategy_definitions", "revision_digest", "CASCADE"]),
    ]),
    uniqueSets: Object.freeze([
      Object.freeze([Object.freeze(["revision_digest", "revision"]), false]),
      Object.freeze([Object.freeze(["revision_digest"]), true]),
    ]),
    indexes: Object.freeze([
      Object.freeze([
        "strategy_authorization_active_idx",
        Object.freeze(["revision_digest"]),
        true,
        true,
        "WHERE active=1",
      ]),
    ]),
  }),
  Object.freeze({
    name: "strategy_runs",
    columns: Object.freeze([
      ["run_id", "TEXT", false, 1],
      ["revision_digest", "TEXT", true, 0],
      ["semantics_digest", "TEXT", true, 0],
      ["idempotency_key", "TEXT", true, 0],
      ["request_digest", "TEXT", true, 0],
      ["snapshot_json", "TEXT", true, 0],
      ["conversation_id", "TEXT", false, 0],
      ["terminal", "INTEGER", true, 0],
      ["created_at", "INTEGER", true, 0],
      ["updated_at", "INTEGER", true, 0],
    ]),
    foreignKeys: Object.freeze([
      Object.freeze([
        "revision_digest",
        "strategy_definitions",
        "revision_digest",
        "NO ACTION",
      ]),
    ]),
    uniqueSets: Object.freeze([
      Object.freeze([Object.freeze(["run_id"]), false]),
      Object.freeze([Object.freeze(["idempotency_key"]), false]),
    ]),
    indexes: Object.freeze([
      Object.freeze([
        "strategy_runs_revision_idx",
        Object.freeze(["revision_digest", "updated_at"]),
        false,
        false,
        "",
      ]),
      Object.freeze([
        "strategy_runs_active_conversation_idx",
        Object.freeze(["revision_digest", "conversation_id", "terminal", "updated_at"]),
        false,
        false,
        "",
      ]),
    ]),
  }),
  Object.freeze({
    name: "strategy_run_events",
    columns: Object.freeze([
      ["run_id", "TEXT", true, 1],
      ["sequence", "INTEGER", true, 2],
      ["event_type", "TEXT", true, 0],
      ["event_json", "TEXT", true, 0],
      ["created_at", "INTEGER", true, 0],
    ]),
    foreignKeys: Object.freeze([
      Object.freeze(["run_id", "strategy_runs", "run_id", "CASCADE"]),
    ]),
    uniqueSets: Object.freeze([
      Object.freeze([Object.freeze(["run_id", "sequence"]), false]),
    ]),
    indexes: Object.freeze([]),
  }),
  Object.freeze({
    name: "strategy_commands",
    columns: Object.freeze([
      ["command_id", "TEXT", false, 1],
      ["run_id", "TEXT", true, 0],
      ["state_id", "TEXT", true, 0],
      ["kind", "TEXT", true, 0],
      ["status", "TEXT", true, 0],
      ["attempt", "INTEGER", true, 0],
      ["attempt_token", "TEXT", true, 0],
      ["command_json", "TEXT", true, 0],
      ["lease_owner", "TEXT", false, 0],
      ["lease_until", "INTEGER", false, 0],
      ["updated_at", "INTEGER", true, 0],
    ]),
    foreignKeys: Object.freeze([
      Object.freeze(["run_id", "strategy_runs", "run_id", "CASCADE"]),
    ]),
    uniqueSets: Object.freeze([
      Object.freeze([Object.freeze(["command_id"]), false]),
    ]),
    indexes: Object.freeze([
      Object.freeze([
        "strategy_commands_ready_idx",
        Object.freeze(["status", "command_id"]),
        false,
        false,
        "",
      ]),
      Object.freeze([
        "strategy_commands_lease_idx",
        Object.freeze(["lease_until"]),
        false,
        true,
        "WHERE status IN ('claimed', 'running')",
      ]),
    ]),
  }),
]);

const STRATEGY_CORE_FORMATS = Object.freeze(
  Object.fromEntries(
    Object.entries(ADAPTIVE_FLYWHEEL_SCHEMA_VERSIONS).map(([version, domainVersion]) => [
      version,
      Object.freeze({ domainSchemaVersion: domainVersion }),
    ]),
  ),
);

function withReadOnlyDatabase(pathname, callback) {
  const module = sqliteOrNull();
  if (module === null) throw new MigrationStateError("probe_capability_unavailable");
  if (!hasSqliteHeader(pathname)) throw new MigrationStateError("unsupported_state_shape");
  let database;
  try {
    database = new module.DatabaseSync(pathname, { readOnly: true });
  } catch {
    throw new MigrationStateError("unsupported_state_shape");
  }
  try {
    return callback(database);
  } finally {
    database.close();
  }
}

function sqliteTableNames(database) {
  return new Set(
    database
      .prepare("SELECT name FROM sqlite_schema WHERE type='table'")
      .all()
      .map((row) => String(row.name)),
  );
}

function sqliteColumns(database, table) {
  return new Set(
    database
      .prepare(`PRAGMA table_info(${table})`)
      .all()
      .map((row) => String(row.name)),
  );
}

function sqliteTableInfo(database, table) {
  return database.prepare(`PRAGMA table_info(${table})`).all().map((row) => ({
    name: String(row.name),
    type: String(row.type ?? ""),
    notNull: Number(row.notnull) !== 0,
    pk: Number(row.pk),
  }));
}

function sqliteForeignKeys(database, table) {
  return database
    .prepare(`PRAGMA foreign_key_list(${table})`)
    .all()
    .map((row) => [
      String(row.from),
      String(row.table),
      String(row.to ?? ""),
      String(row.on_delete),
    ]);
}

function sqliteIndexList(database, table) {
  return database.prepare(`PRAGMA index_list(${table})`).all().map((row) => ({
    name: String(row.name),
    unique: Number(row.unique) !== 0,
    partial: Number(row.partial ?? 0) !== 0,
  }));
}

function sqliteIndexColumns(database, indexName) {
  const rows = database.prepare(`PRAGMA index_info(${indexName})`).all();
  if (rows.some((row) => row.name === null || row.name === undefined)) {
    throw new MigrationStateError("unsupported_state_shape");
  }
  return rows.map((row) => String(row.name));
}

function stableKey(value) {
  return JSON.stringify(value);
}

function inspectConversationLayout(database) {
  const tables = sqliteTableNames(database);
  if (!tables.has("schema_meta")) {
    if (tables.size === 0) return { version: null };
    throw new MigrationStateError("unsupported_state_shape");
  }
  const row = database.prepare("SELECT value FROM schema_meta WHERE key='version'").get();
  if (row === undefined || row.value === null) {
    throw new MigrationStateError("unsupported_state_shape");
  }
  const version = String(row.value);
  if (version === CONVERSATION_SCHEMA_VERSION) {
    if (!CONVERSATION_CURRENT_TABLES.every((table) => tables.has(table))) {
      throw new MigrationStateError("unsupported_state_shape");
    }
    for (const [table, columns] of Object.entries(CONVERSATION_CURRENT_COLUMNS)) {
      const present = sqliteColumns(database, table);
      if (!columns.every((column) => present.has(column))) {
        throw new MigrationStateError("unsupported_state_shape");
      }
    }
    return { version };
  }
  if (version === CONVERSATION_RELEASED_SCHEMA_VERSION) {
    for (const [table, columns] of Object.entries(CONVERSATION_RELEASED_TABLES)) {
      const present = sqliteColumns(database, table);
      if (columns.some((column) => !present.has(column))) {
        throw new MigrationStateError("unsupported_state_shape");
      }
    }
    const membership = database
      .prepare("SELECT 1 FROM sqlite_schema WHERE type='index' AND name=?")
      .get(CONVERSATION_RELEASED_MEMBERSHIP_INDEX);
    if (membership === undefined) throw new MigrationStateError("unsupported_state_shape");
    return { version };
  }
  if (/^(?:[1-9]|10|11)$/u.test(version)) return { version };
  throw new MigrationStateError("unsupported_state_shape");
}

function requireStrategyCoreLayout(database, expectedVersion) {
  const row = database.prepare("SELECT value FROM strategy_meta WHERE key='version'").get();
  if (row === undefined || row.value === null || String(row.value) !== expectedVersion) {
    throw new MigrationStateError("unsupported_state_shape");
  }
  for (const table of STRATEGY_CORE_TABLES) {
    const info = sqliteTableInfo(database, table.name);
    if (info.length !== table.columns.length) {
      throw new MigrationStateError("unsupported_state_shape");
    }
    for (const [name, type, notNull, pk] of table.columns) {
      const column = info.find((entry) => entry.name === name);
      if (
        column === undefined ||
        column.type.toUpperCase() !== type ||
        column.notNull !== notNull ||
        column.pk !== pk
      ) {
        throw new MigrationStateError("unsupported_state_shape");
      }
    }
    const actualForeignKeys = sqliteForeignKeys(database, table.name).sort((left, right) =>
      stableKey(left) < stableKey(right) ? -1 : 1,
    );
    const expectedForeignKeys = table.foreignKeys
      .map((entry) => [...entry])
      .sort((left, right) => (stableKey(left) < stableKey(right) ? -1 : 1));
    if (stableKey(actualForeignKeys) !== stableKey(expectedForeignKeys)) {
      throw new MigrationStateError("unsupported_state_shape");
    }
    const listed = sqliteIndexList(database, table.name);
    const actualUniqueSets = listed
      .filter((index) => index.unique)
      .map((index) => [sqliteIndexColumns(database, index.name), index.partial])
      .sort((left, right) => (stableKey(left) < stableKey(right) ? -1 : 1));
    const expectedUniqueSets = table.uniqueSets
      .map(([columns, partial]) => [[...columns], partial])
      .sort((left, right) => (stableKey(left) < stableKey(right) ? -1 : 1));
    if (stableKey(actualUniqueSets) !== stableKey(expectedUniqueSets)) {
      throw new MigrationStateError("unsupported_state_shape");
    }
    const named = listed
      .filter((index) => !index.name.startsWith("sqlite_autoindex_"))
      .map((index) => index.name)
      .sort();
    const expectedNames = table.indexes.map((index) => index[0]).sort();
    if (stableKey(named) !== stableKey(expectedNames)) {
      throw new MigrationStateError("unsupported_state_shape");
    }
    for (const [name, columns, unique, partial, predicate] of table.indexes) {
      const entry = listed.find((index) => index.name === name);
      if (entry === undefined || entry.unique !== unique || entry.partial !== partial) {
        throw new MigrationStateError("unsupported_state_shape");
      }
      if (stableKey(sqliteIndexColumns(database, name)) !== stableKey([...columns])) {
        throw new MigrationStateError("unsupported_state_shape");
      }
      if (predicate !== "") {
        const sqlRow = database
          .prepare("SELECT sql FROM sqlite_master WHERE type='index' AND name=?")
          .get(name);
        const normalized =
          sqlRow === undefined || sqlRow.sql === null
            ? ""
            : String(sqlRow.sql).split(/\s+/u).join(" ");
        if (!normalized.includes(predicate)) {
          throw new MigrationStateError("unsupported_state_shape");
        }
      }
    }
  }
}

function conversationStoreProbe(root) {
  const database = path.join(root, "client-state/conversations/conversations.sqlite3");
  const completion = path.join(root, "client-state/conversations/migration-v5.complete");
  const databasePresent = regularFileExists(database);
  const completionPresent = regularFileExists(completion);
  const legacyPresent = canonicalLegacyStatePresent(root);
  if (!databasePresent) {
    requireValue(!completionPresent, "unsupported_state_shape");
    return { storeSchemaVersion: 0, present: legacyPresent, documentSchemaVersion: null };
  }
  const layout = withReadOnlyDatabase(database, (connection) =>
    inspectConversationLayout(connection),
  );
  if (!completionPresent) {
    return { storeSchemaVersion: 0, present: true, documentSchemaVersion: null };
  }
  requireValue(!legacyPresent, "unsupported_state_shape");
  requireValue(
    readBoundedText(completion) === CONVERSATION_COMPLETION_MARKER,
    "unsupported_state_shape",
  );
  // The completion marker is written only after a store existed at a published
  // inner schema. Older published schemas (1..11) remain documented migration
  // sources the owner upgrades; a marker over a versionless file is not a
  // store at all.
  requireValue(layout.version !== null, "unsupported_state_shape");
  return { storeSchemaVersion: 1, present: true, documentSchemaVersion: null };
}

function adaptiveFlywheelProbe(root) {
  const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
  if (!regularFileExists(database)) {
    return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
  }
  return withReadOnlyDatabase(database, (connection) => {
    const row = connection.prepare("SELECT value FROM strategy_meta WHERE key='version'").get();
    if (row === undefined || row.value === null) {
      throw new MigrationStateError("unsupported_state_shape");
    }
    const version = String(row.value);
    const format = STRATEGY_CORE_FORMATS[version];
    if (format !== undefined) {
      requireStrategyCoreLayout(connection, version);
      return {
        storeSchemaVersion: format.domainSchemaVersion,
        present: true,
        documentSchemaVersion: Number(version),
      };
    }
    const numeric = Number(version);
    if (Number.isInteger(numeric) && numeric > 3) {
      throw new MigrationStateError("state_newer_than_binary");
    }
    // Legacy stamps (0/1) are not a published layout this tool recognizes, and
    // neither is a malformed version: both are refused rather than mapped to a
    // version.
    throw new MigrationStateError("unsupported_state_shape");
  });
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
