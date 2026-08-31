import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const controllerRoot = "apps/desktop/lib/src/application/controller";
const lifecyclePath = `${controllerRoot}/client_lifecycle_coordinator.dart`;

const projectionConsumers = Object.freeze([
  `${controllerRoot}/client_controller.dart`,
  `${controllerRoot}/client_lifecycle_facade.dart`,
  `${controllerRoot}/client_target_facade.dart`,
  `${controllerRoot}/client_conversation_facade.dart`,
  "apps/desktop/lib/src/application/features/agents/conversation/conversation_refresh_controller.dart",
  "apps/desktop/lib/src/application/features/agents/workspace/agent_workspace_coordinator.dart",
  "apps/desktop/lib/src/application/product_acceptance/agent_conversation_release_live.dart",
]);

const lifecycleComposition = Object.freeze([
  `${controllerRoot}/client_component_assembly.dart`,
  `${controllerRoot}/assembly/client_lifecycle_component_assembly.dart`,
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

function maskDartNonCode(source) {
  const masked = source.split("");
  const isQuote = (value) => value === "'" || value === "\"";
  const isIdentifierPart = (value) =>
    value !== undefined && /[A-Za-z0-9_$]/u.test(value);
  const maskRange = (start, end) => {
    for (let cursor = start; cursor < end; cursor += 1) {
      if (source[cursor] !== "\n" && source[cursor] !== "\r") {
        masked[cursor] = " ";
      }
    }
  };

  function scanLineComment(start) {
    let cursor = start + 2;
    while (cursor < source.length && source[cursor] !== "\n") cursor += 1;
    return cursor;
  }

  function scanBlockComment(start) {
    let cursor = start + 2;
    let depth = 1;
    while (cursor < source.length && depth > 0) {
      if (source.startsWith("/*", cursor)) {
        depth += 1;
        cursor += 2;
      } else if (source.startsWith("*/", cursor)) {
        depth -= 1;
        cursor += 2;
      } else {
        cursor += 1;
      }
    }
    return cursor;
  }

  function scanInterpolation(start) {
    let cursor = start;
    let depth = 1;
    while (cursor < source.length && depth > 0) {
      if (source.startsWith("//", cursor)) {
        cursor = scanLineComment(cursor);
        continue;
      }
      if (source.startsWith("/*", cursor)) {
        cursor = scanBlockComment(cursor);
        continue;
      }
      const raw =
        (source[cursor] === "r" || source[cursor] === "R") &&
        isQuote(source[cursor + 1]) &&
        !isIdentifierPart(source[cursor - 1]);
      if (raw) {
        cursor = scanString(cursor, true);
        continue;
      }
      if (isQuote(source[cursor])) {
        cursor = scanString(cursor, false);
        continue;
      }
      if (source[cursor] === "{") depth += 1;
      if (source[cursor] === "}") depth -= 1;
      cursor += 1;
    }
    return cursor;
  }

  function scanString(start, raw) {
    const quoteStart = raw ? start + 1 : start;
    const quote = source[quoteStart];
    const triple = source.slice(quoteStart, quoteStart + 3) === quote.repeat(3);
    const delimiter = triple ? quote.repeat(3) : quote;
    let cursor = quoteStart + delimiter.length;
    while (cursor < source.length) {
      if (!raw && source[cursor] === "\\") {
        cursor += 2;
        continue;
      }
      if (
        !raw &&
        source[cursor] === "$" &&
        source[cursor + 1] === "{"
      ) {
        cursor = scanInterpolation(cursor + 2);
        continue;
      }
      if (source.startsWith(delimiter, cursor)) {
        return cursor + delimiter.length;
      }
      cursor += 1;
    }
    return source.length;
  }

  let cursor = 0;
  while (cursor < source.length) {
    if (source.startsWith("//", cursor)) {
      const end = scanLineComment(cursor);
      maskRange(cursor, end);
      cursor = end;
      continue;
    }
    if (source.startsWith("/*", cursor)) {
      const end = scanBlockComment(cursor);
      maskRange(cursor, end);
      cursor = end;
      continue;
    }
    const raw =
      (source[cursor] === "r" || source[cursor] === "R") &&
      isQuote(source[cursor + 1]) &&
      !isIdentifierPart(source[cursor - 1]);
    if (raw || isQuote(source[cursor])) {
      const end = scanString(cursor, raw);
      maskRange(cursor, end);
      cursor = end;
      continue;
    }
    cursor += 1;
  }
  return masked.join("");
}

function dartFunctionBlock(source, functionName) {
  const startPattern = new RegExp(
    `(?:^|\\n)[ \\t]*(?:@override\\s*)?(?:Future<[^>]+>|void|bool)\\s+${functionName}\\s*\\(`,
    "mu",
  );
  const match = startPattern.exec(source);
  assert.ok(match, `missing Dart function ${functionName}`);
  const declarationStart = match.index + match[0].indexOf(functionName);
  let parenthesisDepth = 0;
  let cursor = source.indexOf("(", declarationStart);
  for (; cursor < source.length; cursor += 1) {
    if (source[cursor] === "(") parenthesisDepth += 1;
    if (source[cursor] === ")") parenthesisDepth -= 1;
    if (parenthesisDepth === 0) break;
  }
  const open = source.indexOf("{", cursor + 1);
  assert.notEqual(open, -1, `missing body for Dart function ${functionName}`);
  let braceDepth = 0;
  for (cursor = open; cursor < source.length; cursor += 1) {
    if (source[cursor] === "{") braceDepth += 1;
    if (source[cursor] === "}") braceDepth -= 1;
    if (braceDepth === 0) return source.slice(declarationStart, cursor + 1);
  }
  assert.fail(`unterminated Dart function ${functionName}`);
}

async function dartSources(relativePath) {
  const entries = await fs.readdir(path.join(repoRoot, relativePath), {
    withFileTypes: true,
  });
  const sources = [];
  for (const entry of entries) {
    const child = path.join(relativePath, entry.name);
    if (entry.isDirectory()) {
      sources.push(...await dartSources(child));
    } else if (entry.isFile() && entry.name.endsWith(".dart")) {
      sources.push([child, await read(child)]);
    }
  }
  return sources;
}

test("Dart lexical masking rejects comment and literal decoy code", () => {
  const source = [
    "// CLIENT_LIFECYCLE_DECOY lifecycleProjection.disposed }",
    "/* CLIENT_LIFECYCLE_DECOY { /* nested } */ } */",
    "final single = 'CLIENT_LIFECYCLE_DECOY lifecycleController.dispose() }';",
    "final double = \"😀 CLIENT_LIFECYCLE_DECOY lifecycleProjection.initialized {\";",
    "final rawSingle = r'CLIENT_LIFECYCLE_DECOY ${notInterpolation} }';",
    "final rawDouble = r\"CLIENT_LIFECYCLE_DECOY { stillRaw }\";",
    "final escaped = 'prefix \\' CLIENT_LIFECYCLE_DECOY } suffix';",
    "final tripleSingle = '''CLIENT_LIFECYCLE_DECOY",
    "{ multiline single }''';",
    "final tripleDouble = \"\"\"CLIENT_LIFECYCLE_DECOY",
    "} multiline double {\"\"\";",
    "final rawTriple = r'''CLIENT_LIFECYCLE_DECOY ${stillRaw}",
    "{ raw multiline }''';",
    "final interpolated = 'prefix ${(() {",
    "  final nested = \"CLIENT_LIFECYCLE_DECOY }\";",
    "  return {\"brace\": \"}\", \"nested\": {\"value\": 1}};",
    "})()} suffix';",
    "void requiredFunction() {",
    "  final localDecoy = '} CLIENT_LIFECYCLE_DECOY void requiredFunction() {}';",
    "  if (lifecycleProjection.disposed) return;",
    "}",
  ].join("\n");

  const masked = maskDartNonCode(source);
  assert.equal(masked.length, source.length);
  assert.deepEqual(
    [...masked.matchAll(/\n/gu)].map((match) => match.index),
    [...source.matchAll(/\n/gu)].map((match) => match.index),
  );
  assert.doesNotMatch(masked, /CLIENT_LIFECYCLE_DECOY/u);
  const functionBlock = dartFunctionBlock(masked, "requiredFunction");
  assert.match(
    functionBlock,
    /if\s*\(\s*lifecycleProjection\.disposed\s*\)\s*return\s*;/u,
  );
  assert.equal(
    [...functionBlock.matchAll(/requiredFunction/gu)].length,
    1,
    "a function-shaped string decoy must remain masked",
  );
});

test("ClientLifecycleCoordinator owns an immutable lifecycle projection", async () => {
  const coordinator = maskDartNonCode(await read(lifecyclePath));

  assert.match(
    coordinator,
    /final class ClientLifecycleProjection\b/u,
    "the lifecycle read model must be a closed immutable type",
  );
  assert.match(
    coordinator,
    /ClientLifecycleProjection get projection\b/u,
    "the coordinator must expose one read-only projection",
  );
  assert.match(
    coordinator,
    /final ClientLifecyclePhase phase\b/u,
    "the projection must publish the authoritative phase as final state",
  );
  assert.doesNotMatch(
    coordinator,
    /set (?:phase|initialized|disposed)\s*\(/u,
    "lifecycle facts must not be externally writable",
  );

  assert.match(
    coordinator,
    /@visibleForTesting\s+ClientLifecycleReport\s+transitionForTesting\s*\(/u,
    "the transition table must have one explicit typed behavior seam",
  );
});

test("declared lifecycle consumers read specific projection facts", async () => {
  const sources = Object.fromEntries(
    await Promise.all(projectionConsumers.map(async (relativePath) => [
      relativePath,
      maskDartNonCode(await read(relativePath)),
    ])),
  );
  const controller = sources[`${controllerRoot}/client_controller.dart`];
  assert.match(
    controller,
    /ClientLifecycleProjection\s+get\s+lifecycleProjection\s*=>\s*lifecycleController\.projection\s*;/u,
  );
  const dispose = dartFunctionBlock(controller, "dispose");
  assert.match(
    dispose,
    /if\s*\(\s*lifecycleProjection\.disposed\s*\)\s*return\s*;/u,
    "ClientController.dispose must guard through the coordinator projection",
  );
  assert.match(
    dispose,
    /lifecycleController\.dispose\s*\(\s*\)\s*;/u,
    "ClientController.dispose must request the authoritative disposed transition",
  );

  const lifecycle = sources[`${controllerRoot}/client_lifecycle_facade.dart`];
  assert.match(
    lifecycle,
    /Future<void>\s+initialize\s*\(\s*\)\s*=>\s*initializeWithOptions\s*\(\s*\)\s*;/u,
    "default client initialization must use the configurable lifecycle entry point",
  );
  assert.match(
    lifecycle,
    /Future<void>\s+initializeWithOptions\s*\([^)]*\)\s*=>\s*lifecycleController\.initialize\s*\(/u,
    "the configurable lifecycle entry point must enter through the coordinator",
  );
  for (const functionName of [
    "_initializeClientCore",
    "_finalizeClientInitialization",
  ]) {
    const block = dartFunctionBlock(lifecycle, functionName);
    assert.match(
      block,
      /lifecycleProjection\.disposed/u,
      `${functionName} must use authoritative disposal state`,
    );
    assert.doesNotMatch(block, /\binitialized\s*=/u);
  }

  const target = sources[`${controllerRoot}/client_target_facade.dart`];
  assert.match(
    target,
    /bool\s+get\s+initialized\s*=>\s*lifecycleProjection\.initialized\s*;/u,
    "ClientTargetFacade readiness must be a read-only derived projection",
  );

  const conversation =
    sources[`${controllerRoot}/client_conversation_facade.dart`];
  assert.match(
    dartFunctionBlock(conversation, "notifyClientStateChanged"),
    /if\s*\(\s*!lifecycleProjection\.disposed\s*\)/u,
    "conversation notification guards must read authoritative disposal",
  );

  const workspace =
    sources["apps/desktop/lib/src/application/features/agents/workspace/agent_workspace_coordinator.dart"];
  assert.match(
    workspace,
    /ClientLifecycleProjection\s+get\s+lifecycleProjection\s*;/u,
    "the workspace contract must require the immutable lifecycle projection",
  );
  assert.match(
    workspace,
    /bool\s+get\s+agentWorkspaceDisposed\s*=>\s*lifecycleProjection\.disposed\s*;/u,
    "workspace disposal must be derived rather than stored",
  );

  const refresh =
    sources["apps/desktop/lib/src/application/features/agents/conversation/conversation_refresh_controller.dart"];
  for (const functionName of [
    "_scheduleConversationRefreshForSelection",
    "_conversationRefreshTargetIsCurrent",
  ]) {
    const block = dartFunctionBlock(refresh, functionName);
    assert.match(block, /lifecycleProjection\.disposed/u);
    assert.match(block, /lifecycleProjection\.initialized/u);
  }

  const product =
    sources["apps/desktop/lib/src/application/product_acceptance/agent_conversation_release_live.dart"];
  const run = dartFunctionBlock(product, "_run");
  assert.match(
    run,
    /\(\s*\)\s*=>\s*controller\.lifecycleProjection\.initialized/u,
    "product acceptance must wait on authoritative readiness",
  );
});

test("legacy writable readiness and disposal shadows are deleted", async () => {
  const sources = new Map(
    await Promise.all(
      [...projectionConsumers, ...lifecycleComposition].map(async (relativePath) => [
        relativePath,
        maskDartNonCode(await read(relativePath)),
      ]),
    ),
  );

  const forbiddenResidue = Object.freeze([
    [/\bbool\s+initialized\s*=/u, "writable initialized field"],
    [/\binitialized\s*=\s*(?:true|false|value)\b/u, "initialized mutation"],
    [/\bbool\s+_disposed\s*=/u, "ClientController disposed shadow"],
    [/\b_disposed\s*=\s*(?:true|false)\b/u, "disposed shadow mutation"],
    [/\bbool\s+agentWorkspaceDisposed\s*=/u, "workspace disposed shadow"],
    [
      /\bagentWorkspaceDisposed\s*=\s*(?:true|false)\b/u,
      "workspace disposed shadow mutation",
    ],
    [/\bonInitializedChanged\b/u, "initialization callback compatibility path"],
    [/\bclientControllerDisposed\b/u, "disposed compatibility getter"],
  ]);

  for (const [relativePath, source] of sources) {
    for (const [pattern, label] of forbiddenResidue) {
      assert.doesNotMatch(source, pattern, `${relativePath} retains ${label}`);
    }
  }
});

test("no layer outside the coordinator writes lifecycle transitions", async () => {
  const sources = await dartSources("apps/desktop/lib");

  for (const [relativePath, source] of sources) {
    if (relativePath === lifecyclePath) continue;
    const code = maskDartNonCode(source);
    assert.doesNotMatch(
      code,
      /\b(?:_?phase|lifecyclePhase)\s*=\s*ClientLifecyclePhase\./u,
      `${relativePath} duplicates a lifecycle phase transition`,
    );
    assert.doesNotMatch(
      code,
      /\bClientLifecycleProjection\s*\(/u,
      `${relativePath} constructs an authority projection outside the coordinator`,
    );
  }

  const coordinator = maskDartNonCode(await read(lifecyclePath));
  assert.match(
    coordinator,
    /\b_phase\s*=\s*ClientLifecyclePhase\./u,
    "the coordinator must remain the sole phase writer",
  );
});
