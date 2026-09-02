import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(path, "utf8");
const common = read("crates/licoup-native/src/platform/provider_mcp_registration.rs");
const manager = read("crates/licoup-native/src/platform/cursor_subagent_mcp_manager.rs");
const driver = read("crates/licoup-native/src/platform/cursor_driver/execution.rs");
const model = read("crates/licoup-native/src/platform/cursor_driver/model.rs");
const parser = read("crates/licoup-native/src/platform/native_agent_parser/adapters/cursor.rs");
const runtime = read("crates/licoup-native/src/platform/runtime_adapters/subagent_mesh.rs");
const startup = read("tests/product-e2e/cli/subagent-mcp/upstream/cursor-startup-recognition.mjs");

test("Cursor registration is namespaced, digest-bound, owned, and ambiguity-closed", () => {
  assert.match(manager, /ProviderConfigKind::Cursor/u);
  assert.match(common, /land\.lico\.licoup\.subagents/u);
  assert.match(common, /managedBy/u);
  assert.match(common, /config_digest/u);
  assert.match(common, /OwnedEntryAmbiguous/u);
  assert.match(common, /ApprovalConsumed/u);
  assert.match(common, /pub fn remove/u);
  assert.match(common, /resources\/subagent-mesh\/SKILL\.md/u);
  assert.match(common, /\.cursor.*skills/su);
});

test("Cursor target keeps exact create/resume, workspace, PTY, acknowledgement and cancel", () => {
  assert.match(driver, /create_chat_session/u);
  assert.match(driver, /\.arg\("--resume"\)/u);
  assert.match(driver, /\.arg\("--workspace"\)/u);
  assert.match(model, /--approve-mcps/u);
  assert.match(driver, /spawn_turn_transport/u);
  assert.match(driver, /PromptAcknowledgementMissing/u);
  assert.match(driver, /register_active_turn/u);
  assert.match(driver, /apply_mcp_runtime_root/u);
  assert.match(runtime, /ExactIdentityKind::CursorChat/u);
  assert.match(runtime, /active_cancel: true/u);
  assert.match(parser, /safe_session_id/u);
});

test("Cursor generated guidance is one ordinary unmarked wire prefix", () => {
  const policy = read("crates/licoup-native/src/platform/runtime_adapters.rs");
  assert.match(policy, /RuntimeAdapter::Cursor \| RuntimeAdapter::Antigravity/u);
  assert.match(policy, /OrdinaryWirePrefix/u);
  assert.match(driver, /cursor_cli_private_instructions_unsupported/u);
});

test("Cursor startup recognition uses a read-only standard MCP list surface", () => {
  assert.match(startup, /\["mcp", "list"\]/u);
  assert.match(startup, /format: "text"/u);
  assert.match(startup, /installerOnly: true/u);
  assert.match(startup, /probeCursorStartup/u);
});
