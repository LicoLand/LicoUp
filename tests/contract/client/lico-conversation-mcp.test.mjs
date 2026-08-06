import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const read = (relative) => readFileSync(path.join(root, relative), "utf8");

const source = read("crates/licoup-native/src/bin/lico-conversation-mcp.rs");
const catalog = read("crates/licoup-native/src/domain/owned_conversations/catalog.rs");
const packaging = JSON.parse(read("apps/desktop/packaging.modules.json"));
const cargo = read("crates/licoup-native/Cargo.toml");

const tools = [
  "lico_conversation_list",
  "lico_conversation_get",
  "lico_conversation_search",
  "lico_conversation_export",
  "lico_conversation_import",
];

test("conversation MCP exposes owned-conversation query and transfer tools", () => {
  for (const name of tools) {
    assert.match(source, new RegExp(`"${name}"`, "u"));
  }
  assert.match(source, /SERVER_NAME: &str = "lico-up-conversations"/u);
  assert.match(catalog, /agent-conversation-projections\.json/u);
  assert.match(catalog, /OwnedConversationMatchMode::Regex/u);
  assert.match(catalog, /lico-owned-conversations-export/u);
  assert.match(cargo, /name = "lico-conversation-mcp"/u);
  assert.equal(
    packaging.modules["conversations-mcp"].cargoBin,
    "lico-conversation-mcp",
  );
});
