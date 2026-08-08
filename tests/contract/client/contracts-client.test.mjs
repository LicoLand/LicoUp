#!/usr/bin/env node
/**
 * contracts-client — Client Contract Schema Validation
 *
 * Validates that all canonical client contract JSON Schema files exist under
 * packages/contracts/client/ and are structurally valid (have $id,
 * properties, required).
 *
 * Run: node tests/contract/client/contracts-client.test.mjs
 */

import { readFileSync, existsSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SCHEMA_DIR = resolve(__dirname, "../../../packages/contracts/client");

const SCHEMAS = [
  "agent-conversation-adapter.schema.json",
  "snapshot-archive-result.schema.json",
  "mobile-relay-command.schema.json",
  "optional-collaboration-local-deployment.schema.json",
  "optional-collaboration-mcp-install.schema.json",
  "optional-collaboration-plugin.schema.json",
  "semantic-conversation.schema.json",
];

// ── Helpers ────────────────────────────────────────────────────────────────

let passCount = 0;
let failCount = 0;

function assert(condition, label) {
  if (condition) {
    passCount++;
    console.log(`  PASS: ${label}`);
  } else {
    failCount++;
    console.error(`  FAIL: ${label}`);
  }
}

// ── Tests ──────────────────────────────────────────────────────────────────

console.log("\ncontracts.client — schema existence & structural validity\n");

for (const filename of SCHEMAS) {
  const filePath = resolve(SCHEMA_DIR, filename);

  // 1. File exists
  assert(existsSync(filePath), `${filename} — file exists`);

  if (!existsSync(filePath)) continue;

  // 2. JSON is parseable
  let schema;
  try {
    schema = JSON.parse(readFileSync(filePath, "utf-8"));
    assert(true, `${filename} — valid JSON`);
  } catch (e) {
    assert(false, `${filename} — valid JSON (parse error: ${e.message})`);
    continue;
  }

  // 3. Has $schema
  assert(
    typeof schema.$schema === "string" && schema.$schema.length > 0,
    `${filename} — has non-empty $schema`,
  );

  // 4. Has $id
  assert(
    typeof schema.$id === "string" && schema.$id.length > 0,
    `${filename} — has non-empty $id`,
  );

  // 5. Has title
  assert(
    typeof schema.title === "string" && schema.title.length > 0,
    `${filename} — has non-empty title`,
  );

  // 6. type is "object"
  assert(
    schema.type === "object",
    `${filename} — type is "object"`,
  );

  // 7. Has properties (at least 2)
  assert(
    schema.properties &&
      typeof schema.properties === "object" &&
      !Array.isArray(schema.properties) &&
      Object.keys(schema.properties).length >= 2,
    `${filename} — has at least 2 properties`,
  );

  // 8. Has required array (at least 2)
  assert(
    Array.isArray(schema.required) &&
      schema.required.length >= 2 &&
      schema.required.every((r) => typeof r === "string"),
    `${filename} — required array has at least 2 string entries`,
  );
}

// ── Summary ────────────────────────────────────────────────────────────────

const total = passCount + failCount;
console.log(`\n  Results: ${passCount} passed, ${failCount} failed (${total} total)\n`);

process.exit(failCount > 0 ? 1 : 0);
