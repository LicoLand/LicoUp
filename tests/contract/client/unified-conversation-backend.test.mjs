import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const read = (relative) => readFileSync(path.join(root, relative), "utf8");

const contract = JSON.parse(read("schemas/client_bridge/conversation.json"));
const manifest = JSON.parse(read("schemas/client_bridge/manifest.json"));
const state = JSON.parse(read("schemas/client_bridge/state.json"));
const canonicalDomain = read("crates/licoup-conversation/src/client_conversation/mod.rs");
const canonicalStore = read("crates/licoup-conversation/src/store/mod.rs");
const nativeFacade = read("crates/licoup-native/src/domain/client_conversation/mod.rs");
const service = read("crates/licoup-native/src/domain/client_conversation/service.rs");
const migration = read("crates/licoup-native/src/domain/client_conversation/migration.rs");
const conversationMcp = read("crates/licoup-native/src/bin/lico-conversation-mcp.rs");
const flutterController = read(
  "apps/desktop/lib/src/application/features/conversations/client_conversation_controller.dart",
);
const dartBinding = read("apps/desktop/lib/src/contracts/generated/conversation.g.dart");
const rustBinding = read("crates/licoup-native/src/ffi/generated/conversation.rs");
const retiredDefaultGroupSync = ["conversation.default-local-group", "sync"].join(".");
const retiredFlutterSyncMethod = ["syncDefaultLocal", "AgentGroup"].join("");
const retiredRustSyncWriter = ["sync_default_local", "agent_group"].join("_");

test("generated Conversation contract is active and excludes strategy execution", () => {
  assert.deepEqual(
    manifest.families.find((family) => family.id === "conversation"),
    {
      id: "conversation",
      status: "active",
      schema: "schemas/client_bridge/conversation.json",
      rustOutput: "crates/licoup-native/src/ffi/generated/conversation.rs",
      dartOutput: "apps/desktop/lib/src/contracts/generated/conversation.g.dart",
    },
  );
  assert.equal(state.collections.includes("adaptive-flywheel"), false);
  assert.equal(contract.defaultEventPageSize, 50);
  assert.equal(contract.maxEventPageSize, 100);
  for (const action of contract.actions) {
    assert.match(service, new RegExp(`"${action.replaceAll(".", "\\.")}"`, "u"));
  }
  for (const retired of [
    retiredDefaultGroupSync,
    "conversation.role.create",
    "conversation.flywheel.create",
    "conversation.run.start",
    "conversation.run.turn.claim",
  ]) {
    assert.equal(contract.actions.includes(retired), false, retired);
    assert.doesNotMatch(service, new RegExp(retired.replaceAll(".", "\\."), "u"));
  }
});

test("explicit-membership boundary binds Flutter and generated bindings", () => {
  for (const action of contract.actions) {
    const pattern = new RegExp(action.replaceAll(".", "\\."), "u");
    assert.match(dartBinding, pattern, `generated Dart binding missing ${action}`);
    assert.match(rustBinding, pattern, `generated Rust binding missing ${action}`);
  }
  for (const retired of [retiredDefaultGroupSync]) {
    const pattern = new RegExp(retired.replaceAll(".", "\\."), "u");
    assert.doesNotMatch(contract.actions.join(" "), pattern, retired);
    assert.doesNotMatch(dartBinding, pattern, `${retired} in Dart binding`);
    assert.doesNotMatch(rustBinding, pattern, `${retired} in Rust binding`);
    assert.doesNotMatch(flutterController, pattern, `${retired} in Flutter controller`);
  }
  assert.doesNotMatch(
    flutterController,
    new RegExp(retiredFlutterSyncMethod, "u"),
  );
  assert.doesNotMatch(canonicalStore, new RegExp(retiredRustSyncWriter, "u"));
});

test("Canonical Conversation crate owns messaging and membership facts only", () => {
  for (const table of [
    "principals",
    "conversations",
    "memberships",
    "events",
    "event_parts",
    "direct_turns",
    "source_links",
    "runtime_bindings",
    "conversation_dispatches",
    "subagent_dispatch_claims",
    "subagent_mcp_inbound",
  ]) {
    assert.match(
      canonicalStore,
      new RegExp(`CREATE TABLE IF NOT EXISTS ${table}`, "u"),
    );
  }
  for (const retired of [
    "conversation_roles",
    "role_candidates",
    "flywheels",
    "flywheel_stages",
    "run_stage_snapshots",
    "run_candidate_snapshots",
  ]) {
    assert.doesNotMatch(
      canonicalStore,
      new RegExp(`CREATE TABLE IF NOT EXISTS ${retired}`, "u"),
    );
  }
  assert.match(canonicalStore, /DROP TABLE IF EXISTS flywheels/u);
  assert.match(canonicalStore, /PRAGMA journal_mode=WAL/u);
  assert.match(
    canonicalStore,
    /CREATE VIRTUAL TABLE IF NOT EXISTS event_search USING fts5/u,
  );
  assert.match(canonicalDomain, /pub enum PrincipalKind/u);
  assert.match(canonicalDomain, /pub struct Membership/u);
  assert.match(canonicalDomain, /pub struct DirectTurn/u);
  assert.doesNotMatch(
    canonicalDomain,
    /ConversationRole|AdaptiveFlywheel|FlywheelRun/u,
  );
  assert.match(nativeFacade, /pub use licoup_conversation::\*;/u);
  assert.doesNotMatch(nativeFacade, /CREATE TABLE|rusqlite/u);
});

test("retired ordinal configuration is cleaned without reinterpretation", () => {
  assert.match(migration, /adaptive-flywheel\.toml/u);
  assert.doesNotMatch(
    migration,
    /LegacyMigrationRoleSpec|LegacyMigrationFlywheelSpec|migrate_flywheel/u,
  );
  assert.doesNotMatch(canonicalStore, /migrate_legacy_flywheel_configuration/u);
  assert.match(canonicalStore, /migration_provenance/u);
});

test("superseded operational stores and fixed workflow owners stay removed", () => {
  for (const relative of [
    "crates/licoup-native/src/domain/owned_conversations/mod.rs",
    "crates/licoup-native/src/domain/group_conversation/mod.rs",
    "crates/licoup-native/src/domain/agent_workflow_loop.rs",
    "crates/licoup-native/src/platform/agent_workflow_runtime.rs",
    "apps/desktop/lib/src/platform/agents/subagent_handoff_store.dart",
    "apps/desktop/lib/src/platform/agents/agent_conversation_projection_store.dart",
    "apps/desktop/lib/src/platform/agents/group_conversation_store.dart",
    "apps/desktop/lib/src/application/features/agents/orchestration/agent_orchestration_controller.dart",
  ]) {
    assert.equal(existsSync(path.join(root, relative)), false, relative);
  }
  assert.match(conversationMcp, /ConversationService::open/u);
  assert.doesNotMatch(conversationMcp, /projection store|matchMode|replaceExisting/u);
});
