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
const leafPaths = new Set(productionLeaves.map((leaf) => `${paneRoot}/${leaf}`));
const removedRecentSessionsImport =
  "package:licoup/src/frontend/features/agents/ui/agent_conversation_pane/recent_sessions.dart";

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

function resolveDartImport(from, specifier) {
  if (specifier.startsWith("package:licoup/")) {
    return path.posix.join(
      "apps/desktop/lib",
      specifier.slice("package:licoup/".length),
    );
  }
  if (specifier.startsWith(".")) {
    return path.posix.normalize(path.posix.join(path.posix.dirname(from), specifier));
  }
  return null;
}

function importedDartPaths(from, source) {
  return importedDartSpecifiers(source)
    .map((specifier) => resolveDartImport(from, specifier))
    .filter((resolved) => resolved !== null);
}

function importedDartSpecifiers(source) {
  return [...source.matchAll(/^\s*import\s+['"]([^'"]+)['"][^;]*;/gmu)]
    .map((match) => match[1]);
}

async function dartFilesUnder(relativeRoot) {
  const entries = await fs.readdir(path.join(repoRoot, relativeRoot), {
    withFileTypes: true,
  });
  const files = await Promise.all(entries.map(async (entry) => {
    const relativePath = path.posix.join(relativeRoot, entry.name);
    if (entry.isDirectory()) return dartFilesUnder(relativePath);
    return entry.isFile() && entry.name.endsWith(".dart") ? [relativePath] : [];
  }));
  return files.flat();
}

async function sourceGraph() {
  const graph = new Map();
  for (const leafPath of leafPaths) {
    const source = await read(leafPath);
    graph.set(
      leafPath,
      importedDartPaths(leafPath, source).filter((target) => leafPaths.has(target)),
    );
  }
  return graph;
}

test("agent conversation pane facade exposes four leaves and one neutral port", async () => {
  const facade = await read(`${paneRoot}.dart`);
  assert.deepEqual(
    [...facade.matchAll(/^export 'agent_conversation_pane\/([^']+)';$/gmu)]
      .map((match) => match[1])
      .sort(),
    [...productionLeaves].sort(),
  );
  assert.match(facade, /^export 'agent_conversation_pane_presentation\.dart';$/mu);
  assert.equal(facade.includes("part "), false);
  assert.equal(facade.includes("class "), false);
});

test("the real Dart import graph has no cross-leaf edges", async () => {
  const graph = await sourceGraph();
  assert.deepEqual(
    [...graph.entries()].map(([source, targets]) => [source, [...targets]]),
    [...leafPaths].map((source) => [source, []]),
  );
});

test("all four leaves are controller-free and consume neutral presentation ports", async () => {
  for (const leafPath of leafPaths) {
    const source = await read(leafPath);
    assert.equal(source.includes("ClientController"), false, leafPath);
    assert.equal(source.includes("part of"), false, leafPath);
  }
  const composition = await read(`${paneRoot}/composition.dart`);
  const header = await read(`${paneRoot}/header.dart`);
  assert.match(composition, /AgentConversationPaneState/u);
  assert.match(composition, /AgentConversationPaneActions/u);
  assert.match(header, /AgentConversationHeaderState/u);
  assert.match(header, /AgentConversationHeaderActions/u);
});

test("workspace is the single typed controller projection", async () => {
  const workspace = await read(
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart",
  );
  const port = await read(
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart",
  );
  for (const token of [
    "AgentConversationPaneState(",
    "AgentConversationPaneActions(",
    "AgentConversationHeaderState(",
    "AgentConversationHeaderActions(",
  ]) {
    assert.equal(workspace.match(new RegExp(token.replace("(", "\\("), "gu"))?.length, 1);
  }
  assert.match(port, /List\.unmodifiable/u);
  assert.match(port, /enum AgentConversationServeStatus/u);
  assert.equal(port.includes("Map<String, dynamic>"), false);
});

test("superseded hidden recent-sessions leaf is removed", async () => {
  await assert.rejects(
    fs.access(path.join(repoRoot, `${paneRoot}/recent_sessions.dart`)),
    { code: "ENOENT" },
  );
  await fs.access(path.join(
    repoRoot,
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_recent_sessions.dart",
  ));
});

test("production and test Dart sources do not import the removed recent-sessions URI", async () => {
  const dartFiles = (
    await Promise.all([
      dartFilesUnder("apps/desktop/lib"),
      dartFilesUnder("apps/desktop/test"),
    ])
  ).flat();
  const staleImports = [];
  for (const dartFile of dartFiles) {
    const imports = importedDartSpecifiers(await read(dartFile));
    if (imports.includes(removedRecentSessionsImport)) staleImports.push(dartFile);
  }
  assert.deepEqual(staleImports, []);
});

test("every pane responsibility retains a dedicated widget regression", async () => {
  for (const leaf of productionLeaves) {
    await fs.access(path.join(
      repoRoot,
      `apps/desktop/test/agent_conversation_pane/${leaf.replace(".dart", "_test.dart")}`,
    ));
  }
});
