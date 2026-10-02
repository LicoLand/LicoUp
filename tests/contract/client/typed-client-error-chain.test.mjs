import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

const production = {
  manifest: "schemas/client_bridge/manifest.json",
  schema: "schemas/client_bridge/client_error.schema.json",
  generator: "tools/scripts/generate-client-bridge-contracts.mjs",
  rustGenerated:
    "crates/licoup-native/src/ffi/generated/client_error.rs",
  dartGenerated:
    "apps/desktop/lib/src/contracts/generated/client_error.g.dart",
  runtimeError:
    "crates/licoup-native/src/platform/runtime_adapters/error.rs",
  ffiConversation:
    "crates/licoup-native/src/ffi/commands/agent_conversation.rs",
  rpcError:
    "crates/licoup-native/src/bin/licoup/stdio_rpc/error.rs",
  rpcResponse:
    "crates/licoup-native/src/bin/licoup/stdio_rpc/response.rs",
  dartCodec:
    "apps/desktop/lib/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart",
  dartRoundTrip:
    "apps/desktop/lib/src/platform/native_client/agent_service_stdio_rpc/command_round_trip.dart",
  dartConversation:
    "apps/desktop/lib/src/platform/native_client/agent_service_stdio_rpc/conversation_exchange.dart",
  policy:
    "apps/desktop/lib/src/application/features/agents/conversation/conversation_runtime_result_policy.dart",
  controller:
    "apps/desktop/lib/src/application/features/agents/conversation/conversation_message_controller.dart",
  localization:
    "apps/desktop/lib/src/application/localization/client_application_strings.dart",
};

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sourceFiles(relativeDirectory) {
  const directory = path.join(repoRoot, relativeDirectory);
  const entries = await fs.readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const relativePath = path.join(relativeDirectory, entry.name);
      if (entry.isDirectory()) {
        return sourceFiles(relativePath);
      }
      return /\.(?:dart|rs)$/.test(entry.name) ? [relativePath] : [];
    }),
  );
  return nested.flat();
}

test("one schema deterministically owns both generated ClientError values", async () => {
  const schema = JSON.parse(await read(production.schema));
  assert.equal(schema.version, 1);
  assert.deepEqual(
    schema.fields.map(({ name }) => name),
    [
      "code",
      "stage",
      "component",
      "retryable",
      "recovery",
      "presentationArgs",
    ],
  );

  const generator = await read(production.generator);
  assert.ok(generator.includes(production.manifest));
  const manifest = JSON.parse(await read(production.manifest));
  const family = manifest.families.find(({ id }) => id === "client_error");
  assert.deepEqual(family, {
    id: "client_error",
    status: "active",
    schema: production.schema,
    rustOutput: production.rustGenerated,
    dartOutput: production.dartGenerated,
  });
  for (const ownedPath of Object.values(family).filter((value) =>
    typeof value === "string" && value.includes("/"))) {
    assert.ok(
      await fs.access(path.join(repoRoot, ownedPath)).then(() => true, () => false),
      `manifest path must exist: ${ownedPath}`,
    );
  }
  assert.match(generator, /--check/);

  const check = spawnSync(
    process.execPath,
    [production.generator, "--check"],
    { cwd: repoRoot, encoding: "utf8" },
  );
  assert.equal(
    check.status,
    0,
    `generated ClientError output is stale:\n${check.stderr || check.stdout}`,
  );

  const [rust, dart] = await Promise.all([
    read(production.rustGenerated),
    read(production.dartGenerated),
  ]);
  assert.match(rust, /(?:struct|enum)\s+ClientError\b/);
  assert.match(dart, /class\s+ClientError\b/);
  assert.match(rust, /generated/i);
  assert.match(dart, /generated/i);
  for (const field of schema.fields.map(({ name }) => name)) {
    assert.ok(rust.includes(field), `Rust ClientError lost ${field}`);
    assert.ok(dart.includes(field), `Dart ClientError lost ${field}`);
  }
});

test("source, FFI, RPC, and Dart projections carry the complete typed error", async () => {
  const sources = Object.fromEntries(
    await Promise.all(
      Object.entries(production).map(async ([name, relativePath]) => [
        name,
        await read(relativePath),
      ]),
    ),
  );
  for (const [name, source] of Object.entries(sources).filter(([name]) =>
    [
      "runtimeError",
      "ffiConversation",
      "rpcResponse",
      "dartCodec",
    ].includes(name),
  )) {
    for (const field of [
      "code",
      "stage",
      "component",
      "retryable",
      "recovery",
      "presentationArgs",
    ]) {
      assert.ok(source.includes(field), `${name} drops ClientError.${field}`);
    }
  }

  assert.match(sources.runtimeError, /\bClientError\b/);
  assert.match(sources.ffiConversation, /\bClientError\b/);
  assert.match(sources.rpcResponse, /\bClientError\b/);
  assert.match(sources.dartCodec, /\bClientError\b/);
  assert.match(sources.dartRoundTrip, /\bClientError\b/);
  assert.match(sources.dartConversation, /\bClientError\b/);
});

test("node-owned production has no ClientError twins, shims, or string projections", async () => {
  const generatedDirectories = [
    "crates/licoup-native/src/ffi/generated",
    "apps/desktop/lib/src/contracts/generated",
  ];
  const generatedFiles = (
    await Promise.all(generatedDirectories.map(sourceFiles))
  ).flat();
  const generatedSet = new Set(generatedFiles);
  const nodeOwnedFiles = [
    ...new Set([
      ...Object.values(production).filter((relativePath) =>
        /\.(?:dart|rs)$/.test(relativePath),
      ),
      ...generatedFiles,
    ]),
  ];
  const sources = new Map(
    await Promise.all(
      nodeOwnedFiles.map(async (relativePath) => [
        relativePath,
        await read(relativePath),
      ]),
    ),
  );

  const forbiddenClientErrorTypes = [
    [/\b(?:ClientErrorShim|LegacyClientError|ClientErrorDto)\b/, "shim"],
    [/\b(?:type|typedef)\s+ClientError\b/, "alias"],
  ];
  for (const [relativePath, source] of sources) {
    for (const [pattern, description] of forbiddenClientErrorTypes) {
      assert.doesNotMatch(
        source,
        pattern,
        `${relativePath} contains a forbidden ${description}`,
      );
    }
    if (!generatedSet.has(relativePath)) {
      assert.doesNotMatch(
        source,
        /\b(?:struct|enum|class)\s+ClientError\b/,
        `${relativePath} handwrites ClientError`,
      );
      assert.doesNotMatch(
        source,
        /\b(?:pub\s+)?use\b[^;]*\bas\s+ClientError\b/,
        `${relativePath} aliases ClientError`,
      );
    }
  }

  const typedChainFiles = new Set(
    Object.values(production).filter((relativePath) =>
      /\.(?:dart|rs)$/u.test(relativePath)),
  );
  const forbiddenTypedChain = [
    [/\b(?:errorCode|error_code)\b/, "code-only projection"],
    [
      /(?:message|error|cause)\s*\.\s*(?:contains|startsWith|endsWith|contains_key)\s*\(/,
      "string classifier",
    ],
    [/\bRegExp\s*\(/, "regular-expression classifier"],
  ];
  for (const relativePath of typedChainFiles) {
    const source = sources.get(relativePath);
    for (const [pattern, description] of forbiddenTypedChain) {
      assert.doesNotMatch(
        source,
        pattern,
        `${relativePath} contains a forbidden ${description}`,
      );
    }
  }

  const generatedSource = generatedFiles
    .map((relativePath) => sources.get(relativePath))
    .join("\n");
  assert.equal(
    (generatedSource.match(/\b(?:struct|enum)\s+ClientError\b/g) ?? []).length,
    1,
    "generated Rust contracts must own exactly one ClientError",
  );
  assert.equal(
    (generatedSource.match(/\bclass\s+ClientError\b/g) ?? []).length,
    1,
    "generated Dart contracts must own exactly one ClientError",
  );

  assert.match(sources.get(production.policy), /\bClientError\b/);
  assert.match(sources.get(production.localization), /\bClientError\b/);
  assert.doesNotMatch(
    sources.get(production.controller),
    /[\u3400-\u9fff]|send failed at|发送在/,
  );
});
