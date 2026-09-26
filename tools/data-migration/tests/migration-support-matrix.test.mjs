import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import { convert } from "../lib/convert.mjs";
import { plan } from "../lib/plan.mjs";
import { writeJsonAtomicSync } from "../lib/fs-atomic.mjs";
import { readPublishedFormat } from "../lib/published-strategy-format.mjs";

/**
 * The component-scope support matrix for the migration tool, with the evidence
 * for each row.
 *
 * Three outcomes exist, and they are deliberately distinct:
 *
 * - **converted**: this tool performs the move and verifies the result on the
 *   real file.
 * - **deferred**: the move belongs to the client's own owner (the Conversation
 *   store's legacy import, the strategy store's typed routing move, a store
 *   missing the published writer's schema). The tool reports the domain and
 *   leaves the file exactly as it was; the native startup admission completes
 *   it under its own lock.
 * - **refused**: no published receiver can be shown to read the result, or the
 *   older shape cannot express the rows. Nothing is written — not a journal,
 *   not a marker, not the store — and the caller gets a stable code.
 *
 * What this does not cover: real old client binaries and installed
 * applications. Those are device-level acceptance, outside this tool's scope.
 */

const STRATEGY_STORE = "client-state/adaptive-flywheel/strategies.sqlite3";
const CONVERSATION_STORE = "client-state/conversations/conversations.sqlite3";
const JOURNAL = "client-state/migrations/data-migration-journal.json";
const LEDGER = "client-state/migrations/ledger.json";

const CORE_SQL = `
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

const NOTICE_SQL = `
  CREATE TABLE workflow_notice_intents(
    notice_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, sequence INTEGER NOT NULL,
    recipient TEXT NOT NULL, kind TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('pending','accepted')),
    created_at INTEGER NOT NULL, accepted_at INTEGER
  );
  CREATE TABLE workflow_notice_acceptances(
    notice_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, sequence INTEGER NOT NULL,
    recipient TEXT NOT NULL, kind TEXT NOT NULL, accept_count INTEGER NOT NULL,
    first_accepted_at INTEGER NOT NULL, last_accepted_at INTEGER NOT NULL
  );
  INSERT INTO workflow_notice_intents VALUES
    ('notice-1','run-1',1,'owner-1','kind-1','pending',10,NULL);
`;

function temporaryRoot(label) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `licoup-matrix-${label}-`));
}

function writeStrategyStore(root, { version, ordinal, core = true, extra = "" }) {
  const databasePath = path.join(root, STRATEGY_STORE);
  fs.mkdirSync(path.dirname(databasePath), { recursive: true });
  const bindings = ordinal
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
     ${core ? CORE_SQL : ""}
     ${extra}`,
  );
  database.close();
}

function writeConversationStore(root) {
  const databasePath = path.join(root, CONVERSATION_STORE);
  fs.mkdirSync(path.dirname(databasePath), { recursive: true });
  const database = new DatabaseSync(databasePath);
  database.exec(`
    CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    INSERT INTO schema_meta(key,value) VALUES ('version','17');
    CREATE TABLE conversations(
      id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    );
  `);
  database.close();
  fs.writeFileSync(
    path.join(root, "client-state/conversations/migration-v5.complete"),
    "schema=v5\nstatus=complete\n",
    "utf8",
  );
}

function digest(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function fileDigests(root) {
  const out = {};
  const walk = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) walk(absolute);
      else if (entry.isFile()) out[path.relative(root, absolute)] = digest(absolute);
    }
  };
  walk(root);
  return out;
}

function readLedger(root) {
  const file = path.join(root, LEDGER);
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : null;
}

function strategyVersion(root) {
  const database = new DatabaseSync(path.join(root, STRATEGY_STORE), { readOnly: true });
  try {
    return String(database.prepare("SELECT value FROM strategy_meta WHERE key='version'").get().value);
  } finally {
    database.close();
  }
}

const rows = [
  {
    id: "forward/absent-store",
    setup: (root) => writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["a"]),
    target: "0.0.1-alpha",
    outcome: "converted",
    check: (root) => {
      assert.equal(fs.existsSync(path.join(root, STRATEGY_STORE)), false);
    },
  },
  {
    id: "forward/store-1-empty",
    setup: (root) => writeStrategyStore(root, { version: "1", ordinal: false }),
    target: "0.0.1-alpha",
    outcome: "converted",
    check: (root) => assert.equal(readPublishedFormat(path.join(root, STRATEGY_STORE)).formatId, "strategy-store-4"),
  },
  {
    id: "forward/store-2-with-document",
    setup: (root) =>
      writeStrategyStore(root, {
        version: "2",
        ordinal: true,
        extra: `INSERT INTO strategy_definitions VALUES
          ('definition-1','revision-1','semantics-1','Imported','1','{"schema":"licoup.workflow/1"}',0,1);`,
      }),
    target: "0.0.1-alpha",
    outcome: "deferred",
    check: (root) => assert.equal(readPublishedFormat(path.join(root, STRATEGY_STORE)).formatId, "strategy-store-2"),
  },
  {
    id: "forward/store-2-missing-published-schema",
    setup: (root) => writeStrategyStore(root, { version: "2", ordinal: true, core: false }),
    target: "0.0.1-alpha",
    outcome: "deferred",
    check: (root) => assert.equal(readPublishedFormat(path.join(root, STRATEGY_STORE)).formatId, "strategy-store-2"),
  },
  {
    id: "forward/store-2-unbackfilled-runs",
    setup: (root) =>
      writeStrategyStore(root, {
        version: "2",
        ordinal: true,
        extra: `INSERT INTO strategy_runs VALUES
          ('run-1','revision-1','semantics-1','idempotency-1','request-1',
           '{"status":"running"}','conversation-1',NULL,11,12);`,
      }),
    target: "0.0.1-alpha",
    outcome: "deferred",
    check: (root) => assert.equal(readPublishedFormat(path.join(root, STRATEGY_STORE)).formatId, "strategy-store-2"),
  },
  {
    id: "reverse/store-4-to-v0.3.0",
    setup: (root) => writeStrategyStore(root, { version: "3", ordinal: true, extra: NOTICE_SQL }),
    target: "v0.3.0",
    outcome: "converted",
    check: (root) => {
      assert.equal(readPublishedFormat(path.join(root, STRATEGY_STORE)).formatId, "strategy-store-3");
      const artifact = JSON.parse(
        fs.readFileSync(
          path.join(root, "client-state/migrations/recovery/adaptive-flywheel-notice-outbox.json"),
          "utf8",
        ),
      );
      assert.equal(artifact.status, "preserved");
      assert.equal(artifact.rows.workflow_notice_intents.length, 1);
    },
  },
  {
    id: "reverse/store-3-to-v0.2.1",
    setup: (root) => writeStrategyStore(root, { version: "3", ordinal: true }),
    target: "v0.2.1",
    outcome: "converted",
    check: (root) => {
      assert.equal(readPublishedFormat(path.join(root, STRATEGY_STORE)).formatId, "strategy-store-2");
      assert.equal(strategyVersion(root), "2");
    },
  },
  {
    id: "reverse/store-2-to-v0.1.0",
    setup: (root) => writeStrategyStore(root, { version: "2", ordinal: true }),
    target: "v0.1.0",
    outcome: "refused",
    refusal: /migration_unsupported_downgrade/,
    check: (root) => assert.equal(strategyVersion(root), "2"),
  },
  {
    id: "reverse/conversation-store-to-v0.1.0",
    setup: (root) => writeConversationStore(root),
    target: "v0.1.0",
    outcome: "refused",
    domain: "canonical-conversation",
    refusal: /migration_unsupported_downgrade/,
    check: (root) => assert.ok(fs.existsSync(path.join(root, CONVERSATION_STORE))),
  },
  {
    id: "forward/legacy-conversation-projection",
    setup: (root) =>
      writeJsonAtomicSync(path.join(root, "client-state/agent-conversation-projections.json"), {
        schemaVersion: 1,
        sessionsByAgent: { "agent-one": [{ id: "session-1", title: "Kept" }] },
      }),
    target: "0.0.1-alpha",
    outcome: "deferred",
    domain: "canonical-conversation",
    check: (root) => {
      assert.equal(fs.existsSync(path.join(root, CONVERSATION_STORE)), false);
      assert.ok(fs.existsSync(path.join(root, "client-state/agent-conversation-projections.json")));
    },
  },
];

for (const row of rows) {
  test(`support matrix: ${row.id} is ${row.outcome}`, () => {
    const root = temporaryRoot(row.id.replace(/[/]/gu, "-"));
    const domain = row.domain ?? "adaptive-flywheel";
    try {
      row.setup(root);
      const before = fileDigests(root);
      const storeBefore = before[STRATEGY_STORE] ?? null;

      if (row.outcome === "refused") {
        assert.throws(() => plan(root, row.target), row.refusal);
        assert.throws(() => convert(root, row.target, { writersStopped: true }), row.refusal);
        assert.deepEqual(fileDigests(root), before, "a refusal must write nothing at all");
        row.check(root);
        return;
      }

      const result = convert(root, row.target, { writersStopped: true });
      assert.equal(result.status, "success");

      if (row.outcome === "deferred") {
        assert.ok(
          result.pendingNativeAdmissionDomains.includes(domain),
          `the deferred domain ${domain} must be reported`,
        );
        const storeNow = fs.existsSync(path.join(root, STRATEGY_STORE))
          ? digest(path.join(root, STRATEGY_STORE))
          : null;
        assert.equal(storeNow, storeBefore, "a deferred store must keep its bytes");
        if (domain === "adaptive-flywheel") {
          const ledger = readLedger(root);
          if (ledger?.domains?.["adaptive-flywheel"]) {
            assert.ok(
              ledger.domains["adaptive-flywheel"].schemaVersion <= 1,
              "the ledger must not record a conversion the owner still owes",
            );
          }
        }
      } else {
        assert.equal(
          result.pendingNativeAdmissionDomains.includes(domain),
          false,
          `a converted domain ${domain} must not be reported as pending`,
        );
      }

      row.check(root);
      if (row.outcome === "converted") {
        assert.equal(fs.existsSync(path.join(root, JOURNAL)), false);
        assert.ok(readLedger(root), "a converted run records its ledger");
      }
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
}
