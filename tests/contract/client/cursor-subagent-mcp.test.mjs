import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(path, "utf8");
const common = read("crates/licoup-native/src/platform/provider_mcp_registration.rs");
const manager = read("crates/licoup-native/src/platform/cursor_subagent_mcp_manager.rs");
const driver = read("crates/licoup-native/src/platform/cursor_driver/execution.rs");
// Cursor's fixed launch arguments and capability surface are the package's own
// vocabulary; the host's driver reads them through the former path.
const model = read("crates/licoup-agent-cursor/src/model.rs");
const hostVocabulary = read("crates/licoup-native/src/platform/cursor_driver/model.rs");
// Cursor's wire dialect — including the application error codes an installed
// Cursor client returns for a delegated MCP turn — is the Cursor adapter
// package's own, parsed once below the port (ADR-0008).
const parser = read("crates/licoup-agent-cursor/src/parser.rs");
const registration = read("crates/licoup-agent-cursor/src/registration.rs");
const runtime = read("crates/licoup-agent-drivers/src/runtime_adapters/subagent_mesh.rs");
const adapters = read("crates/licoup-native/src/platform/native_agent_parser/adapters/mod.rs");
const startup = read("tests/product-e2e/cli/subagent-mcp/upstream/cursor-startup-recognition.mjs");

test("Cursor registration is namespaced, digest-bound, owned, and ambiguity-closed", () => {
  assert.match(manager, /ProviderConfigKind::Cursor/u);
  assert.match(common, /land\.lico\.licoup\.subagents/u);
  assert.match(common, /managedBy/u);
  assert.match(common, /config_digest/u);
  assert.match(common, /OwnedEntryAmbiguous/u);
  assert.match(common, /DuplicateConnectorEntry/u);
  assert.match(common, /ApprovalConsumed/u);
  assert.match(common, /pub fn remove/u);
  assert.match(
    common,
    /const SKILL_SOURCE: &str = crate::domain::client_conversation::LICOUP_GUIDE_SKILL_SOURCE;/u,
  );
  assert.match(common, /\.cursor.*skills/su);
  assert.match(common, /publish_shared_skill/u);
  assert.match(common, /\.agents.*skills/su);
});

test("Cursor target keeps exact create/resume, workspace, PTY, acknowledgement and cancel", () => {
  assert.match(driver, /create_chat_session/u);
  assert.match(driver, /\.arg\("--resume"\)/u);
  assert.match(driver, /\.arg\("--workspace"\)/u);
  assert.match(model, /--approve-mcps/u);
  assert.match(hostVocabulary, /licoup_agent_cursor::model/u);
  assert.match(driver, /spawn_turn_transport/u);
  assert.match(driver, /PromptAcknowledgementMissing/u);
  assert.match(driver, /register_active_turn/u);
  assert.match(driver, /apply_mcp_runtime_root/u);
  // Exact resume asks the Agent's own parser through the shared port, and the
  // host's Cursor registration answers with Cursor's session-id rule.
  assert.match(runtime, /parser\.valid_identity/u);
  // The host composes the package's own registration for Cursor, which answers
  // exact-resume identity with the same session-id rule the parser binds with.
  assert.match(adapters, /licoup_agent_cursor::registration::REGISTRATION/u);
  assert.match(registration, /pub fn valid_identity/u);
  assert.match(registration, /parser::safe_session_id/u);
  assert.match(runtime, /active_cancel: true/u);
  assert.match(parser, /fn safe_session_id/u);
});

test("Cursor generated guidance is one ordinary unmarked wire prefix", () => {
  const policy = read("crates/licoup-agent-drivers/src/runtime_adapters.rs");
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
