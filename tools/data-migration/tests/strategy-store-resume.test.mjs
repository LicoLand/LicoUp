import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import { convert } from "../lib/convert.mjs";
import { resume } from "../lib/resume.mjs";
import { plan } from "../lib/plan.mjs";
import {
  initJournal,
  markStepCommitted,
  markStoreFormatRunning,
  openJournal,
} from "../lib/journal.mjs";
import { getCodec } from "../lib/codecs/index.mjs";
import { writeJsonAtomicSync } from "../lib/fs-atomic.mjs";
import { RootLock } from "../lib/lock.mjs";
import { readPublishedFormat } from "../lib/published-strategy-format.mjs";

/**
 * The maintenance lock and the recovery artifacts, on the seam this task adds:
 * a store-format step that is not a frontier step.
 *
 * What is proven: an interrupted conversion (a journal naming a store-format
 * step in flight, and a store still in the published shape) is completed by
 * `resume`, and no conversion runs while another owner holds the root lock.
 * What is taken as given: that the lock is this tool's unit of mutual exclusion
 * — cross-process ordering with a running client is the root-access protocol's
 * subject, not this tool's, and the lock file is deliberately not the native
 * `admission.lock`.
 */

function temporaryRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-store-resume-"));
}

/**
 * A store at the current format with the published writer's own schema. A
 * partial file is routed to the native admission, so the lock/resume seam has
 * to be exercised on a shape the tool actually converts.
 */
function writePublishedStore(databasePath) {
  fs.mkdirSync(path.dirname(databasePath), { recursive: true });
  const database = new DatabaseSync(databasePath);
  database.exec(
    `CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
     INSERT INTO strategy_meta(key,value) VALUES ('version','3');
     CREATE TABLE strategy_definitions(
       definition_id TEXT NOT NULL, revision_digest TEXT PRIMARY KEY,
       semantics_digest TEXT NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL,
       workflow_json TEXT NOT NULL, asset_count INTEGER NOT NULL, imported_at INTEGER NOT NULL
     );
     CREATE TABLE strategy_bindings(
       revision_digest TEXT NOT NULL, slot_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
       value_id TEXT NOT NULL, model TEXT NOT NULL DEFAULT '',
       reasoning_effort TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL,
       PRIMARY KEY(revision_digest, slot_id, ordinal)
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
     );`,
  );
  database.close();
}

function seedRoot(root) {
  writeJsonAtomicSync(path.join(root, "client-state/agent-tab-order.json"), ["agent-1"]);
  writePublishedStore(
    path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3"),
  );
  return path.join(root, "client-state/adaptive-flywheel/strategies.sqlite3");
}

test("an interrupted store-format step is resumed from the journal, not repeated", () => {
  const root = temporaryRoot();
  try {
    const database = seedRoot(root);
    const migrationPlan = plan(root, "0.0.1-alpha");
    initJournal(root, migrationPlan);
    // Every frontier step completed, the store-format step still in flight:
    // the state a crash between the two phases leaves behind.
    for (const step of migrationPlan.steps) {
      if (step.domainId === "gateway-credential-custody") {
        // Protected custody needs the platform bridge and is left pending, the
        // same way the admission leaves it awaiting the explicit operation.
        continue;
      }
      if (step.deferredTo === "native-admission") {
        // The Conversation store's step belongs to the client owner; this
        // harness stands in for the tool's own run only.
        continue;
      }
      const codec = getCodec(step.domainId);
      if (step.direction === "forward") {
        codec.forward(root, step.fromVersion, step.toVersion);
      } else {
        codec.reverse(root, step.fromVersion, step.toVersion);
      }
      codec.verifyPostcondition(root, step.toVersion);
      markStepCommitted(root, step.domainId, step.toVersion);
    }
    markStoreFormatRunning(root, "adaptive-flywheel", "adaptive-flywheel.strategy-store-notice-outbox");
    assert.equal(openJournal(root).storeFormats["adaptive-flywheel"].status, "running");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-3");

    const result = resume(root, { writersStopped: true });
    assert.equal(result.status, "success");
    const storeStep = result.resumedSteps.find((step) => step.storeFormat !== undefined);
    assert.equal(storeStep.status, "resumed_and_committed");
    assert.equal(storeStep.storeFormat, "strategy-store-4");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-4");
    assert.equal(openJournal(root), null, "the journal is removed once every step is verified");

    // Resuming again is not a second migration: there is no journal to resume.
    assert.equal(resume(root, { writersStopped: true }).status, "no_op");
    assert.equal(readPublishedFormat(database).formatId, "strategy-store-4");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a conversion is refused while another owner holds the root lock", () => {
  const root = temporaryRoot();
  try {
    seedRoot(root);
    const held = new RootLock(root).acquire();
    try {
      assert.throws(
        () => convert(root, "0.0.1-alpha", { writersStopped: true }),
        /migration_lock_unavailable/,
      );
      assert.throws(() => resume(root, { writersStopped: true }), /migration_lock_unavailable/);
    } finally {
      held.release();
    }
    // The lock is a gate, not a loss: once it is released the same conversion
    // runs to completion.
    const result = convert(root, "0.0.1-alpha", { writersStopped: true });
    assert.equal(result.status, "success");
    assert.equal(result.storeFormatSteps.length, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
