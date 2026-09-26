import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { convert } from "../lib/convert.mjs";
import { plan } from "../lib/plan.mjs";
import {
  PUBLISHED_STORE_CORE_TABLES,
  readPublishedFormat,
} from "../lib/published-strategy-format.mjs";

/**
 * The JS codec and the real native admission must agree about what a store is
 * and about what converting it produces.
 *
 * This is a *differential* over real outputs, not a name comparison: the same
 * published fixture is converted twice — once by this tool, once by
 * `licoup-cli state admit`, which is the Rust format authority — and the two
 * results are compared on the facts a format descriptor actually claims
 * (`strategy_meta.version`, the format-defining tables and their columns, the
 * notice-table rows) plus the recovery artifact the admission itself writes.
 * Where the tool defers a domain to the owner, the fixture is instead checked
 * to be unchanged and the owner's artifact is checked to name the same format
 * the JS reader named.
 *
 * What this does not prove: that either side is right about the published
 * history (that is the fixture's own contract), or anything about a receiver
 * this repository no longer contains.
 */

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const nativeCli = path.join(
  repoRoot,
  "build",
  "crates",
  "licoup-native",
  "target",
  "debug",
  "licoup-cli",
);

const STORE = "client-state/adaptive-flywheel/strategies.sqlite3";
const ARTIFACT = "client-state/migrations/artifacts/adaptive-flywheel-strategy-store.json";

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

function temporaryRoot(label) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `licoup-format-diff-${label}-`));
}

function writeStore(root, version, { ordinal, extra = "" }) {
  const databasePath = path.join(root, STORE);
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
     ${CORE_SQL}
     ${extra}`,
  );
  database.close();
  return databasePath;
}

/**
 * The facts the published descriptors claim, read back out of the file: the
 * version row, the format-defining tables' column sets, and the delivery rows.
 */
function fingerprint(root) {
  const database = new DatabaseSync(path.join(root, STORE), { readOnly: true });
  try {
    const columns = (table) =>
      database
        .prepare(`PRAGMA table_info(${table})`)
        .all()
        .map((row) => String(row.name))
        .sort();
    const tableExists = (table) =>
      Boolean(
        database
          .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?")
          .get(table),
      );
    const count = (table) =>
      tableExists(table)
        ? Number(database.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get().count)
        : 0;
    const canaryTable = tableExists("undeclared_canary");
    return {
      version: String(
        database.prepare("SELECT value FROM strategy_meta WHERE key='version'").get()?.value,
      ),
      bindings: columns("strategy_bindings"),
      runs: columns("strategy_runs"),
      notices: columns("workflow_notice_intents"),
      acceptances: columns("workflow_notice_acceptances"),
      noticeRows: count("workflow_notice_intents"),
      acceptanceRows: count("workflow_notice_acceptances"),
      canary: canaryTable
        ? String(database.prepare("SELECT value FROM undeclared_canary").get().value)
        : null,
    };
  } finally {
    database.close();
  }
}

function nativeAdmit(root) {
  const proc = spawnSync(nativeCli, ["state", "admit", root], {
    encoding: "utf8",
    timeout: 60_000,
  });
  assert.equal(proc.status, 0, `licoup-cli failed: ${proc.stderr}`);
  return JSON.parse(proc.stdout.trim());
}

function nativeArtifact(root) {
  const file = path.join(root, ARTIFACT);
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : null;
}

test("the tool and the native admission agree on every published store fixture", (t) => {
  if (!fs.existsSync(nativeCli)) {
    t.skip(`Native binary not compiled at ${nativeCli}`);
    return;
  }

  const fixtures = [
    {
      label: "store-3",
      build: (root) =>
        writeStore(root, "3", {
          ordinal: true,
          extra: `INSERT INTO strategy_runs VALUES
            ('run-1','revision-1','semantics-1','idempotency-1','request-1',
             '{"status":"completed"}','conversation-1',1,11,12);`,
        }),
      toolAction: "convert",
      expectedFrom: "strategy-store-3",
    },
    {
      label: "store-1-empty",
      // The version-1 bindings shape with no rows: the ordinal rebuild is a
      // shape move here, and a canary table checks that neither side drops what
      // it does not know. (A binding row would need a definition row for the
      // native rebuild's foreign key, and a definition row routes the domain to
      // the native owner by design — that case is the store-2 fixture.)
      build: (root) =>
        writeStore(root, "1", {
          ordinal: false,
          extra: `CREATE TABLE undeclared_canary(value TEXT NOT NULL);
                  INSERT INTO undeclared_canary(value) VALUES ('must-survive');`,
        }),
      toolAction: "convert",
      expectedFrom: "strategy-store-1",
    },
    {
      label: "store-2-with-document",
      build: (root) =>
        writeStore(root, "2", {
          ordinal: true,
          extra: `INSERT INTO strategy_definitions VALUES
            ('definition-1','revision-1','semantics-1','Imported','1',
             '{"schema":"licoup.workflow/1"}',0,1);`,
        }),
      toolAction: "defer",
      expectedFrom: "strategy-store-2",
    },
    {
      label: "store-4",
      build: (root) =>
        writeStore(root, "3", {
          ordinal: true,
          extra: `CREATE TABLE workflow_notice_intents(
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
                    ('notice-1','run-1',1,'owner-1','kind-1','pending',10,NULL);`,
        }),
      toolAction: "none",
      expectedFrom: "strategy-store-4",
    },
  ];

  for (const fixture of fixtures) {
    const toolRoot = temporaryRoot(`${fixture.label}-tool`);
    const nativeRoot = temporaryRoot(`${fixture.label}-native`);
    try {
      fixture.build(toolRoot);
      fixture.build(nativeRoot);
      const fixtureFormat = readPublishedFormat(path.join(toolRoot, STORE)).formatId;
      assert.equal(
        fixtureFormat,
        fixture.expectedFrom,
        `${fixture.label}: the fixture is not the shape it claims`,
      );

      // The tool side: convert what it can, defer the rest.
      const toolPlan = plan(toolRoot, "0.0.1-alpha");
      const toolResult = convert(toolRoot, "0.0.1-alpha", { writersStopped: true });
      const deferred = toolResult.pendingNativeAdmissionDomains.includes("adaptive-flywheel");

      // The native side: the real admission drives the store through its own
      // codec, whatever the tool decided.
      const admission = nativeAdmit(nativeRoot);
      const artifact = nativeArtifact(nativeRoot);
      assert.ok(
        admission.appliedDomainIds.includes("adaptive-flywheel") ||
          admission.skippedDomainIds.includes("adaptive-flywheel"),
        `${fixture.label}: the admission did not account for the domain`,
      );
      assert.equal(
        readPublishedFormat(path.join(nativeRoot, STORE)).formatId,
        "strategy-store-4",
        `${fixture.label}: the native admission must reach the current format`,
      );
      // The tool's "published writer's own schema" list is not a second format
      // authority: every table it names must be one the real admission's own
      // conversion leaves behind.
      const nativeDatabase = new DatabaseSync(path.join(nativeRoot, STORE), { readOnly: true });
      let nativeTables;
      try {
        nativeTables = new Set(
          nativeDatabase
            .prepare("SELECT name FROM sqlite_master WHERE type='table'")
            .all()
            .map((row) => String(row.name)),
        );
      } finally {
        nativeDatabase.close();
      }
      for (const table of PUBLISHED_STORE_CORE_TABLES) {
        assert.ok(
          nativeTables.has(table),
          `${fixture.label}: the admission's store is missing ${table}, so the tool's list is wrong`,
        );
      }

      if (fixture.toolAction === "convert") {
        assert.equal(deferred, false, `${fixture.label}: the tool must convert this shape`);
        assert.ok(
          toolPlan.storeFormatSteps.length +
            toolPlan.steps.filter((step) => step.domainId === "adaptive-flywheel").length >
            0,
          `${fixture.label}: the conversion must be planned`,
        );
        // The artifact is the admission's own record of what it converted from:
        // it must name the format the JS reader named for the same fixture.
        assert.equal(
          artifact?.fromFormat,
          fixtureFormat,
          `${fixture.label}: the native artifact and the JS reader disagree about the fixture`,
        );
        assert.deepEqual(
          fingerprint(toolRoot),
          fingerprint(nativeRoot),
          `${fixture.label}: the tool's converted store and the admission's differ`,
        );
      } else {
        if (fixture.toolAction === "defer") {
          assert.equal(deferred, true, `${fixture.label}: the tool must defer this shape`);
        } else {
          assert.equal(
            deferred,
            false,
            `${fixture.label}: a current store is not a deferred conversion`,
          );
          assert.equal(toolResult.storeFormatSteps.length, 0);
        }
        // Deferral means untouched, not "converted differently": compare the
        // tool's store against a fresh build of the same fixture.
        const referenceRoot = temporaryRoot(`${fixture.label}-reference`);
        try {
          fixture.build(referenceRoot);
          assert.deepEqual(
            fingerprint(toolRoot),
            fingerprint(referenceRoot),
            `${fixture.label}: an untouched store must keep its original shape`,
          );
        } finally {
          fs.rmSync(referenceRoot, { recursive: true, force: true });
        }
        if (fixture.expectedFrom === "strategy-store-4") {
          // Already current: nothing for the admission to convert either.
          assert.equal(artifact, null, `${fixture.label}: no conversion artifact is owed`);
        } else {
          assert.equal(
            artifact?.fromFormat,
            fixtureFormat,
            `${fixture.label}: the native artifact and the JS reader disagree about the fixture`,
          );
        }
      }
    } finally {
      fs.rmSync(toolRoot, { recursive: true, force: true });
      fs.rmSync(nativeRoot, { recursive: true, force: true });
    }
  }
});
