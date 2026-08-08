import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const blocksRoot =
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_message_blocks";
const productionLeaves = Object.freeze([
  "disclosures.dart",
  "dispatcher.dart",
  "role_blocks.dart",
  "subagent.dart",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${blocksRoot}/${leaf}`),
  ])));
}

test("message blocks root exports exactly four ordinary libraries", async () => {
  const facade = await read(`${blocksRoot}.dart`);
  assert.deepEqual(
    [...facade.matchAll(/^export 'agent_conversation_message_blocks\/([^']+)';$/gmu)]
      .map((match) => match[1])
      .sort(),
    [...productionLeaves].sort(),
  );
  assert.equal(facade.includes("part "), false);
  assert.equal(facade.includes("class "), false);
});

test("message block leaves stay bounded with one-way dependencies", async () => {
  const source = await sources();
  for (const leaf of Object.keys(source)) {
    assert.equal(source[leaf].includes("agent_conversation_message_blocks.dart"), false);
    assert.equal(source[leaf].includes("part of"), false);
  }
  for (const dependency of ["role_blocks.dart", "subagent.dart"]) {
    assert.ok(source["dispatcher.dart"].includes(`agent_conversation_message_blocks/${dependency}`));
  }
  for (const consumer of ["role_blocks.dart", "subagent.dart"]) {
    assert.ok(source[consumer].includes("agent_conversation_message_blocks/disclosures.dart"));
    assert.equal(source[consumer].includes("agent_conversation_message_blocks/dispatcher.dart"), false);
  }
  assert.equal(source["disclosures.dart"].includes("agent_conversation_message_blocks/"), false);
});

test("dispatcher owns only message-kind and assistant-layout selection", async () => {
  const source = (await sources())["dispatcher.dart"];
  for (const token of [
    "class AgentConversationMessageBlock",
    "message.isSubagentCard",
    "switch (message.kind)",
    "AgentAssistantLayout.bubble",
    "Structured events must be rendered by the process timeline.",
  ]) {
    assert.ok(source.includes(token), `missing dispatcher token: ${token}`);
  }
  assert.equal(source.includes("MessageMarkdown"), false);
  assert.equal(source.includes("splitMessageDisplayBlocks"), false);
});

test("disclosures own content splitting and collapsed detail surfaces", async () => {
  const source = (await sources())["disclosures.dart"];
  for (const token of [
    "class AgentConversationMessageContent",
    "splitMessageDisplayBlocks(data)",
    "_RecommendedPluginsDisclosure",
    "_MessageDetailsDisclosure",
    "recommendedPluginsCount(widget.blocks)",
    "buildAgentConversationEventDetails",
    "class _DisclosureSurface",
  ]) {
    assert.ok(source.includes(token), `missing disclosure token: ${token}`);
  }
});

test("role and subagent blocks retain independent presentation state", async () => {
  const source = await sources();
  for (const token of [
    "AgentConversationUserMessageBlock",
    "AgentConversationAssistantDocumentBlock",
    "AgentConversationAssistantBubbleBlock",
    "adapter.userBubble.maxWidth",
    "adapter.assistantMaxWidth",
  ]) {
    assert.ok(source["role_blocks.dart"].includes(token), `missing role token: ${token}`);
  }
  for (const token of [
    "class AgentConversationSubagentCardBlock",
    "late bool _expanded = !widget.message.collapsed",
    "conversationMessagePreviewText",
    "widget.message.childMessages",
    "_SubagentChildMessageBlock",
  ]) {
    assert.ok(source["subagent.dart"].includes(token), `missing subagent token: ${token}`);
  }
});

test("every message block responsibility retains a dedicated widget regression", async () => {
  for (const leaf of productionLeaves) {
    await fs.access(path.join(
      repoRoot,
      `apps/desktop/test/agent_conversation_message_blocks/${leaf.replace(".dart", "_test.dart")}`,
    ));
  }
  await fs.access(path.join(
    repoRoot,
    "apps/desktop/test/agent_conversation_message_blocks/message_blocks_test_harness.dart",
  ));
});
