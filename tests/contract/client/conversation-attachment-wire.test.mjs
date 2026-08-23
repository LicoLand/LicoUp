import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const read = (relative) => fs.readFile(path.join(root, relative), "utf8");

test("conversation attachments use one typed Dart-to-Rust wire", async () => {
  const dartContract = "apps/desktop/lib/src/contracts/agent_conversation_attachment.dart";
  const dartService = "apps/desktop/lib/src/backend/features/agents/services/agent_conversation_service.dart";
  const rustParams = "crates/licoup-native/src/platform/runtime_adapters/params.rs";
  const codexSession = "crates/licoup-native/src/platform/native_agent_parser/adapters/codex/session.rs";
  const [contract, service, params, session] = await Promise.all(
    [dartContract, dartService, rustParams, codexSession].map(read),
  );

  for (const field of ["id", "name", "mediaType", "path"]) {
    assert.match(contract, new RegExp(`'${field}'\\s*:`));
    assert.match(params, new RegExp(`"${field}"`));
  }
  assert.match(service, /'attachments':\s*\[/u);
  assert.match(params, /MAX_IMAGE_ATTACHMENTS:\s*usize\s*=\s*4/u);
  assert.match(session, /"type":\s*"localImage"/u);
  assert.doesNotMatch(service, /data:image|attach-url|base64Encode/u);
});

test("frontend image rendering depends on the byte-reader contract, never dart:io", async () => {
  const rendererPath = "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_image_attachments.dart";
  const workspacePath = "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart";
  const [renderer, workspace] = await Promise.all([
    read(rendererPath),
    read(workspacePath),
  ]);

  assert.match(renderer, /ConversationImageByteReaderScope/u);
  assert.match(workspace, /conversationImageByteReader/u);
  assert.doesNotMatch(renderer, /dart:io|File\s*\(/u);
  assert.doesNotMatch(workspace, /dart:io|File\s*\(/u);
});
