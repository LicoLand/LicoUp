// The mirror clause of the migration diagnostic contract: every durable shape
// and constant this Node tool states about the Rust admission must still agree
// with the owner that defines it. The constants themselves are owned by
// `probe.mjs`; this leaf only proves they have not drifted, so a change to the
// Rust admission that is not carried into the mirror fails here.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";

import {
  CLIENT_STATE_COLLECTIONS,
  CLIENT_STATE_SCHEMA_VERSION,
  DURABLE_SHAPES,
} from "../../../../tools/scripts/client-state-migration/probe.mjs";
import {
  CLIENT_STATE_MIGRATION,
  CLIENT_STATE_POLICY,
  CONVERSATION_STORE,
  repoRoot,
} from "./support.mjs";

const BACKSLASH = String.fromCharCode(92);

test("every mirrored durable shape and constant still matches the Rust admission", async () => {
  const [migration, policy, migrationPlatform, conversationStore, probe, strategyStore] = await Promise.all([
    fs.promises.readFile(path.join(repoRoot, "crates/licoup-native/src/domain/client_state_migration/stores.rs"), "utf8"),
    fs.promises.readFile(path.join(repoRoot, CLIENT_STATE_POLICY), "utf8"),
    fs.promises.readFile(path.join(repoRoot, CLIENT_STATE_MIGRATION), "utf8"),
    fs.promises.readFile(path.join(repoRoot, CONVERSATION_STORE), "utf8"),
    fs.promises.readFile(path.join(repoRoot, "tools/scripts/client-state-migration/probe.mjs"), "utf8"),
    fs.promises.readFile(path.join(repoRoot, "crates/licoup-native/src/domain/client_state_migration/strategy_store.rs"), "utf8"),
  ]);
  // Whitespace is stripped so the binding survives any rustfmt layout.
  const compact = migration.replace(/\s+/gu, "");

  const jsonDocuments = new Map();
  const pattern =
    /"([a-z0-9-]+)"=>probe_json_schema\(&root\.join\("([^"]+)"\),(\d+),JsonSchemaPolicy::(\w+),\)/gu;
  for (const match of compact.matchAll(pattern)) {
    jsonDocuments.set(match[1], {
      document: match[2],
      schemaVersion: Number(match[3]),
      policy: match[4] === "MissingIsLegacy" ? "missing-is-legacy" : "current-only",
    });
  }
  const mirrored = Object.fromEntries(
    Object.entries(DURABLE_SHAPES)
      .filter(([, shape]) => shape.kind === "json-document")
      .map(([domainId, shape]) => [domainId, {
        document: shape.document,
        schemaVersion: shape.schemaVersion,
        policy: shape.policy,
      }]),
  );
  assert.deepEqual(Object.fromEntries(jsonDocuments), mirrored);
  for (const [domainId, shape] of Object.entries(mirrored)) {
    assert.ok(
      compact.includes(`"${domainId}"=>probe_json_schema`),
      `${domainId} must route through probe_json_schema`,
    );
    assert.ok(shape.document.length > 0);
  }

  const probeRoute = (name, document) =>
    `${name}(&root.join("${document}"))`;
  assert.ok(
    compact.includes(probeRoute("probe_agent_tab_order", DURABLE_SHAPES["agent-tab-order"].document)),
  );
  assert.ok(
    compact.includes(probeRoute("probe_mobile_relay", DURABLE_SHAPES["mobile-relay"].document)),
  );
  const strategy = strategyStore.replace(/\s+/gu, "");
  assert.ok(strategy.includes('STRATEGY_STORE_DATABASE:&str="client-state/adaptive-flywheel/strategies.sqlite3";'));
  assert.ok(strategy.includes('meta_versions:&["3"],domain_schema_version:2,'));
  assert.ok(strategy.includes('meta_versions:&["2"],domain_schema_version:1,'));
  assert.ok(compact.includes('root.join("client-state/conversations/conversations.sqlite3")'));
  assert.ok(compact.includes('root.join("client-state/conversations/migration-v5.complete")'));
  const completionSource =
    `value=="schema=v5${BACKSLASH}nstatus=complete${BACKSLASH}n"`;
  assert.ok(
    compact.includes(completionSource),
    "the completion marker contract moved in the admission",
  );
  const currentSchema = conversationStore.match(
    /pub const CURRENT_SCHEMA_VERSION: &str = "(\d+)";/u,
  );
  assert.ok(currentSchema, "the conversation store schema version moved");
  assert.ok(
    probe.includes(`const CONVERSATION_SCHEMA_VERSION = "${currentSchema[1]}";`),
    "the diagnostic's conversation schema version must mirror the conversation store",
  );

  const collections = policy
    .slice(
      policy.indexOf("pub(super) const COLLECTIONS"),
      policy.indexOf("];", policy.indexOf("pub(super) const COLLECTIONS")),
    )
    .match(/"([a-z0-9-]+)"/gu)
    .map((quoted) => quoted.slice(1, -1));
  assert.deepEqual(collections, [...CLIENT_STATE_COLLECTIONS]);
  const stateSchema = policy.match(
    /pub\(super\) const STATE_SCHEMA_VERSION: &str = "([^"]+)";/u,
  );
  assert.ok(stateSchema, "the client-state schema marker moved");
  assert.equal(
    CLIENT_STATE_SCHEMA_VERSION,
    stateSchema[1],
    "the diagnostic's client-state schema marker must mirror the admission's",
  );
  assert.match(migrationPlatform, /"client state collection owner mismatch"/u);
});
