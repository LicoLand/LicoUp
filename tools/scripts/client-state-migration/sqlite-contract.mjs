// Read-only counterpart of Foundation's sqlite_contract. SQL remains owned by
// the stores; fixtures are never imported into the diagnostic implementation.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { MigrationStateError } from "./errors.mjs";
import { requireValue } from "./util.mjs";

const refused = () => { throw new MigrationStateError("unsupported_state_shape"); };
const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);

function memoryDatabase() {
  try {
    const { DatabaseSync } = createRequire(import.meta.url)("node:sqlite");
    return new DatabaseSync(":memory:");
  } catch { throw new MigrationStateError("probe_capability_unavailable"); }
}

export function sqlTokens(sql) {
  const result = [];
  const pattern = /\s+|--[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/|'(?:[^']|'')*'|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]|[\p{L}\p{N}_]+|[^\s]/guy;
  let position = 0;
  while (position < sql.length) {
    pattern.lastIndex = position;
    const match = pattern.exec(sql);
    if (!match) refused();
    position = pattern.lastIndex;
    const token = match[0];
    if (/^(?:\s|--|\/\*)/u.test(token)) continue;
    if (token.startsWith("'")) result.push(token);
    else if (/^["`[]/u.test(token)) {
      const quote = token[0];
      result.push(token.slice(1, -1).replaceAll(quote + quote, quote).toLowerCase());
    } else result.push(token.toLowerCase());
  }
  while (result.at(-1) === ";") result.pop();
  return result;
}

function declarations(sql) {
  const tokens = sqlTokens(sql);
  const using = tokens.indexOf("using");
  if (using !== -1) return [tokens.slice(using)];
  let start = tokens.indexOf("(") + 1;
  if (start === 0) refused();
  let depth = 1;
  const entries = [];
  for (let index = start; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (token === "(") depth += 1;
    else if (token === ")") depth -= 1;
    else if (token === "," && depth === 1) {
      entries.push(tokens.slice(start, index)); start = index + 1;
    }
    if (depth === 0) {
      entries.push(tokens.slice(start, index));
      entries.sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b), "en"));
      entries.push(tokens.slice(index + 1));
      return entries;
    }
  }
  refused();
}

function tableSql(database, table) {
  return database.prepare("SELECT sql FROM sqlite_schema WHERE type='table' AND name=?").get(table)?.sql ?? null;
}

export function tableNames(database) {
  return database.prepare("SELECT name FROM pragma_table_list WHERE schema='main' AND type IN ('table','virtual') AND name NOT LIKE 'sqlite_%' ORDER BY name").all().map((row) => row.name);
}

function indexes(database, table) {
  return database.prepare("SELECT name,sql FROM sqlite_schema WHERE type='index' AND tbl_name=? AND sql IS NOT NULL ORDER BY name").all(table).map((row) => {
    const tokens = sqlTokens(row.sql);
    const index = tokens.findIndex((token, i) => token === "if" && tokens[i + 1] === "not" && tokens[i + 2] === "exists");
    if (index !== -1) tokens.splice(index, 3);
    return [row.name, tokens];
  });
}

export function requireTable(database, reference, table, nullableVariant = null) {
  const sql = tableSql(database, table);
  if (sql === null) refused();
  const expected = declarations(tableSql(reference, table));
  const actual = declarations(sql);
  const columns = (db) => db.prepare("SELECT name,type,\"notnull\",dflt_value,pk,hidden FROM pragma_table_xinfo(?) ORDER BY name").all(table).map((row) => [row.name, row.type.toUpperCase(), Number(row.notnull), row.dflt_value === null ? null : sqlTokens(row.dflt_value), Number(row.pk), Number(row.hidden)]);
  const actualColumns = columns(database);
  const expectedColumns = columns(reference);
  if (nullableVariant !== null && actualColumns.find((row) => row[0] === nullableVariant)?.[2] === 0) {
    expectedColumns.find((row) => row[0] === nullableVariant)[2] = 0;
    const entry = expected.find((entry) => entry[0] === nullableVariant);
    const index = entry.findIndex((token, i) => token === "not" && entry[i + 1] === "null");
    if (index !== -1) entry.splice(index, 2);
  }
  requireValue(same(actual, expected) && same(actualColumns, expectedColumns), "unsupported_state_shape");
  requireValue(same(indexes(database, table), indexes(reference, table)), "unsupported_state_shape");
  requireValue(database.prepare("SELECT count(*) AS count FROM sqlite_schema WHERE type='trigger' AND tbl_name=?").get(table).count === 0, "unsupported_state_shape");
  const owned = tableNames(reference);
  for (const child of tableNames(database)) {
    if (owned.includes(child)) continue;
    requireValue(database.prepare("SELECT count(*) AS count FROM pragma_foreign_key_list(?) WHERE \"table\"=?").get(child, table).count === 0, "unsupported_state_shape");
  }
}

function source(relative) {
  try { return readFileSync(new URL(`../../../${relative}`, import.meta.url), "utf8"); }
  catch { throw new MigrationStateError("probe_capability_unavailable"); }
}

function literal(text, anchor) {
  const at = text.indexOf(anchor);
  const begin = text.lastIndexOf('"', at);
  const end = text.indexOf('"', at);
  if (at === -1 || begin === -1 || end <= begin) throw new MigrationStateError("probe_capability_unavailable");
  return text.slice(begin + 1, end).replaceAll("\\n", "\n").replaceAll('\\"', '"');
}

function functionSource(text, name) {
  const begin = text.indexOf(`fn ${name}(`);
  const next = text.indexOf("\nfn ", begin + 1);
  if (begin === -1) throw new MigrationStateError("probe_capability_unavailable");
  return text.slice(begin, next === -1 ? undefined : next);
}

function ensureColumn(database, table, column, declaration) {
  if (!database.prepare("SELECT name FROM pragma_table_info(?)").all(table).some((row) => row.name === column)) {
    database.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${declaration};`);
  }
}

function ensureColumns(database, text) {
  for (const match of text.matchAll(/ensure_column\(\s*connection,\s*"(\w+)",\s*"(\w+)",\s*"([^"]+)"\s*,?\s*\)/gu)) {
    ensureColumn(database, match[1], match[2], match[3]);
  }
}

function ensureMigrationColumn(database, text, migration, table, column) {
  if (!database.prepare("SELECT name FROM pragma_table_info(?)").all(table).some((row) => row.name === column)) {
    database.exec(literal(functionSource(text, migration), `ALTER TABLE ${table} ADD COLUMN ${column}`));
  }
}

const conversationSource = () => source("crates/licoup-conversation/src/store/schema.rs");
function currentConversationLayout(database, text) {
  database.exec(literal(text, "CREATE TABLE IF NOT EXISTS principals"));
  database.exec(literal(source("crates/licoup-conversation/src/store/native_sessions.rs"), "CREATE TABLE IF NOT EXISTS conversation_native_sessions"));
  const current = functionSource(text, "ensure_current_layout");
  ensureColumns(database, current);
  database.exec(literal(current, "CREATE INDEX IF NOT EXISTS conversation_dispatches_native_provenance_idx"));
  database.exec(literal(text, "DROP INDEX IF EXISTS memberships_active_unique"));
}

function conversationReference() {
  const database = memoryDatabase();
  try {
    const text = conversationSource();
    database.exec(literal(text, "CREATE TABLE IF NOT EXISTS schema_meta"));
    currentConversationLayout(database, text);
    return database;
  } catch (error) { database.close(); throw error; }
}

function copySchema(source) {
  const database = memoryDatabase();
  try {
    const names = new Set(tableNames(source));
    for (const row of source.prepare("SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 WHEN 'trigger' THEN 2 ELSE 3 END").all()) {
      if (row.type === "table" && !names.has(row.name)) continue;
      if (row.type === "trigger") refused();
      database.exec(row.sql);
    }
    return database;
  } catch (error) { database.close(); throw error; }
}

// The structural part of the real owner upgrade. Reads the owner's actual SQL
// statements; data-dependent conversions intentionally remain apply/retry work.
function upgradeConversationLayout(database, version, text) {
  database.exec(literal(text, "CREATE TABLE IF NOT EXISTS principals"));
  if (version <= 4) ensureMigrationColumn(database, text, "migrate_runtime_replay_v5", "event_parts", "runtime_cursor");
  if (version <= 5) ensureMigrationColumn(database, text, "migrate_strategy_selection_v6", "conversations", "strategy_revision");
  if (version <= 6) ensureMigrationColumn(database, text, "migrate_assistant_profile_v7", "conversations", "assistant_membership_id");
  if (version <= 7) {
    const columns = database.prepare("SELECT name FROM pragma_table_info('membership_profiles')").all().map((row) => row.name);
    if (!columns.includes("required_capabilities") || columns.includes("authority")) {
      const migration = functionSource(text, "migrate_profile_intent_v8");
      database.exec(literal(migration, "ALTER TABLE membership_profiles RENAME"));
      database.exec(literal(migration, "DROP TABLE membership_profiles_v7_draft"));
    }
  }
  if (version <= 8) ensureMigrationColumn(database, text, "migrate_profile_reasoning_effort_v9", "membership_profiles", "preferred_reasoning_effort");
  if (version < 12) ensureColumns(database, functionSource(text, "initialize_schema_unchecked"));
  currentConversationLayout(database, text);
}

export function inspectConversationContract(database, currentVersion) {
  const names = tableNames(database);
  if (!names.includes("schema_meta")) {
    if (names.length === 0) return { version: null };
    refused();
  }
  const version = database.prepare("SELECT value FROM schema_meta WHERE key='version'").get()?.value;
  if (version !== currentVersion && !/^(?:[1-9]|10|11|12)$/u.test(version ?? "")) refused();
  const reference = conversationReference();
  let upgraded;
  try {
    if (version !== currentVersion) {
      for (const [table, columns] of [["schema_meta", ["key", "value"]], ["principals", ["id"]], ["conversations", ["id", "title"]], ["memberships", ["id"]], ["events", ["id"]]]) {
        const found = database.prepare("SELECT name FROM pragma_table_info(?)").all(table).map((row) => row.name);
        requireValue(columns.every((column) => found.includes(column)), "unsupported_state_shape");
      }
      upgraded = copySchema(database);
      upgradeConversationLayout(upgraded, Number(version), conversationSource());
    }
    for (const table of tableNames(reference)) requireTable(upgraded ?? database, reference, table);
    return { version };
  } finally { upgraded?.close(); reference.close(); }
}

export function inspectStrategyContract(database) {
  const reference = memoryDatabase();
  try {
    const root = "crates/licoup-native/src/domain/workflow_store/";
    const text = source(`${root}store.rs`);
    reference.exec(literal(text, "CREATE TABLE IF NOT EXISTS strategy_meta"));
    reference.exec(literal(text, "CREATE INDEX IF NOT EXISTS strategy_runs_active_conversation_idx"));
    const required = tableNames(reference);
    for (const [file, anchor] of [["queue", "workflow_store_meta"], ["subscriptions", "workflow_subscriptions"], ["commit", "workflow_transition_intents"], ["control", "workflow_graph_state"]]) {
      reference.exec(literal(source(`${root}${file}.rs`), `CREATE TABLE IF NOT EXISTS ${anchor}`));
    }
    const existing = tableNames(database);
    for (const table of tableNames(reference)) {
      if (!required.includes(table) && !existing.includes(table)) continue;
      requireTable(database, reference, table, table === "strategy_runs" ? "terminal" : null);
    }
  } finally { reference.close(); }
}
