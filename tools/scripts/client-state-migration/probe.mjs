import { closeSync, constants, lstatSync, openSync, readSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

import { MigrationStateError } from "./errors.mjs";
import { REPO_ROOT } from "./frontier.mjs";
import { inspectConversationContract, inspectStrategyContract } from "./sqlite-contract.mjs";
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

/** Platform-owner projection; Node's platform names are only transport aliases. */
export function gatewayCredentialMigrationDisposition(platform) {
  const platformId = ({ darwin: "macos", win32: "windows" })[platform] ?? platform;
  const policy = readJsonArtifact(path.join(REPO_ROOT, "crates/licoup-native/resources/gateway-credential-migration.json"));
  const disposition = policy?.[platformId];
  requireValue(["requires-authorization", "not-applicable"].includes(disposition), "probe_capability_unavailable");
  return disposition;
}

// The diagnostic contract test compares these domain constants to the owners.
const CLIENT_STATE_SCHEMA_VERSION = "v0.0.1:schema:definition-1";
const CLIENT_STATE_COLLECTIONS = Object.freeze([
  "settings", "targets", "target-discovery-cache", "pairings", "skills", "pins",
  "identities", "conversation-archive-profiles", "agent-usage-reports",
  "provider-quota-snapshots", "skill-usage", "collaboration-plugins",
  "local-server-assemblies", "local-server-assembly-cleanup",
  "local-server-assembly-transaction", "mcp-install-transactions",
]);
const CONVERSATION_SCHEMA_VERSION = "18";
const CONVERSATION_COMPLETION_MARKER = "schema=v5\nstatus=complete\n";
export const ADAPTIVE_FLYWHEEL_SCHEMA_VERSIONS = Object.freeze({ "3": 2, "2": 1 });
const MOBILE_RELAY_SCHEMA_VERSION = 2;
const MOBILE_RELAY_E2EE_PROTOCOL_VERSION = "licomesh.mobile-relay.e2ee.pqxdh-mlkem1024.v1";
const SQLITE_HEADER = `SQLite format 3${String.fromCharCode(0)}`;

/** Domain documents and their own schema markers, not store-internal versions. */
export const DURABLE_SHAPES = Object.freeze({
  "gateway-credential-custody": Object.freeze({ kind: "native-custody" }),
  "client-state": Object.freeze({ kind: "collections", directory: "client-state" }),
  "canonical-conversation": Object.freeze({ kind: "conversation-store" }),
  "adaptive-flywheel": Object.freeze({ kind: "sqlite-meta" }),
  "workspace-manifest": Object.freeze({ kind: "json-document", document: ".licoup-workspace.json", schemaVersion: 1, policy: "current-only" }),
  "appearance-presentation": Object.freeze({ kind: "json-document", document: "client-state/appearance-preferences.json", schemaVersion: 1, policy: "missing-is-legacy" }),
  "mobile-relay": Object.freeze({ kind: "mobile-relay", document: "client-state/mobile-relay/config.json", schemaVersion: MOBILE_RELAY_SCHEMA_VERSION, policy: "current-only" }),
  "agent-tab-order": Object.freeze({ kind: "agent-tab-order", document: "client-state/agent-tab-order.json", schemaVersion: 1, policy: "current-only" }),
  "agent-tool-allowlist": Object.freeze({ kind: "json-document", document: "client-state/agent-tool-allowlists.json", schemaVersion: 1, policy: "current-only" }),
  "current-view": Object.freeze({ kind: "json-document", document: "client-state/current-client-view.json", schemaVersion: 1, policy: "current-only" }),
  "mobile-home-layout": Object.freeze({ kind: "json-document", document: "client-state/mobile-home-layout.json", schemaVersion: 2, policy: "current-only" }),
  "skill-hub-preferences": Object.freeze({ kind: "json-document", document: "client-state/skill-hub-preferences.json", schemaVersion: 1, policy: "current-only" }),
});

export function shapeFor(domainId) {
  return DURABLE_SHAPES[domainId] ?? null;
}

export function documentPath(root, shape) {
  return path.join(root, shape.document);
}

/** The frontier can repair only shapes whose document and domain versions agree. */
export function isRepairableShape(shape, toSchemaVersion) {
  return shape !== null && Number.isInteger(shape.schemaVersion) &&
    shape.schemaVersion === toSchemaVersion &&
    (shape.kind === "json-document" || shape.kind === "agent-tab-order");
}

function jsonDocumentProbe(root, shape) {
  const document = readJsonArtifact(documentPath(root, shape));
  if (document === null) return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
  requireValue(isPlainObject(document), "unsupported_state_shape");
  const version = asU64(document.schemaVersion);
  if (version === shape.schemaVersion) return { storeSchemaVersion: 1, present: true, documentSchemaVersion: version };
  if (version === undefined && shape.policy === "missing-is-legacy") return { storeSchemaVersion: 0, present: true, documentSchemaVersion: null };
  if (version !== undefined && version > shape.schemaVersion) throw new MigrationStateError("state_newer_than_binary");
  throw new MigrationStateError("unsupported_state_shape");
}

function agentTabOrderProbe(root, shape) {
  const document = readJsonArtifact(documentPath(root, shape));
  if (document === null) return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
  if (Array.isArray(document)) return { storeSchemaVersion: 0, present: true, documentSchemaVersion: null };
  return jsonDocumentProbe(root, shape);
}

function mobileRelayProbe(root, shape) {
  const document = readJsonArtifact(documentPath(root, shape));
  if (document === null) return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
  requireValue(isPlainObject(document), "unsupported_state_shape");
  const version = asU64(document.schemaVersion);
  if (version === shape.schemaVersion || version === 0 || version === 1) {
    requireValue(!protocolIsIncompatible(document), "unsupported_state_shape");
    return { storeSchemaVersion: version === shape.schemaVersion ? 1 : 0, present: true, documentSchemaVersion: version };
  }
  if (version !== undefined && version > shape.schemaVersion) throw new MigrationStateError("state_newer_than_binary");
  throw new MigrationStateError("unsupported_state_shape");
}

function protocolIsIncompatible(document) {
  const state = document.mobileRelayE2ee;
  if (!isPlainObject(state)) return false;
  const protocol = state.protocolVersion;
  return typeof protocol === "string" && protocol.trim() !== MOBILE_RELAY_E2EE_PROTOCOL_VERSION;
}

function collectionsProbe(root, shape) {
  const directory = path.join(root, shape.directory);
  let found = false;
  let legacy = false;
  let current = false;
  for (const collection of CLIENT_STATE_COLLECTIONS) {
    const pathname = path.join(directory, `${collection}.json`);
    if (!regularFileExists(pathname)) continue;
    found = true;
    const document = readJsonArtifact(pathname, 16 * 1024 * 1024);
    requireValue(isPlainObject(document), "unsupported_state_shape");
    const version = asText(document.schemaVersion);
    if (version === CLIENT_STATE_SCHEMA_VERSION) {
      requireValue(document.collection === collection, "unsupported_state_shape");
      current = true;
    } else if (version === undefined) {
      requireValue(document.collection === undefined || document.collection === collection, "unsupported_state_shape");
      legacy = true;
    } else throw new MigrationStateError("unsupported_state_shape");
  }
  return { storeSchemaVersion: found && !legacy ? 1 : 0, present: found, documentSchemaVersion: current && !legacy ? CLIENT_STATE_SCHEMA_VERSION : null };
}

function withReadOnlyDatabase(pathname, callback) {
  let module;
  try { module = createRequire(import.meta.url)("node:sqlite"); }
  catch { throw new MigrationStateError("probe_capability_unavailable"); }
  if (!hasSqliteHeader(pathname)) throw new MigrationStateError("unsupported_state_shape");
  let database;
  try { database = new module.DatabaseSync(pathname, { readOnly: true }); }
  catch { throw new MigrationStateError("unsupported_state_shape"); }
  try {
    return callback(database);
  } catch (error) {
    // Inspection failures belong to this domain and never erase sibling reports.
    if (error instanceof MigrationStateError) throw error;
    throw new MigrationStateError("unsupported_state_shape");
  } finally { database.close(); }
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
  const layout = withReadOnlyDatabase(database, (connection) => inspectConversationContract(connection, CONVERSATION_SCHEMA_VERSION));
  if (!completionPresent) return { storeSchemaVersion: 0, present: true, documentSchemaVersion: null };
  requireValue(layout.version !== null && !legacyPresent, "unsupported_state_shape");
  requireValue(readBoundedText(completion) === CONVERSATION_COMPLETION_MARKER, "unsupported_state_shape");
  return { storeSchemaVersion: 1, present: true, documentSchemaVersion: null };
}

function adaptiveFlywheelProbe(root) {
  const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
  if (!regularFileExists(database)) return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
  return withReadOnlyDatabase(database, (connection) => {
    const row = connection.prepare("SELECT value FROM strategy_meta WHERE key='version'").get();
    if (row === undefined || row.value === null) throw new MigrationStateError("unsupported_state_shape");
    const version = String(row.value);
    const domainVersion = ADAPTIVE_FLYWHEEL_SCHEMA_VERSIONS[version];
    if (domainVersion !== undefined) {
      inspectStrategyContract(connection);
      return { storeSchemaVersion: domainVersion, present: true, documentSchemaVersion: Number(version) };
    }
    const numeric = Number(version);
    if (Number.isInteger(numeric) && numeric > 3) throw new MigrationStateError("state_newer_than_binary");
    throw new MigrationStateError("unsupported_state_shape");
  });
}

function canonicalLegacyStatePresent(root) {
  const stateRoot = path.join(root, "client-state");
  for (const name of ["agent-conversation-projections.json", "adaptive-flywheel.toml"]) {
    if (regularFileExists(path.join(stateRoot, name))) return true;
  }
  const metadata = lstatSync(path.join(stateRoot, "group-conversations"), { throwIfNoEntry: false });
  if (metadata === undefined) return false;
  requireValue(metadata.isDirectory() && !metadata.isSymbolicLink(), "unsupported_state_shape");
  return true;
}

function hasSqliteHeader(pathname) {
  let handle;
  try { handle = openSync(pathname, constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch { return false; }
  try {
    const buffer = Buffer.alloc(SQLITE_HEADER.length);
    const read = readSync(handle, buffer, 0, buffer.length, 0);
    return read === buffer.length && buffer.toString("latin1") === SQLITE_HEADER;
  } catch { return false; }
  finally { closeSync(handle); }
}

/** Read-only observation of one domain, retaining a bounded refusal on failure. */
export function probeDomain({ root, domain }) {
  const shape = shapeFor(domain.domainId);
  const base = { shape: shape?.kind ?? "unknown", storeSchemaVersion: null, present: false, documentSchemaVersion: null, unverified: null, code: null, markerSchemaVersion: null };
  if (domain.durability === "derived") return { ...base, storeSchemaVersion: 0 };
  if (shape === null) return { ...base, code: "unsupported_state_shape" };
  try {
    const observation = probeShape({ root, shape });
    return { ...base, ...observation, code: observation.code ?? null };
  } catch (error) {
    if (error instanceof MigrationStateError) return { ...base, code: error.code };
    throw error;
  }
}

function probeShape({ root, shape }) {
  switch (shape.kind) {
    case "native-custody": return { storeSchemaVersion: 0, present: false, documentSchemaVersion: null };
    case "collections": return collectionsProbe(root, shape);
    case "conversation-store": return conversationStoreProbe(root);
    case "sqlite-meta": return adaptiveFlywheelProbe(root);
    case "mobile-relay": return mobileRelayProbe(root, shape);
    case "agent-tab-order": return agentTabOrderProbe(root, shape);
    case "json-document": return jsonDocumentProbe(root, shape);
    default: throw new MigrationStateError("unsupported_state_shape");
  }
}
