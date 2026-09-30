// Shared context and synthetic data-root fixtures for the client-state
// migration diagnostic contract leaves. This module states no contract of its
// own: it exists so the leaves observe one durable-root vocabulary instead of
// each rebuilding the same fixtures.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = path.resolve(
  fileURLToPath(new URL("../../../../", import.meta.url)),
);

/** The operator-facing facade and the module it must stay thin around. */
export const facadeRef = "tools/scripts/client-state-migration.mjs";
export const moduleRoot = "tools/scripts/client-state-migration";

/** The Rust admission and the platform owners the tool mirrors read-only. */
export const MIGRATION_MODULE = "crates/licoup-native/src/domain/client_state_migration.rs";
// The schema version and the collection adoption are owned by the client-state
// crate; the command layer only re-exports them.
export const CLIENT_STATE_POLICY = "crates/licoup-client-state/src/policy.rs";
export const CLIENT_STATE_MIGRATION = "crates/licoup-client-state/src/migration.rs";
export const CONVERSATION_STORE = "crates/licoup-conversation/src/store/mod.rs";

/**
 * The conversation store's own current schema version, read from the owner that
 * defines it so a fixture never restates it. The admission-mirror leaf asserts
 * the same value through the diagnostic's mirrored constant.
 */
export function conversationSchemaVersion() {
  const source = fs.readFileSync(path.join(repoRoot, CONVERSATION_STORE), "utf8");
  const match = source.match(/pub const CURRENT_SCHEMA_VERSION: &str = "(\d+)";/u);
  assert.ok(match, "the conversation store schema version moved");
  return match[1];
}

export function tempRoot(label) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `licoup-migration-${label}-`));
}

export function removeRoot(root) {
  fs.rmSync(root, { recursive: true, force: true });
}

export function runCli(args) {
  return spawnSync(process.execPath, [path.join(repoRoot, facadeRef), ...args], {
    cwd: repoRoot,
    encoding: "utf8",
  });
}

export function runJson(args) {
  const result = runCli([...args, "--json"]);
  const envelope = JSON.parse(result.stdout);
  return { ...result, envelope };
}

export function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value)}\n`);
}

/**
 * Migration metadata is private state: the admission reads it through the
 * 0700/0600-enforcing path, so a fixture that is going to be certified healthy
 * has to carry those modes.
 */
export function writePrivateJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true, mode: 0o700 });
  fs.writeFileSync(filePath, `${JSON.stringify(value)}\n`, { mode: 0o600 });
}

/** Every path and byte under `root`, so a read-only command can be proven inert. */
export function snapshot(root) {
  const entries = [];
  const visit = (directory, prefix) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort()) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const absolute = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        entries.push(`${relative}/`);
        visit(absolute, relative);
      } else {
        entries.push(`${relative}:${fs.readFileSync(absolute).toString("base64")}`);
      }
    }
  };
  visit(root, "");
  return entries.join("\n");
}

export function seedLedger(root, frontier, domains) {
  writePrivateJson(path.join(root, "client-state/migrations/ledger.json"), {
    schemaVersion: "v0.0.1:client-state-migration-ledger-1",
    highestAdmittedProductVersion: "0.3.0",
    frontierId: frontier.frontierId,
    domains,
  });
}

/** The state a completed admission leaves behind, for the healthy verdict. */
export function seedAdmittedRoot(root, frontier) {
  const expectedSteps = (domain) =>
    domain.steps.filter((step) => step.toSchemaVersion <= domain.targetSchemaVersion)
      .map((step) => step.stepId);
  const domains = {};
  for (const domain of frontier.domains) {
    domains[domain.domainId] = {
      schemaVersion: domain.targetSchemaVersion,
      completedStepIds: expectedSteps(domain),
    };
  }
  seedLedger(root, frontier, domains);
  for (const domain of frontier.domains) {
    writePrivateJson(path.join(root, `client-state/migrations/domain-state/${domain.domainId}.json`), {
      schemaVersion: "v0.0.1:client-state-domain-marker-1",
      domainId: domain.domainId,
      authoritativeSchemaVersion: domain.targetSchemaVersion,
    });
  }
  writeJson(path.join(root, ".licoup-workspace.json"), { schemaVersion: 1 });
  writeJson(path.join(root, "client-state/appearance-preferences.json"), {
    schemaVersion: 1,
    appearancePresetId: "synthetic",
  });
  writeJson(path.join(root, "client-state/agent-tool-allowlists.json"), { schemaVersion: 1 });
  writeJson(path.join(root, "client-state/current-client-view.json"), { schemaVersion: 1 });
  writeJson(path.join(root, "client-state/skill-hub-preferences.json"), { schemaVersion: 1 });
  writeJson(path.join(root, "client-state/mobile-home-layout.json"), { schemaVersion: 2 });
  writeJson(path.join(root, "client-state/agent-tab-order.json"), {
    schemaVersion: 1,
    order: [],
  });
  writeJson(path.join(root, "client-state/mobile-relay/config.json"), { schemaVersion: 2 });
  writeJson(path.join(root, "client-state/settings.json"), {
    schemaVersion: "v0.0.1:schema:definition-1",
    collection: "settings",
    items: [],
  });
  const conversations = path.join(root, "client-state/conversations");
  fs.mkdirSync(conversations, { recursive: true });
  const database = new DatabaseSync(path.join(conversations, "conversations.sqlite3"));
  database.exec(
    "CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);" +
      `INSERT INTO schema_meta(key,value) VALUES ('version','${conversationSchemaVersion()}');`,
  );
  database.close();
  fs.writeFileSync(
    path.join(conversations, "migration-v5.complete"),
    ["schema=v5", "status=complete", ""].join("\n"),
  );
  const flywheel = path.join(root, "client-state/adaptive-flywheel");
  fs.mkdirSync(flywheel, { recursive: true });
  const strategies = new DatabaseSync(path.join(flywheel, "strategies.sqlite3"));
  strategies.exec(
    "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);" +
      "INSERT INTO strategy_meta(key,value) VALUES ('version','3');",
  );
  strategies.close();
}
