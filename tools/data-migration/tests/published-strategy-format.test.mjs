import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import {
  PUBLISHED_STRATEGY_FORMATS,
  STRATEGY_STORE_EDGES,
  currentStrategyFormat,
  readPublishedDomainVersion,
  readPublishedFormat,
  strategyFormatForDomainVersion,
  strategyFormatPosition,
  strategyStorePath,
} from "../lib/published-strategy-format.mjs";
import { convert } from "../lib/convert.mjs";
import { plan } from "../lib/plan.mjs";
import { writeJsonAtomicSync } from "../lib/fs-atomic.mjs";

/**
 * What these tests prove, and what they take as given:
 *
 * - The codec classifies real files. Every fixture is a database written here,
 *   so the shapes are copies of the published column lists rather than the
 *   published column lists themselves; `notice-outbox-ddl-parity.test.mjs` is
 *   what holds those copies against the sources that publish them.
 * - The conversion graph is a property of the published history: one successor
 *   per shape, every shape reaching the current one.
 * - A whole-root conversion leaves the file in the current shape and writes a
 *   domain version the admission can still read. That is asserted against this
 *   tool's own ledger, not against the Rust admission — the cross-language
 *   agreement is `rust-admission-compatibility.test.mjs`.
 */

function temporaryRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-published-format-"));
}

/**
 * The store's own schema, as the published writer's batch creates it in every
 * generation. A fixture without it is not a shape any writer left behind, and
 * the tool routes such a file to the native admission instead of moving a
 * version row over it.
 */
const PUBLISHED_CORE_SQL = `
  CREATE TABLE strategy_definitions(
    definition_id TEXT NOT NULL, revision_digest TEXT PRIMARY KEY,
    semantics_digest TEXT NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL,
    workflow_json TEXT NOT NULL, asset_count INTEGER NOT NULL, imported_at INTEGER NOT NULL
  );
  CREATE TABLE strategy_authorizations(
    revision_digest TEXT NOT NULL, revision INTEGER NOT NULL,
    semantics_digest TEXT NOT NULL, binding_digest TEXT NOT NULL,
    authorization_digest TEXT NOT NULL, active INTEGER NOT NULL, created_at INTEGER NOT NULL,
    PRIMARY KEY(revision_digest, revision)
  );
  CREATE TABLE strategy_runs(
    run_id TEXT PRIMARY KEY, revision_digest TEXT NOT NULL,
    semantics_digest TEXT NOT NULL, idempotency_key TEXT NOT NULL UNIQUE,
    request_digest TEXT NOT NULL, snapshot_json TEXT NOT NULL,
    conversation_id TEXT, terminal INTEGER,
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
  );
  CREATE TABLE strategy_run_events(
    run_id TEXT NOT NULL, sequence INTEGER NOT NULL, event_type TEXT NOT NULL,
    event_json TEXT NOT NULL, created_at INTEGER NOT NULL,
    PRIMARY KEY(run_id, sequence)
  );
  CREATE TABLE strategy_commands(
    command_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, state_id TEXT NOT NULL,
    kind TEXT NOT NULL, status TEXT NOT NULL, attempt INTEGER NOT NULL,
    attempt_token TEXT NOT NULL, command_json TEXT NOT NULL,
    lease_owner TEXT, lease_until INTEGER, updated_at INTEGER NOT NULL
  );
`;

/**
 * A store as one published writer left it. The bindings table carries `ordinal`
 * exactly where the publication history says it does: a fixture that claims one
 * shape while holding another is not a published format at all, and the codec is
 * supposed to refuse it. `core: false` builds a partial file on purpose, to
 * check that such a file is routed to the owner rather than version-moved.
 */
function writeStore(databasePath, version, extra = "", { core = true } = {}) {
  fs.mkdirSync(path.dirname(databasePath), { recursive: true });
  fs.rmSync(databasePath, { force: true });
  const withOrdinal = version === "2" || version === "3";
  const bindings = withOrdinal
    ? `CREATE TABLE strategy_bindings(
         revision_digest TEXT NOT NULL, slot_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
         value_id TEXT NOT NULL, model TEXT NOT NULL DEFAULT '',
         reasoning_effort TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL,
         PRIMARY KEY(revision_digest, slot_id, ordinal)
       );`
    : `CREATE TABLE strategy_bindings(
         revision_digest TEXT NOT NULL, slot_id TEXT NOT NULL, value_id TEXT NOT NULL,
         revision INTEGER NOT NULL, PRIMARY KEY(revision_digest, slot_id)
       );`;
  const database = new DatabaseSync(databasePath);
  database.exec(
    `CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
     INSERT INTO strategy_meta(key,value) VALUES ('version','${version}');
     ${bindings}
     ${core ? PUBLISHED_CORE_SQL : ""}
     ${extra}`,
  );
  database.close();
}

/** Every stored value in the file, so "unchanged" is a comparison of rows. */
function storedValues(databasePath) {
  const database = new DatabaseSync(databasePath, { readOnly: true });
  try {
    const tables = database
      .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
      .all()
      .map((row) => String(row.name))
      .filter((name) => !name.startsWith("sqlite_"));
    const values = [];
    for (const table of tables) {
      for (const row of database.prepare(`SELECT * FROM ${table}`).all()) {
        values.push(`${table}:${JSON.stringify(row, Object.keys(row).sort())}`);
      }
    }
    values.sort();
    return values;
  } finally {
    database.close();
  }
}

test("published store formats are an immutable, connected publication history", () => {
  const current = currentStrategyFormat();
  assert.equal(current.formatId, "strategy-store-4");
  // A shape is never edited into a new shape: its version row is a record of
  // what shipped, and the newest shape is the last entry.
  assert.deepEqual(
    PUBLISHED_STRATEGY_FORMATS.map((format) => format.formatId),
    ["strategy-store-1", "strategy-store-2", "strategy-store-3", "strategy-store-4"],
  );
  for (const format of PUBLISHED_STRATEGY_FORMATS) {
    const successors = STRATEGY_STORE_EDGES.filter((edge) => edge.from === format.formatId);
    assert.ok(successors.length <= 1, `${format.formatId} has an ambiguous successor`);
    const path_ = strategyStorePath(format.formatId, current.formatId);
    assert.equal(
      path_.length === 0 ? format.formatId : path_[path_.length - 1].to,
      current.formatId,
    );
  }
  assert.throws(
    () => strategyStorePath("strategy-store-9", current.formatId),
    /migration_frontier_incomplete/,
  );
  // Domain versions are one numbering with the shapes, and a shape that only
  // adds tables does not move the domain version — that is why the delivery
  // tables can arrive without the ledger changing.
  assert.equal(strategyFormatForDomainVersion(2).formatId, "strategy-store-3");
  assert.equal(current.domainSchemaVersion, 2);
});

test("the codec reads the shape a real file holds, and refuses what it cannot read", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    assert.equal(readPublishedFormat(database), null);

    writeStore(database, "2");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-2");
    assert.equal(readPublishedDomainVersion(database), 1);

    writeStore(database, "3");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-3");
    assert.equal(readPublishedDomainVersion(database), 2);

    // The two shapes that share version '3' are told apart by the tables that
    // are physically there, not by the version row.
    const database3 = new DatabaseSync(database);
    database3.exec(
      `CREATE TABLE workflow_notice_intents(
         notice_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, sequence INTEGER NOT NULL,
         recipient TEXT NOT NULL, kind TEXT NOT NULL,
         status TEXT NOT NULL CHECK(status IN ('pending','accepted')),
         created_at INTEGER NOT NULL, accepted_at INTEGER
       );
       CREATE TABLE workflow_notice_acceptances(
         notice_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, sequence INTEGER NOT NULL,
         recipient TEXT NOT NULL, kind TEXT NOT NULL, accept_count INTEGER NOT NULL,
         first_accepted_at INTEGER NOT NULL, last_accepted_at INTEGER NOT NULL
       );`,
    );
    database3.close();
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-4");

    // A shape whose tables are not the published ones matches no descriptor:
    // the reader answers with the shape it can verify, or refuses.
    const partial = path.join(root, "partial.sqlite3");
    writeStore(partial, "3", "CREATE TABLE workflow_notice_intents(notice_id TEXT PRIMARY KEY);");
    assert.throws(() => readPublishedFormat(partial), /unsupported_state_shape/);

    const ahead = path.join(root, "ahead.sqlite3");
    writeStore(ahead, "9");
    assert.throws(() => readPublishedFormat(ahead), /state_newer_than_binary/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a whole-root conversion leaves the store in the current shape", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    writeStore(database, "3");
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);

    const migrationPlan = plan(root, "0.0.1-alpha");
    assert.deepEqual(
      migrationPlan.storeFormatSteps.map((step) => [step.stepId, step.direction]),
      [["adaptive-flywheel.strategy-store-notice-outbox", "forward"]],
      "the delivery tables are planned as a store-format step, not a frontier step",
    );
    assert.ok(
      !migrationPlan.steps.some((step) => step.domainId === "adaptive-flywheel"),
      "the delivery tables do not move the domain version the ledger records",
    );

    const result = convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(result.status, "success");
    assert.equal(result.storeFormatSteps.length, 1);
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-4");

    const ledger = JSON.parse(
      fs.readFileSync(path.join(root, "client-state/migrations/ledger.json"), "utf8"),
    );
    assert.equal(ledger.domains["adaptive-flywheel"].schemaVersion, 2);

    // Idempotent: a second conversion plans nothing and changes nothing.
    assert.equal(plan(root, "0.0.1-alpha").storeFormatSteps.length, 0);
    convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-4");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a downgrade preserves delivery rows the published shape cannot express", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    writeStore(database, "3");
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);
    convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-4");

    // A delivery the current format recorded, and a second fact recorded while
    // the store is downgraded. The re-upgrade must keep both, and must not
    // resurrect the accepted one as pending.
    const database4 = new DatabaseSync(database);
    database4.exec(
      `INSERT INTO workflow_notice_intents(
         notice_id, run_id, sequence, recipient, kind, status, created_at, accepted_at
       ) VALUES ('notice-1','run-1',1,'owner-1','kind-1','pending',10,NULL);`,
    );
    database4.close();

    // v0.3.0 is the profile that shipped without the delivery tables.
    const downgrade = convert(root, "v0.3.0", { writersStopped: true });
    assert.equal(downgrade.status, "success");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-3");
    assert.equal(readPublishedDomainVersion(database), 2);
    assert.ok(
      downgrade.storeFormatSteps.some((step) => step.direction === "reverse"),
      "the reverse step must be executed, not merely planned",
    );
    const artifact = JSON.parse(
      fs.readFileSync(
        path.join(
          root,
          "client-state/migrations/recovery/adaptive-flywheel-notice-outbox.json",
        ),
        "utf8",
      ),
    );
    assert.equal(artifact.status, "preserved");
    assert.equal(artifact.rows.workflow_notice_intents.length, 1);
    assert.equal(artifact.rows.workflow_notice_intents[0].notice_id, "notice-1");
    assert.equal(artifact.truncated, false);

    // Re-upgrade merges the preserved row back rather than dropping it.
    const upgrade = convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(upgrade.status, "success");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-4");
    const database5 = new DatabaseSync(database, { readOnly: true });
    const restored = database5
      .prepare("SELECT notice_id, status FROM workflow_notice_intents")
      .all()
      .map((row) => [row.notice_id, row.status]);
    database5.close();
    assert.deepEqual(restored, [["notice-1", "pending"]]);
    const resolved = JSON.parse(
      fs.readFileSync(
        path.join(
          root,
          "client-state/migrations/recovery/adaptive-flywheel-notice-outbox.json",
        ),
        "utf8",
      ),
    );
    assert.equal(resolved.status, "restored");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("an absent store stays absent: the tool does not fabricate one", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);

    const migrationPlan = plan(root, "0.0.1-alpha");
    assert.ok(
      !migrationPlan.steps.some((step) => step.domainId === "adaptive-flywheel" && step.deferredTo),
      "store absence is a state the tool can reconcile",
    );
    assert.equal(
      migrationPlan.storeFormatSteps.length,
      0,
      "there is no file shape to move when the store does not exist",
    );

    const result = convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(result.status, "success");
    assert.equal(fs.existsSync(database), false, "no partial database may be created");
    assert.equal(result.storeFormatSteps.length, 0);

    // The domain version still advances: absence is represented by version 0
    // and the immutable absent-to-1 step is reconciled without a store, the
    // same way the native admission reconciles it.
    const ledger = JSON.parse(
      fs.readFileSync(path.join(root, "client-state/migrations/ledger.json"), "utf8"),
    );
    assert.equal(ledger.domains["adaptive-flywheel"].schemaVersion, 2);
    assert.equal(ledger.domains["adaptive-flywheel"].completedStepIds.length, 2);

    // A later run still finds nothing to do to the file.
    const second = convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(second.status, "success");
    assert.equal(fs.existsSync(database), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a marker ahead of the store is refused instead of papered over", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    writeStore(
      database,
      "2",
      `INSERT INTO strategy_definitions VALUES
         ('definition-1','revision-1','semantics-1','Imported','1','{"legacy":true}',0,1);`,
    );
    // A marker claiming a version the file does not hold is a discrepancy the
    // probe refuses: accepting it would let a later run skip the conversion
    // that never happened.
    writeJsonAtomicSync(
      path.join(root, "client-state/migrations/domain-state/adaptive-flywheel.json"),
      {
        schemaVersion: "v0.0.1:client-state-domain-marker-1",
        domainId: "adaptive-flywheel",
        authoritativeSchemaVersion: 2,
      },
    );
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);

    assert.throws(
      () => convert(root, "0.0.1-alpha", { writersStopped: true }),
      /unsupported_state_shape/,
    );
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-2");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a store missing the published core schema is deferred rather than version-flipped", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    writeStore(
      database,
      "1",
      `INSERT INTO strategy_bindings(revision_digest, slot_id, value_id, revision)
         VALUES ('revision-1','worker','agent:one',3);`,
      { core: false },
    );
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);

    // The ordinary client open validates the version and creates only the
    // auxiliary tables; a file without the published writer's own schema needs
    // the writer's open path, not a version move that would leave the current
    // shape without tables its readers query.
    const result = convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(result.status, "success");
    assert.ok(result.pendingNativeAdmissionDomains.includes("adaptive-flywheel"));
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-1");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("an old-format store is converted through the writer's own moves, not a version flip", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    writeStore(
      database,
      "1",
      `INSERT INTO strategy_bindings(revision_digest, slot_id, value_id, revision)
         VALUES ('revision-1','worker','agent:one',3);
       INSERT INTO strategy_runs VALUES
         ('run-1','revision-1','semantics-1','idempotency-1','request-1',
          '{"status":"completed"}','conversation-1',1,11,12);
       CREATE TABLE undeclared_canary(value TEXT NOT NULL);
       INSERT INTO undeclared_canary(value) VALUES ('must-survive');`,
    );
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);

    convert(root, "0.0.1-alpha", { writersStopped: true });

    const connection = new DatabaseSync(database, { readOnly: true });
    const binding = connection
      .prepare("SELECT ordinal, value_id, model, reasoning_effort, revision FROM strategy_bindings")
      .get();
    const canary = connection.prepare("SELECT value FROM undeclared_canary").get().value;
    connection.close();
    assert.deepEqual(
      [binding.ordinal, binding.value_id, binding.model, binding.reasoning_effort, binding.revision],
      [0, "agent:one", "", "", 3],
      "the ordinal-bindings move keeps the binding, not just the version row",
    );
    assert.equal(canary, "must-survive");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-4");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a store holding workflow documents is deferred to the native owner", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    writeStore(
      database,
      "2",
      `INSERT INTO strategy_definitions VALUES
         ('definition-1','revision-1','semantics-1','Imported','1','{"legacy":true}',0,1);`,
    );
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);

    // The routing move canonicalizes stored documents through the workflow
    // compiler. This tool has no compiler, so the domain is planned and
    // reported as pending native admission and the file is left exactly where
    // it is — a version row without the typed move behind it would be the
    // "describe a migration instead of running one" this refusal prevents.
    const result = convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(result.status, "success");
    assert.ok(
      result.pendingNativeAdmissionDomains.includes("adaptive-flywheel"),
      "the domain must be reported, not silently skipped",
    );
    const deferred = result.convertedSteps.find((step) => step.domainId === "adaptive-flywheel");
    assert.equal(deferred, undefined, "a deferred step is not a converted step");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-2");

    const matrix = JSON.parse(
      fs.readFileSync(path.join(root, "client-state/migrations/ledger.json"), "utf8"),
    );
    assert.equal(
      matrix.domains["adaptive-flywheel"].schemaVersion,
      1,
      "the ledger records what the store is, not what the owner will make it",
    );
    assert.equal(
      matrix.domains["adaptive-flywheel"].completedStepIds.length,
      1,
      "only the absent-to-1 prefix is complete",
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the version-2 downgrade changes the version row and nothing else", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    writeStore(
      database,
      "3",
      `INSERT INTO strategy_definitions VALUES
         ('definition-1','revision-1','semantics-1','Imported','1','{"schema":"licoup.workflow/1"}',0,1);
       INSERT INTO strategy_bindings VALUES
         ('revision-1','worker',0,'agent:one','','',3);
       INSERT INTO strategy_runs VALUES
         ('run-1','revision-1','semantics-1','idempotency-1','request-1',
          '{"status":"completed"}','conversation-1',1,11,12);`,
    );
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);

    const before = storedValues(database);
    const definitionsBefore = new DatabaseSync(database, { readOnly: true })
      .prepare("SELECT revision_digest, workflow_json FROM strategy_definitions ORDER BY revision_digest")
      .all();
    const downgrade = convert(root, "v0.2.1", { writersStopped: true });
    assert.equal(downgrade.status, "success");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-2");
    assert.equal(readPublishedDomainVersion(database), 1);

    // The version-2 writer stored compiled definitions and its reader parsed
    // `WorkflowDefinition` (see the codec's reverse() doc comment), so the move
    // is the version row alone: every document and every row is byte-identical,
    // and nothing is parked in a preservation area.
    const after = storedValues(database);
    const versionRowBefore = `${"strategy_meta"}:${JSON.stringify({ key: "version", value: "3" }, ["key", "value"])}`;
    const versionRowAfter = `${"strategy_meta"}:${JSON.stringify({ key: "version", value: "2" }, ["key", "value"])}`;
    assert.deepEqual(
      after.filter((value) => value !== versionRowAfter),
      before.filter((value) => value !== versionRowBefore),
      "only the version row may differ",
    );
    const definitionsAfter = new DatabaseSync(database, { readOnly: true })
      .prepare("SELECT revision_digest, workflow_json FROM strategy_definitions ORDER BY revision_digest")
      .all();
    assert.deepEqual(definitionsAfter, definitionsBefore);
    assert.equal(
      fs.existsSync(path.join(root, "client-state/migrations/preservation")),
      false,
      "a downgrade that loses nothing must not claim a preservation record",
    );

    // Re-upgrading is the published writer's routing move, not this tool's: the
    // tool reports the domain and the native admission drives the store.
    const upgrade = convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.ok(upgrade.pendingNativeAdmissionDomains.includes("adaptive-flywheel"));
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-2");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a version-1 downgrade of an existing store is refused with zero writes", () => {
  const root = temporaryRoot();
  try {
    const database = path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
    writeStore(
      database,
      "2",
      `INSERT INTO strategy_definitions VALUES
         ('definition-1','revision-1','semantics-1','Imported','1','{"schema":"licoup.workflow/1"}',0,1);
       INSERT INTO strategy_runs VALUES
         ('run-1','revision-1','semantics-1','idempotency-1','request-1',
          '{"status":"completed"}','conversation-1',1,11,12);`,
    );
    writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);
    const before = storedValues(database);

    // The version-1 shape has no ordinal bindings and no run/event/command
    // tables, so expressing this store in it would drop data; there is no
    // published downgrade and no receiver to verify one against. Refused before
    // the journal, the ledger or the store is touched.
    assert.throws(
      () => plan(root, "v0.1.0"),
      /migration_unsupported_downgrade/,
    );
    assert.throws(
      () => convert(root, "v0.1.0", { writersStopped: true }),
      /migration_unsupported_downgrade/,
    );
    assert.deepEqual(storedValues(database), before, "the store must be untouched");
    assert.equal(
      fs.existsSync(path.join(root, "client-state/migrations/data-migration-journal.json")),
      false,
    );
    assert.equal(fs.existsSync(path.join(root, "client-state/migrations/ledger.json")), false);
    assert.equal(
      fs.existsSync(
        path.join(root, "client-state/migrations/domain-state/adaptive-flywheel.json"),
      ),
      false,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
