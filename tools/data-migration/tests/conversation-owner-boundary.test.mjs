import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { convert } from "../lib/convert.mjs";
import { plan } from "../lib/plan.mjs";
import { writeJsonAtomicSync } from "../lib/fs-atomic.mjs";
import {
  CURRENT_SQLITE_SCHEMA_VERSION,
  PUBLISHED_STORE_CORE,
  cannotReverse,
  probe,
} from "../lib/codecs/canonical-conversation.mjs";

/**
 * The canonical Conversation store is owned by the client's Conversation
 * crate, and this tool must not fabricate it.
 *
 * What these tests prove: the codec reads the real files and answers with the
 * same refusals the native probe does; a conversion reports the domain as
 * pending native admission and writes no database, no marker and no ledger
 * version for it; and a downgrade that would have to express the store in the
 * legacy shape is refused before anything mutates.
 * What they take as given: that the schema constants below are pinned to the
 * publishing crate by the parity assertions in this file, and that the native
 * admission (exercised by rust-admission-compatibility.test.mjs on a real
 * binary) actually performs the import.
 */

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const storeSourceRef = "crates/licoup-conversation/src/store/mod.rs";

function temporaryRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "licoup-conversation-owner-"));
}

function storePath(root) {
  return path.join(root, "client-state/conversations/conversations.sqlite3");
}

function markerPath(root) {
  return path.join(root, "client-state/conversations/migration-v5.complete");
}

/**
 * A store with the columns every published generation carries. The tool's
 * probe refuses a database without them, so a fixture that only carries a
 * version row is not a valid stand-in.
 */
function writePublishedStore(root, { version = CURRENT_SQLITE_SCHEMA_VERSION, marker = true } = {}) {
  const database = storePath(root);
  fs.mkdirSync(path.dirname(database), { recursive: true });
  const connection = new DatabaseSync(database);
  connection.exec(`
    CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    INSERT INTO schema_meta(key,value) VALUES ('version','${version}');
    CREATE TABLE conversations(
      id TEXT PRIMARY KEY, title TEXT NOT NULL,
      archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)),
      pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)),
      is_group INTEGER NOT NULL DEFAULT 0 CHECK(is_group IN (0,1)),
      strategy_revision TEXT, assistant_membership_id TEXT,
      revision INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    );
  `);
  connection.close();
  if (marker) {
    fs.writeFileSync(markerPath(root), "schema=v5\nstatus=complete\n", "utf8");
  }
}

function writeLegacyProjection(root) {
  writeJsonAtomicSync(path.join(root, "client-state/agent-conversation-projections.json"), {
    schemaVersion: 1,
    sessionsByAgent: {
      "agent-one": [
        { id: "session-1", title: "Preserved", messages: [{ role: "user", content: "canary" }] },
      ],
    },
  });
}

test("the codec classifies real files and refuses shapes it cannot read", () => {
  const root = temporaryRoot();
  try {
    // Absence, and absence with legacy sources.
    assert.deepEqual(probe(root), { version: 0, present: false });
    writeLegacyProjection(root);
    assert.deepEqual(probe(root), { version: 0, present: true });

    // A database without the cutover marker is still the owner's to convert.
    writePublishedStore(root, { marker: false });
    const withoutMarker = probe(root);
    assert.equal(withoutMarker.version, 0);
    assert.equal(withoutMarker.present, true);

    // The completion marker is authoritative for the domain version (the inner
    // SQLite schema advances through the owner's in-store upgrades). Legacy
    // sources and a completed store cannot coexist: that pair is refused, the
    // way the native probe refuses it.
    fs.writeFileSync(markerPath(root), "schema=v5\nstatus=complete\n", "utf8");
    assert.throws(
      () => probe(root),
      /legacy sources and a completed store coexist/,
    );
    fs.rmSync(path.join(root, "client-state/agent-conversation-projections.json"));
    assert.equal(probe(root).version, 1);

    // A marker the published import did not write is not a completion.
    fs.writeFileSync(markerPath(root), "schema=v9\nstatus=complete\n", "utf8");
    assert.throws(() => probe(root), /unsupported_state_shape/);
    fs.rmSync(markerPath(root));

    // A marker without the database is a broken pair.
    fs.rmSync(storePath(root));
    fs.writeFileSync(markerPath(root), "schema=v5\nstatus=complete\n", "utf8");
    assert.throws(() => probe(root), /unsupported_state_shape/);

    // A schema ahead of this tool is refused, never read.
    writePublishedStore(root, { version: "99" });
    assert.throws(() => probe(root), /state_newer_than_binary/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a database that only declares a version is refused as unsupported shape", () => {
  const root = temporaryRoot();
  try {
    const database = storePath(root);
    fs.mkdirSync(path.dirname(database), { recursive: true });
    const connection = new DatabaseSync(database);
    connection.exec(`
      CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO schema_meta(key,value) VALUES ('version','${CURRENT_SQLITE_SCHEMA_VERSION}');
      CREATE TABLE conversations(
        conversation_id TEXT PRIMARY KEY, title TEXT NOT NULL,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
      );
      CREATE TABLE conversation_messages(
        message_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL,
        role TEXT NOT NULL, content TEXT NOT NULL, created_at INTEGER NOT NULL
      );
    `);
    connection.close();
    fs.writeFileSync(markerPath(root), "schema=v5\nstatus=complete\n", "utf8");

    // The native probe refuses the same file (see the Rust unit test
    // `a_fabricated_conversation_store_is_refused_rather_than_admitted`).
    assert.throws(() => probe(root), /unsupported_state_shape/);
    assert.throws(() => plan(root, "v0.3.0"), /unsupported_state_shape/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the forward step is planned, reported and not fabricated", () => {
  const root = temporaryRoot();
  try {
    writeLegacyProjection(root);

    const migrationPlan = plan(root, "0.3.0");
    const step = migrationPlan.steps.find((candidate) => candidate.domainId === "canonical-conversation");
    assert.ok(step, "the frontier step must still be planned");
    assert.equal(step.deferredTo, "native-admission");

    const result = convert(root, "0.3.0", { writersStopped: true });
    assert.equal(result.status, "success");
    assert.ok(result.pendingNativeAdmissionDomains.includes("canonical-conversation"));
    assert.equal(fs.existsSync(storePath(root)), false, "no database may be fabricated");
    assert.equal(fs.existsSync(markerPath(root)), false, "no completion marker may be fabricated");
    assert.ok(
      fs.existsSync(path.join(root, "client-state/agent-conversation-projections.json")),
      "the owner's legacy source must survive for its import",
    );
    const ledger = JSON.parse(
      fs.readFileSync(path.join(root, "client-state/migrations/ledger.json"), "utf8"),
    );
    assert.equal(ledger.domains["canonical-conversation"].schemaVersion, 0);
    assert.deepEqual(ledger.domains["canonical-conversation"].completedStepIds, []);
    assert.equal(
      fs.existsSync(
        path.join(
          root,
          "client-state/migrations/domain-state/canonical-conversation.json",
        ),
      ),
      false,
      "no domain marker may claim a step that was not performed",
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("a downgrade that would need the owner's export is refused before mutating", () => {
  const root = temporaryRoot();
  try {
    writePublishedStore(root, { marker: true });

    assert.equal(cannotReverse, true);
    assert.throws(
      () => plan(root, "v0.1.0"),
      /migration_unsupported_downgrade/,
    );
    assert.throws(
      () => convert(root, "v0.1.0", { writersStopped: true }),
      /migration_unsupported_downgrade/,
    );

    // Old-or-new: the refusal happened before any conversion state exists.
    assert.ok(fs.existsSync(storePath(root)), "the store is untouched");
    assert.equal(
      fs.existsSync(path.join(root, "client-state/migrations/ledger.json")),
      false,
      "no ledger was written for a plan that was refused",
    );
    assert.equal(
      fs.existsSync(path.join(root, "client-state/migrations/data-migration-journal.json")),
      false,
      "no journal was started for a plan that was refused",
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the tool's constants are pinned to the publishing crate", () => {
  const source = fs.readFileSync(path.join(repoRoot, storeSourceRef), "utf8");

  const versionMatch = source.match(/pub const CURRENT_SCHEMA_VERSION: &str = "(\d+)"/u);
  assert.ok(versionMatch, "the publishing crate's CURRENT_SCHEMA_VERSION moved");
  assert.equal(
    CURRENT_SQLITE_SCHEMA_VERSION,
    versionMatch[1],
    "the tool's notion of the current conversation schema is stale",
  );

  for (const { table, columns } of PUBLISHED_STORE_CORE) {
    // Read the published statement as a whole (it may be one line) and drop the
    // nested constraint parentheses before splitting column definitions.
    const statement = new RegExp(
      String.raw`CREATE TABLE IF NOT EXISTS ${table}\s*\(([\s\S]*?)\)\s*;`,
      "u",
    ).exec(source);
    assert.ok(statement, `${table} is not created in the publishing crate`);
    let body = statement[1];
    while (/\([^()]*\)/u.test(body)) {
      body = body.replace(/\([^()]*\)/gu, "");
    }
    const published = body
      .split(",")
      .map((part) => part.trim())
      .filter((part) => part.length > 0)
      .filter((part) => !/^(PRIMARY KEY|UNIQUE|CHECK|FOREIGN KEY)\b/u.test(part))
      .map((part) => part.split(/\s+/u)[0]);
    assert.ok(published.length > 0, `${table}: no published columns were read`);
    for (const column of columns) {
      assert.ok(
        published.includes(column),
        `${table}.${column} is not part of the published table`,
      );
    }
  }
});
