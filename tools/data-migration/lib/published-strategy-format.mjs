// The published shapes of the strategy database, the conversion graph over
// them, and the recovery artifact a downgrade leaves behind.
//
// The database lives at `client-state/adaptive-flywheel/strategies.sqlite3` and
// has shipped more than one shape. Two rules shape everything here.
//
// 1. **A published format is immutable.** Each descriptor below records a shape
//    that already shipped; a descriptor is never edited into a new shape, and a
//    conversion reads the old shape and writes the next one. The reader asks
//    `sqlite_master` and `PRAGMA table_info` what the file actually holds — it
//    never runs `CREATE TABLE IF NOT EXISTS` to find out, because that answers
//    the question with the answer it just wrote.
// 2. **The tool does not fake a typed migration.** The published writer's own
//    SQLite moves are reproducible here (they are DDL and data movement, no
//    compilation); the workflow-routing move rewrites a workflow document
//    through the compiler, and this tool refuses that edge with a stable code
//    instead of claiming a shape it did not produce.

import { DatabaseSync } from "node:sqlite";
import path from "node:path";
import {
  ensureDirectorySync,
  isRegularFileSync,
  readJsonSync,
  removeFileSync,
  writeJsonAtomicSync,
} from "./fs-atomic.mjs";

export const STRATEGY_DATABASE_REF = "client-state/adaptive-flywheel/strategies.sqlite3";
export const STRATEGY_SCHEMA_ARTIFACT_SCHEMA = "v0.0.1:strategy-store-conversion-artifact-1";
export const STRATEGY_RECOVERY_SCHEMA = "v0.0.1:strategy-store-recovery-1";

/** How many rows of an unrepresentable table a downgrade keeps. */
export const MAX_RECOVERED_ROWS = 4096;

/**
 * The delivery-intent tables the current format adds, exactly as the store
 * crate that owns them publishes them.
 *
 * `tools/data-migration/tests/notice-outbox-ddl-parity.test.mjs` holds this
 * list against that crate's schema source and against the admission's own copy,
 * so a table renamed in one place fails a test instead of drifting.
 */
export const NOTICE_OUTBOX_TABLES = Object.freeze([
  Object.freeze({
    name: "workflow_notice_intents",
    columns: Object.freeze([
      "notice_id",
      "run_id",
      "sequence",
      "recipient",
      "kind",
      "status",
      "created_at",
      "accepted_at",
    ]),
    statements: Object.freeze([
      `CREATE TABLE workflow_notice_intents(
         notice_id TEXT PRIMARY KEY,
         run_id TEXT NOT NULL,
         sequence INTEGER NOT NULL,
         recipient TEXT NOT NULL,
         kind TEXT NOT NULL,
         status TEXT NOT NULL CHECK(status IN ('pending', 'accepted')),
         created_at INTEGER NOT NULL,
         accepted_at INTEGER
       )`,
      `CREATE INDEX workflow_notice_intents_pending_idx
         ON workflow_notice_intents(status, created_at, run_id, sequence, notice_id)`,
    ]),
  }),
  Object.freeze({
    name: "workflow_notice_acceptances",
    columns: Object.freeze([
      "notice_id",
      "run_id",
      "sequence",
      "recipient",
      "kind",
      "accept_count",
      "first_accepted_at",
      "last_accepted_at",
    ]),
    statements: Object.freeze([
      `CREATE TABLE workflow_notice_acceptances(
         notice_id TEXT PRIMARY KEY,
         run_id TEXT NOT NULL,
         sequence INTEGER NOT NULL,
         recipient TEXT NOT NULL,
         kind TEXT NOT NULL,
         accept_count INTEGER NOT NULL,
         first_accepted_at INTEGER NOT NULL,
         last_accepted_at INTEGER NOT NULL
       )`,
    ]),
  }),
]);

const NOTICE_OUTBOX_NAMES = Object.freeze(NOTICE_OUTBOX_TABLES.map((table) => table.name));

/**
 * The publication history of the strategy database, oldest first.
 *
 * `metaVersions` is every value `strategy_meta.version` shipped under; the
 * writer stamped `0` before it stamped `1`, and both are the same shape.
 * `domainSchemaVersion` is the frontier domain version the shape answers to: a
 * shape that only adds tables does not move the domain version, because the
 * rows the frontier versions are the same rows.
 */
export const PUBLISHED_STRATEGY_FORMATS = Object.freeze([
  Object.freeze({
    formatId: "strategy-store-1",
    metaVersions: Object.freeze(["0", "1"]),
    domainSchemaVersion: 0,
    required: Object.freeze([["strategy_meta", Object.freeze(["key", "value"])]]),
    columns: Object.freeze([
      ["strategy_bindings", Object.freeze(["revision_digest", "slot_id", "value_id", "revision"])],
    ]),
    absent: NOTICE_OUTBOX_NAMES,
  }),
  Object.freeze({
    formatId: "strategy-store-2",
    metaVersions: Object.freeze(["2"]),
    domainSchemaVersion: 1,
    required: Object.freeze([["strategy_meta", Object.freeze(["key", "value"])]]),
    columns: Object.freeze([
      [
        "strategy_bindings",
        Object.freeze(["ordinal", "value_id", "model", "reasoning_effort"]),
      ],
    ]),
    absent: NOTICE_OUTBOX_NAMES,
  }),
  Object.freeze({
    formatId: "strategy-store-3",
    metaVersions: Object.freeze(["3"]),
    domainSchemaVersion: 2,
    required: Object.freeze([["strategy_meta", Object.freeze(["key", "value"])]]),
    columns: Object.freeze([
      [
        "strategy_runs",
        Object.freeze(["snapshot_json", "conversation_id", "terminal"]),
      ],
    ]),
    absent: NOTICE_OUTBOX_NAMES,
  }),
  Object.freeze({
    formatId: "strategy-store-4",
    metaVersions: Object.freeze(["3"]),
    domainSchemaVersion: 2,
    required: Object.freeze([
      ["strategy_meta", Object.freeze(["key", "value"])],
      ["workflow_notice_intents", NOTICE_OUTBOX_TABLES[0].columns],
      ["workflow_notice_acceptances", NOTICE_OUTBOX_TABLES[1].columns],
    ]),
    columns: Object.freeze([
      [
        "strategy_runs",
        Object.freeze(["snapshot_json", "conversation_id", "terminal"]),
      ],
    ]),
    absent: Object.freeze([]),
  }),
]);

export function currentStrategyFormat() {
  return PUBLISHED_STRATEGY_FORMATS[PUBLISHED_STRATEGY_FORMATS.length - 1];
}

export function strategyFormatPosition(formatId) {
  const index = PUBLISHED_STRATEGY_FORMATS.findIndex(
    (format) => format.formatId === formatId,
  );
  if (index < 0) throw new Error(`migration_frontier_incomplete: unknown store format ${formatId}`);
  return index;
}

export function strategyFormatForDomainVersion(version) {
  const format = PUBLISHED_STRATEGY_FORMATS.find(
    (candidate) => candidate.domainSchemaVersion === version,
  );
  if (!format) {
    throw new Error(
      `migration_frontier_incomplete: no published store format for domain version ${version}`,
    );
  }
  return format;
}

/**
 * The conversion graph. Each edge names what performs the move, so a caller
 * cannot assume the tool does work it delegates.
 */
export const STRATEGY_STORE_EDGES = Object.freeze([
  Object.freeze({
    stepId: "adaptive-flywheel.strategy-store-ordinal-bindings",
    from: "strategy-store-1",
    to: "strategy-store-2",
    mover: "tool",
  }),
  Object.freeze({
    stepId: "adaptive-flywheel.strategy-store-workflow-routing",
    from: "strategy-store-2",
    to: "strategy-store-3",
    mover: "typed-store",
  }),
  Object.freeze({
    stepId: "adaptive-flywheel.strategy-store-notice-outbox",
    from: "strategy-store-3",
    to: "strategy-store-4",
    mover: "tool",
  }),
]);

/**
 * The unique conversion path from one published shape to another.
 *
 * A shape has exactly one successor, so the path is a property of the graph and
 * not of the caller; a gap is refused rather than bridged by "the newest thing".
 */
export function strategyStorePath(fromFormatId, toFormatId) {
  let cursor = strategyFormatPosition(fromFormatId);
  const target = strategyFormatPosition(toFormatId);
  const path = [];
  while (cursor < target) {
    const current = PUBLISHED_STRATEGY_FORMATS[cursor].formatId;
    const edge = STRATEGY_STORE_EDGES.find((candidate) => candidate.from === current);
    if (!edge) {
      throw new Error(
        `migration_frontier_incomplete: no conversion edge from ${current}`,
      );
    }
    path.push(edge);
    cursor = strategyFormatPosition(edge.to);
  }
  if (cursor !== target) {
    throw new Error(`migration_frontier_incomplete: ${fromFormatId} is ahead of ${toFormatId}`);
  }
  return path;
}

export function strategyDatabasePath(dataRoot) {
  return path.join(dataRoot, STRATEGY_DATABASE_REF);
}

export function strategyStoreArtifactPath(dataRoot) {
  return path.join(
    dataRoot,
    "client-state/migrations/artifacts/adaptive-flywheel-strategy-store.json",
  );
}

/**
 * The conversion record, in the shape the admission reads.
 *
 * One record per store rather than one per tool: the field names and the status
 * vocabulary are the admission's own (`StrategyStoreArtifact`), so a conversion
 * this tool left half-done is resumed by the next admission and one the
 * admission left half-done is finished here. `notice-outbox-ddl-parity.test.mjs`
 * holds the two field sets together.
 */
export function writeStrategyStoreArtifact(
  dataRoot,
  { fromFormat, targetFormat, appliedStepIds, status },
) {
  const artifactPath = strategyStoreArtifactPath(dataRoot);
  ensureDirectorySync(path.dirname(artifactPath));
  writeJsonAtomicSync(artifactPath, {
    schemaVersion: STRATEGY_SCHEMA_ARTIFACT_SCHEMA,
    domainId: "adaptive-flywheel",
    fromFormat,
    targetFormat,
    appliedStepIds: [...appliedStepIds],
    status,
  });
}

export function readStrategyStoreArtifact(dataRoot) {
  const artifact = readJsonSync(strategyStoreArtifactPath(dataRoot));
  if (!artifact || artifact.schemaVersion !== STRATEGY_SCHEMA_ARTIFACT_SCHEMA) return null;
  return artifact;
}

export function strategyRecoveryPath(dataRoot) {
  return path.join(
    dataRoot,
    "client-state/migrations/recovery/adaptive-flywheel-notice-outbox.json",
  );
}

function tableColumns(database, table) {
  try {
    return database
      .prepare(`PRAGMA table_info(${table})`)
      .all()
      .map((row) => String(row.name));
  } catch {
    return [];
  }
}

function hasColumns(database, table, columns) {
  const present = tableColumns(database, table);
  return columns.every((column) => present.includes(column));
}

/**
 * Which published shape a real file holds.
 *
 * Read-only: the file is opened with `readOnly`, and every answer comes from the
 * version row and the tables that are physically there. `null` means no store
 * at all; a shape matching no descriptor is `unsupported_state_shape`, and a
 * version ahead of this tool is `state_newer_than_binary` — the same two codes
 * the native probe returns, so a root cannot be "acceptable" to one and refused
 * by the other.
 */
export function readPublishedFormat(databasePath) {
  if (!isRegularFileSync(databasePath)) return null;
  let database;
  try {
    database = new DatabaseSync(databasePath, { readOnly: true });
  } catch {
    throw new Error(`unsupported_state_shape in adaptive-flywheel`);
  }
  try {
    let version;
    try {
      const row = database
        .prepare("SELECT value FROM strategy_meta WHERE key = ?")
        .get("version");
      version = row === undefined || row === null ? null : String(row.value);
    } catch {
      throw new Error(`unsupported_state_shape in adaptive-flywheel`);
    }
    if (version === null) throw new Error(`unsupported_state_shape in adaptive-flywheel`);
    if (/^\d+$/.test(version)) {
      const newest = Math.max(
        ...currentStrategyFormat().metaVersions.map((candidate) => Number(candidate)),
      );
      if (Number(version) > newest) {
        throw new Error(`state_newer_than_binary in adaptive-flywheel`);
      }
    }
    for (const format of PUBLISHED_STRATEGY_FORMATS) {
      if (!format.metaVersions.includes(version)) continue;
      const required = format.required.every(([table, columns]) =>
        hasColumns(database, table, columns),
      );
      const described = format.columns.every(([table, columns]) => {
        const present = tableColumns(database, table);
        return present.length === 0 || columns.every((column) => present.includes(column));
      });
      const absent = format.absent.every((table) => tableColumns(database, table).length === 0);
      if (required && described && absent) return format;
    }
    throw new Error(`unsupported_state_shape in adaptive-flywheel`);
  } finally {
    database.close();
  }
}

export function readPublishedDomainVersion(databasePath) {
  const format = readPublishedFormat(databasePath);
  return format === null ? 0 : format.domainSchemaVersion;
}

function withDatabase(databasePath, operation) {
  const database = new DatabaseSync(databasePath);
  try {
    database.exec("PRAGMA busy_timeout=5000;");
    database.exec("BEGIN IMMEDIATE");
    try {
      const result = operation(database);
      database.exec("COMMIT");
      return result;
    } catch (error) {
      try {
        database.exec("ROLLBACK");
      } catch {
        // The transaction is already gone; the original error is the report.
      }
      throw error;
    }
  } finally {
    database.close();
  }
}

/**
 * The published writer's ordinal-bindings move.
 *
 * Reproduced from that writer's own SQL rather than inferred: the table is
 * rebuilt with `ordinal` in its primary key, existing rows keep their value and
 * revision and take ordinal 0, and the active authorization flags are cleared
 * because the binding a run was authorized against no longer exists in the old
 * form.
 */
export function applyOrdinalBindings(databasePath) {
  return withDatabase(databasePath, (database) => {
    if (tableColumns(database, "strategy_bindings").includes("ordinal")) {
      return { applied: false, details: "bindings already carry ordinal" };
    }
    const authorizations =
      tableColumns(database, "strategy_authorizations").length > 0
        ? "UPDATE strategy_authorizations SET active=0 WHERE active=1;"
        : "";
    database.exec(
      `CREATE TABLE strategy_bindings_v2 (
         revision_digest TEXT NOT NULL,
         slot_id TEXT NOT NULL,
         ordinal INTEGER NOT NULL,
         value_id TEXT NOT NULL,
         model TEXT NOT NULL DEFAULT '',
         reasoning_effort TEXT NOT NULL DEFAULT '',
         revision INTEGER NOT NULL,
         PRIMARY KEY(revision_digest, slot_id, ordinal)
       );
       INSERT INTO strategy_bindings_v2(
         revision_digest, slot_id, ordinal, value_id, model, reasoning_effort, revision
       )
       SELECT revision_digest, slot_id, 0, value_id, '', '', revision FROM strategy_bindings;
       DROP TABLE strategy_bindings;
       ALTER TABLE strategy_bindings_v2 RENAME TO strategy_bindings;
       ${authorizations}
       UPDATE strategy_meta SET value='2' WHERE key='version';`,
    );
    return { applied: true, details: "rebuilt strategy_bindings with ordinal" };
  });
}

/**
 * The tables the published writer's own schema batch creates in every
 * generation (version 1 through the current one).
 *
 * They are the store's *internal* schema, not the published format table's
 * shape, but they matter for the same reason: the ordinary client open
 * (`StrategyStore::open`) validates the version and creates only the auxiliary
 * queue/subscription/commit/control tables — it does not create these. A store
 * that reaches the current version without them is not a store any published
 * writer produced, and a version move must not be the thing that makes it look
 * like one. A file missing any of them is routed to the native admission, whose
 * open path creates the full schema.
 *
 * `tests/format-authority-differential.test.mjs` holds this list against the
 * tables the real admission leaves behind.
 */
export const PUBLISHED_STORE_CORE_TABLES = Object.freeze([
  "strategy_meta",
  "strategy_definitions",
  "strategy_bindings",
  "strategy_authorizations",
  "strategy_runs",
  "strategy_run_events",
  "strategy_commands",
]);

/**
 * The core tables missing from a published store file, or `[]`.
 *
 * Read-only (`sqlite_master`); a file that cannot be opened is reported as
 * missing everything, so callers refuse rather than guess.
 */
export function missingPublishedCoreTables(databasePath) {
  if (!isRegularFileSync(databasePath)) return [...PUBLISHED_STORE_CORE_TABLES];
  let database;
  try {
    database = new DatabaseSync(databasePath, { readOnly: true });
  } catch {
    return [...PUBLISHED_STORE_CORE_TABLES];
  }
  try {
    const present = new Set(
      database
        .prepare("SELECT name FROM sqlite_master WHERE type='table'")
        .all()
        .map((row) => String(row.name)),
    );
    return PUBLISHED_STORE_CORE_TABLES.filter((table) => !present.has(table));
  } finally {
    database.close();
  }
}

/**
 * What the routing move still needs from the typed owner, or `null` when this
 * tool can reproduce it.
 *
 * The published writer's move to `version = 3` canonicalizes stored workflow
 * documents through the compiler and backfills every run's query columns from
 * its snapshot. Both are typed semantics. The version row on its own says
 * nothing about whether either happened, so a store that has not been through
 * the writer's backfill (no `terminal` column, or rows with `terminal IS NULL`)
 * is not moved by a version flip here: the admission delegates the store to the
 * published writer, which performs both.
 */
export function workflowRoutingNeedsNative(databasePath) {
  if (!isRegularFileSync(databasePath)) return null;
  let database;
  try {
    database = new DatabaseSync(databasePath, { readOnly: true });
  } catch {
    return { reason: "the database is unreadable" };
  }
  try {
    const runColumns = tableColumns(database, "strategy_runs");
    if (runColumns.length === 0) {
      // The published writer's batch creates the run table; a file that does
      // not have it is not a shape this tool's version move can complete.
      return { reason: "strategy_runs is missing from the published shape" };
    }
    if (!runColumns.includes("terminal")) {
      return { reason: "strategy_runs.terminal has not been backfilled" };
    }
    const pending = Number(
      database.prepare("SELECT COUNT(*) AS count FROM strategy_runs WHERE terminal IS NULL")
        .get().count,
    );
    if (pending > 0) {
      return { reason: `${pending} run(s) still need the typed terminal backfill` };
    }
    if (tableColumns(database, "strategy_definitions").length > 0) {
      const definitions = Number(
        database.prepare("SELECT COUNT(*) AS count FROM strategy_definitions").get().count,
      );
      if (definitions > 0) {
        return { reason: `${definitions} workflow document(s) need the workflow compiler` };
      }
    }
    return null;
  } finally {
    database.close();
  }
}

/**
 * The published writer's routing move: `strategy_meta.version` from `2` to `3`.
 *
 * The move also canonicalizes every stored workflow document through the
 * compiler that owns that format and backfills each run's query columns from
 * its snapshot. This tool has neither, so it performs the version move only for
 * a store where both are already done — where the claim is exactly true — and
 * refuses the rest with a stable code for the caller to route to the native
 * admission. Advancing the version over documents that still hold pre-routing
 * conventions would hand a later reader a shape nobody produced.
 */
export function applyWorkflowRouting(databasePath) {
  const blocker = workflowRoutingNeedsNative(databasePath);
  if (blocker !== null) {
    throw new Error(
      `migration_requires_native_admission: workflow routing move: ${blocker.reason}`,
    );
  }
  return withDatabase(databasePath, (database) => {
    const version = database
      .prepare("SELECT value FROM strategy_meta WHERE key = ?")
      .get("version");
    if (version !== undefined && String(version.value) === "3") {
      return { applied: false, details: "routing already published" };
    }
    database.exec("UPDATE strategy_meta SET value='3' WHERE key='version'");
    return { applied: true, details: "published routing version with no definition to canonicalize" };
  });
}

/**
 * The current format's delivery tables, created for real.
 *
 * Empty on purpose. The published format recorded a post-commit obligation as a
 * copy of the committed body and never named a recipient or a kind; the current
 * format's intent carries both. Neither can be derived, and guessing one would
 * create delivery work for a fact nobody addressed — so the legacy rows are left
 * with their owner and no notice is invented.
 */
export function applyNoticeOutbox(databasePath) {
  return withDatabase(databasePath, (database) => {
    for (const table of NOTICE_OUTBOX_TABLES) {
      if (tableColumns(database, table.name).length > 0) {
        throw new Error(
          `migration_step_failed: ${table.name} exists without being the published shape`,
        );
      }
      for (const statement of table.statements) database.exec(statement);
    }
    return { applied: true, details: "created workflow_notice_intents and workflow_notice_acceptances" };
  });
}

/**
 * Reverse the delivery tables out of a store.
 *
 * The published shape cannot express these rows, so they are written to the
 * recovery artifact with the format they came from and the tables are dropped:
 * a downgrade that silently deleted an accepted delivery would lose the only
 * record that the delivery happened.
 */
export function reverseNoticeOutbox(dataRoot, databasePath) {
  const rows = { workflow_notice_intents: [], workflow_notice_acceptances: [] };
  let truncated = false;
  withDatabase(databasePath, (database) => {
    for (const table of NOTICE_OUTBOX_TABLES) {
      if (tableColumns(database, table.name).length === 0) continue;
      const all = database.prepare(`SELECT * FROM ${table.name}`).all();
      const kept = all.slice(0, MAX_RECOVERED_ROWS);
      truncated ||= kept.length < all.length;
      rows[table.name] = kept.map((row) => ({ ...row }));
      database.exec(`DROP TABLE ${table.name}`);
    }
    database.exec("DROP INDEX IF EXISTS workflow_notice_intents_pending_idx");
    return null;
  });
  const artifactPath = strategyRecoveryPath(dataRoot);
  ensureDirectorySync(path.dirname(artifactPath));
  writeJsonAtomicSync(artifactPath, {
    schemaVersion: STRATEGY_RECOVERY_SCHEMA,
    domainId: "adaptive-flywheel",
    fromFormat: currentStrategyFormat().formatId,
    targetFormat: "strategy-store-3",
    savedAt: new Date().toISOString(),
    truncated,
    status: "preserved",
    rows,
  });
  const count = rows.workflow_notice_intents.length + rows.workflow_notice_acceptances.length;
  return {
    applied: count > 0,
    details: `preserved ${count} delivery row(s)${truncated ? " (truncated)" : ""}`,
  };
}

export function loadStrategyRecovery(dataRoot) {
  const artifact = readJsonSync(strategyRecoveryPath(dataRoot));
  if (!artifact || artifact.schemaVersion !== STRATEGY_RECOVERY_SCHEMA) return null;
  return artifact;
}

export function clearStrategyRecovery(dataRoot) {
  removeFileSync(strategyRecoveryPath(dataRoot));
}

/**
 * Re-upgrade merge.
 *
 * Restored rows are inserted with `INSERT OR IGNORE`, never `INSERT OR REPLACE`:
 * an intent or an acceptance recorded *while the store was downgraded* is the
 * newer fact, and a re-upgrade that replaced it would resurrect a delivery that
 * was already accepted — the one thing the plan forbids doing across a
 * downgrade.
 */
export function restoreNoticeOutbox(dataRoot, databasePath) {
  const artifact = loadStrategyRecovery(dataRoot);
  if (artifact === null || artifact.status !== "preserved") {
    return { applied: false, details: "no preserved delivery rows" };
  }
  let restored = 0;
  withDatabase(databasePath, (database) => {
    for (const table of NOTICE_OUTBOX_TABLES) {
      if (tableColumns(database, table.name).length === 0) {
        for (const statement of table.statements) database.exec(statement);
      }
      const rows = artifact.rows?.[table.name] ?? [];
      if (rows.length === 0) continue;
      const columns = table.columns.filter((column) =>
        tableColumns(database, table.name).includes(column),
      );
      const placeholders = columns.map(() => "?").join(", ");
      const statement = database.prepare(
        `INSERT OR IGNORE INTO ${table.name}(${columns.join(", ")}) VALUES (${placeholders})`,
      );
      for (const row of rows) {
        const values = columns.map((column) => (row[column] === undefined ? null : row[column]));
        try {
          statement.run(...values);
          restored += 1;
        } catch {
          // A preserved row this shape cannot store is left in the artifact
          // rather than approximated: the artifact is the record of what the
          // published shape could not hold.
        }
      }
    }
    return null;
  });
  writeJsonAtomicSync(strategyRecoveryPath(dataRoot), { ...artifact, status: "restored" });
  return {
    applied: restored > 0,
    details: `restored ${restored} delivery row(s)`,
  };
}
