import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const paneRoot =
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_pane";
const productionLeaves = Object.freeze([
  "actions.dart",
  "composition.dart",
  "header.dart",
  "resize.dart",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${paneRoot}/${leaf}`),
  ])));
}

test("agent conversation pane root exports exactly four ordinary libraries", async () => {
  const facade = await read(`${paneRoot}.dart`);
  assert.deepEqual(
    [...facade.matchAll(/^export 'agent_conversation_pane\/([^']+)';$/gmu)]
      .map((match) => match[1])
      .sort(),
    [...productionLeaves].sort(),
  );
  assert.equal(facade.trimEnd().split(/\r?\n/u).length, 4);
  assert.equal(facade.includes("part "), false);
  assert.equal(facade.includes("class "), false);
});

test("pane leaves are bounded with one-way composition dependencies", async () => {
  const source = await sources();
  const limits = new Map([
    ["actions.dart", 160],
    ["composition.dart", 240],
    ["header.dart", 340],
    ["resize.dart", 140],
  ]);
  for (const [leaf, limit] of limits) {
    assert.ok(source[leaf].trimEnd().split(/\r?\n/u).length <= limit, `${leaf} is oversized`);
    assert.equal(source[leaf].includes("agent_conversation_pane.dart"), false);
    assert.equal(source[leaf].includes("part of"), false);
  }
  assert.ok(source["composition.dart"].includes("agent_conversation_pane/actions.dart"));
  assert.ok(source["composition.dart"].includes("agent_conversation_pane/header.dart"));
  for (const independent of ["actions.dart", "header.dart", "resize.dart"]) {
    assert.equal(source[independent].includes("agent_conversation_pane/composition.dart"), false);
  }
});

test("composition owns send gating while actions remain controller-free", async () => {
  const source = await sources();
  for (const token of [
    "conversationParityDisclosureCopy",
    "controller.sendConversationMessage(text)",
    "controller.scanTargets()",
    "showAgentOrchestrationPolicyEditor",
    "AgentConversationMessageList",
    "RuntimeMessageComposer",
    "ConversationPaneHeader",
  ]) {
    assert.ok(source["composition.dart"].includes(token));
  }
  for (const token of [
    "AgentConversationEmptySelection",
    "ArchiveAgentConversationsButton",
    "NewAgentConversationButton",
    "MobileComposerSurface",
  ]) {
    assert.ok(source["actions.dart"].includes(token));
  }
  assert.equal(source["actions.dart"].includes("ClientController"), false);
});

test("resize and header retain independent geometry and identity policies", async () => {
  const source = await sources();
  for (const token of [
    "ResizableConversationSplit",
    "PaneEdgeDragHandle",
    "conversationHistoryMinWidth",
    "SystemMouseCursors.resizeLeftRight",
    "onHorizontalDragUpdate",
  ]) {
    assert.ok(source["resize.dart"].includes(token));
  }
  for (const token of [
    "ConversationPaneHeader",
    "session?.title.trim()",
    "ConversationParityDisclosurePanel",
    "AgentOrchestrationPolicyHeaderControls",
    "opencode-serve-status",
    "AgentsSidebarCollapseControl",
    "_SidebarToggleGlyphPainter",
  ]) {
    assert.ok(source["header.dart"].includes(token));
  }
});

test("every pane responsibility retains a dedicated widget regression", async () => {
  for (const leaf of productionLeaves) {
    await fs.access(path.join(
      repoRoot,
      `apps/desktop/test/agent_conversation_pane/${leaf.replace(".dart", "_test.dart")}`,
    ));
  }
  await fs.access(path.join(
    repoRoot,
    "apps/desktop/test/agent_conversation_pane/pane_test_harness.dart",
  ));
});
