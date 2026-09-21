import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { NOTICE_OUTBOX_TABLES } from "../lib/published-strategy-format.mjs";

/**
 * The delivery tables are published by the store crate that owns them and
 * created by two migrations — the native admission and this tool. Three copies
 * of one contract is how a migration creates a table no reader expects, so this
 * test holds all three together, column by column and index by index.
 *
 * What it proves: the column lists and the pending index agree. What it does not
 * prove: the two migrations are the same code — they are not, and that is the
 * point of comparing their output rather than trusting one of them.
 */

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const storeSchemaRef = "crates/licoup-workflow-store/src/schema/mod.rs";
const admissionRef = "crates/licoup-native/src/domain/client_state_migration.rs";

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
}

/**
 * `CREATE TABLE [IF NOT EXISTS] name(` → column names, in order.
 *
 * Read line by line rather than by one whole-statement pattern: the column
 * lists contain parentheses of their own (`CHECK(... IN (...))`), and a pattern
 * that stops at the first closing parenthesis would compare truncated lists.
 */
function tableColumns(source, table) {
  const lines = source.split("\n");
  const opener = new RegExp(`CREATE TABLE (?:IF NOT EXISTS )?${table}\\(`, "u");
  const start = lines.findIndex((line) => opener.test(line));
  assert.ok(start >= 0, `${table} is not created in the source under test`);
  const columns = [];
  for (const line of lines.slice(start + 1)) {
    const trimmed = line.trim().replace(/,$/u, "");
    if (trimmed.startsWith(")")) break;
    if (trimmed.length === 0) continue;
    if (/^(PRIMARY KEY|UNIQUE|CHECK|FOREIGN KEY)\b/u.test(trimmed)) continue;
    columns.push(trimmed.split(/\s+/u)[0]);
  }
  return columns;
}

test("the delivery tables are published, migrated, and created with the same columns", () => {
  const storeSchema = read(storeSchemaRef);
  const admission = read(admissionRef);

  for (const table of NOTICE_OUTBOX_TABLES) {
    const published = tableColumns(storeSchema, table.name);
    const admitted = tableColumns(admission, table.name);
    // A parser that stopped matching would compare two empty lists and pass.
    assert.ok(published.length > 0, `${table.name}: no published columns were read`);
    assert.ok(admitted.length > 0, `${table.name}: no admission columns were read`);
    assert.deepEqual(
      [...table.columns],
      published,
      `${table.name}: this tool and the publishing crate disagree on the published columns`,
    );
    assert.deepEqual(
      admitted,
      published,
      `${table.name}: the admission's table is not the published table`,
    );
  }

  // The pending-query index is part of the contract: it is what makes the
  // bounded outbox read a covered index scan.
  const indexPattern = /CREATE INDEX (?:IF NOT EXISTS )?workflow_notice_intents_pending_idx\s+ON workflow_notice_intents\(([^)]*)\)/u;
  const publishedIndex = storeSchema.match(indexPattern);
  const admittedIndex = admission.match(indexPattern);
  assert.ok(publishedIndex, "the publishing crate no longer defines the pending index");
  assert.ok(admittedIndex, "the admission no longer creates the pending index");
  const normalize = (columns) => columns.split(",").map((column) => column.trim());
  assert.deepEqual(
    normalize(admittedIndex[1]),
    normalize(publishedIndex[1]),
    "the pending index must cover the same columns",
  );
  for (const table of NOTICE_OUTBOX_TABLES) {
    const toolIndex = table.statements.join("\n");
    for (const column of table.columns) {
      assert.ok(
        toolIndex.includes(column),
        `${table.name}.${column} is missing from this tool's own statements`,
      );
    }
  }

  // The recovery record is one record per store, written by both tools: a
  // field the admission does not know is refused by `deny_unknown_fields`, and
  // a field it needs but this tool omits makes its own conversion record
  // unreadable. Both writers must emit exactly the declared set.
  const structMatch = admission.match(/struct StrategyStoreArtifact \{([^}]*)\}/u);
  assert.ok(structMatch, "the admission's conversion record is gone from its source");
  const declaredFields = structMatch[1]
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && line.endsWith(","))
    .map((line) => line.split(":")[0].trim());
  assert.deepEqual(
    declaredFields,
    [
      "schema_version",
      "domain_id",
      "from_format",
      "target_format",
      "applied_step_ids",
      "status",
    ],
    "the admission's record fields moved; this tool writes the camelCase names",
  );
  assert.match(
    admission,
    /rename_all = "camelCase", deny_unknown_fields/u,
    "the record's field naming or its closed-set policy moved",
  );
  const toolWriter = read("tools/data-migration/lib/published-strategy-format.mjs");
  for (const field of ["schemaVersion", "domainId", "fromFormat", "targetFormat", "appliedStepIds", "status"]) {
    assert.ok(
      toolWriter.includes(`${field}:`),
      `this tool no longer writes ${field} into the conversion record`,
    );
  }

  // The status vocabulary is the published one: a migration that widened it
  // would accept a row no reader in the published format can interpret.
  assert.match(
    storeSchema,
    /status TEXT NOT NULL CHECK\(status IN \('pending', 'accepted'\)\)/u,
    "the published status vocabulary moved",
  );
  assert.match(
    admission,
    /status TEXT NOT NULL CHECK\(status IN \('pending', 'accepted'\)\)/u,
    "the admission's status vocabulary is not the published one",
  );
});
