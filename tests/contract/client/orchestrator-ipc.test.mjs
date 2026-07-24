import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import net from "node:net";
import Ajv2020 from "ajv/dist/2020.js";
import {
  NATIVE_CARGO_TEST_TARGET,
} from "../../../tools/scripts/lib/test-artifact-lifecycle.mjs";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const schemaRef = "packages/contracts/client/lico-up-orchestrator-ipc.schema.json";
const ipcRoot = "crates/licoup-native/src/platform/orchestrator_ipc";
const sourceRefs = Object.freeze([
  `${ipcRoot}/mod.rs`,
  `${ipcRoot}/client.rs`,
  "crates/licoup-native/src/platform/orchestrator_service.rs",
  "crates/licoup-native/src/platform/mod.rs",
  "crates/licoup-native/src/bin/licoup/orchestrator.rs",
  "crates/licoup-native/src/bin/licoup.rs",
]);
const protocolVersion = "lico.orchestrator.ipc.v1";
const methods = Object.freeze([
  "service.status",
  "service.stop",
  "policy.register",
  "policy.activate",
  "workflow.submit",
  "workflow.preview",
  "workflow.status",
  "workflow.cancel",
  "workflow.approve",
  "workflow.events",
  "workflow.wait",
  "workflow.message",
]);
const stableErrors = Object.freeze([
  "peer_rejected",
  "protocol_mismatch",
  "invalid_request",
  "unknown_method",
  "frame_too_large",
  "frame_truncated",
  "rate_limited",
  "capacity_exceeded",
  "operation_forbidden",
  "capability_missing",
  "capability_rejected",
  "transport_closed",
  "service_already_running",
  "service_draining",
  "service_unavailable",
  "policy_schema_unsupported",
  "policy_schema_invalid",
  "policy_revision_unavailable",
  "policy_revision_inactive",
  "workflow_unavailable",
  "workflow_terminal",
  "workflow_not_active",
  "bridge_queue_full",
  "message_artifact_unavailable",
  "approval_rejected",
  "idempotency_conflict",
  "orchestrator_state_error",
]);
const privacyCanaries = Object.freeze([
  "synthetic-account@example.invalid",
  "synthetic-credential-canary",
  "/synthetic/private-path-canary",
  "synthetic-native-session-canary",
  "synthetic raw provider output",
]);
const paramsDefinitionByMethod = Object.freeze({
  "service.status": "serviceStatusParams",
  "service.stop": "serviceStopParams",
  "policy.register": "policyRegisterParams",
  "policy.activate": "policyActivateParams",
  "workflow.submit": "workflowSubmitParams",
  "workflow.preview": "workflowPreviewParams",
  "workflow.status": "workflowStatusParams",
  "workflow.cancel": "workflowCancelParams",
  "workflow.approve": "workflowApproveParams",
  "workflow.events": "workflowEventsParams",
  "workflow.wait": "workflowWaitParams",
  "workflow.message": "workflowMessageParams",
});

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function readSources() {
  return Object.fromEntries(
    await Promise.all(sourceRefs.map(async (ref) => [ref, await read(ref)])),
  );
}

function resolveLocalSchemaRef(schema, node) {
  if (!node?.$ref) return node;
  const prefix = "#/$defs/";
  assert.equal(node.$ref.startsWith(prefix), true, "schema ref must remain local");
  return schema.$defs[node.$ref.slice(prefix.length)];
}

function propertySchema(schema, node, property, seen = new Set()) {
  const resolved = resolveLocalSchemaRef(schema, node);
  if (!resolved || seen.has(resolved)) return undefined;
  seen.add(resolved);
  if (resolved.properties?.[property]) {
    return resolveLocalSchemaRef(schema, resolved.properties[property]);
  }
  for (const branch of resolved.allOf || []) {
    const found = propertySchema(schema, branch, property, seen);
    if (found) return found;
  }
  return undefined;
}

function enumAt(schema, definition, property) {
  return propertySchema(schema, schema.$defs?.[definition], property)?.enum;
}

function requiredFields(schema, node, seen = new Set()) {
  const resolved = resolveLocalSchemaRef(schema, node);
  if (!resolved || seen.has(resolved)) return [];
  seen.add(resolved);
  return [...new Set([
    ...(resolved.required || []),
    ...(resolved.allOf || []).flatMap((branch) => requiredFields(schema, branch, seen)),
  ])];
}

function collectMethodBindings(schema, node, found = [], seen = new Set()) {
  const resolved = resolveLocalSchemaRef(schema, node);
  if (!resolved || seen.has(resolved)) return found;
  seen.add(resolved);
  const method = resolved?.if?.properties?.method?.const;
  const paramsRef = resolved?.then?.properties?.params?.$ref;
  if (method && paramsRef) found.push([method, paramsRef]);
  for (const branch of [...(resolved?.allOf || []), ...(resolved?.oneOf || [])]) {
    collectMethodBindings(schema, branch, found, seen);
  }
  return found;
}

function rustCharacterLiteralLength(source, start) {
  if (source[start] !== "'") return 0;
  let index = start + 1;
  if (source[index] === "\\") {
    index += 1;
    const escape = source[index];
    if (["n", "r", "t", "0", "\\", "'", '"'].includes(escape)) {
      index += 1;
    } else if (
      escape === "x" &&
      /^[0-9A-Fa-f]{2}$/u.test(source.slice(index + 1, index + 3))
    ) {
      index += 3;
    } else if (escape === "u" && source[index + 1] === "{") {
      const close = source.indexOf("}", index + 2);
      if (close < 0 || !/^[0-9A-Fa-f_]+$/u.test(source.slice(index + 2, close))) {
        return 0;
      }
      index = close + 1;
    } else {
      return 0;
    }
  } else {
    const codePoint = source.codePointAt(index);
    if (codePoint == null || [0x0a, 0x0d, 0x27, 0x5c].includes(codePoint)) return 0;
    index += String.fromCodePoint(codePoint).length;
  }
  return source[index] === "'" ? index - start + 1 : 0;
}

function stripRustCommentsAndLiterals(source) {
  let output = "";
  let index = 0;
  let blockDepth = 0;
  while (index < source.length) {
    if (blockDepth > 0) {
      if (source.startsWith("/*", index)) {
        blockDepth += 1;
        index += 2;
      } else if (source.startsWith("*/", index)) {
        blockDepth -= 1;
        index += 2;
      } else {
        output += source[index] === "\n" ? "\n" : " ";
        index += 1;
      }
      continue;
    }
    if (source.startsWith("//", index)) {
      const newline = source.indexOf("\n", index);
      if (newline < 0) break;
      output += "\n";
      index = newline + 1;
      continue;
    }
    if (source.startsWith("/*", index)) {
      blockDepth = 1;
      index += 2;
      continue;
    }
    if (source[index] === "'") {
      const characterLength = rustCharacterLiteralLength(source, index);
      if (characterLength === 0) {
        output += "'";
        index += 1;
        continue;
      }
      output += " ".repeat(characterLength);
      index += characterLength;
      continue;
    }
    if (source[index] === '"') {
      const quote = source[index];
      output += " ";
      index += 1;
      while (index < source.length) {
        if (source[index] === "\\") index += 2;
        else if (source[index] === quote) {
          index += 1;
          break;
        } else {
          output += source[index] === "\n" ? "\n" : " ";
          index += 1;
        }
      }
      continue;
    }
    output += source[index];
    index += 1;
  }
  return output;
}

function splitTopLevel(value) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < value.length; index += 1) {
    if (value[index] === "{") depth += 1;
    else if (value[index] === "}") depth -= 1;
    else if (value[index] === "," && depth === 0) {
      parts.push(value.slice(start, index));
      start = index + 1;
    }
  }
  parts.push(value.slice(start));
  return parts.filter((part) => part.trim());
}

function expandRustUseTree(tree, prefix = "") {
  const normalized = tree.trim().replace(/\s+as\s+[A-Za-z_][A-Za-z0-9_]*\s*$/u, "");
  let depth = 0;
  let groupStart = -1;
  let groupEnd = -1;
  for (let index = 0; index < normalized.length; index += 1) {
    if (normalized[index] === "{") {
      if (depth === 0) groupStart = index;
      depth += 1;
    } else if (normalized[index] === "}") {
      depth -= 1;
      if (depth === 0) {
        groupEnd = index;
        break;
      }
    }
  }
  if (groupStart >= 0 && groupEnd > groupStart) {
    const head = normalized.slice(0, groupStart).replace(/::\s*$/u, "");
    const base = [prefix, head].filter(Boolean).join("::");
    return splitTopLevel(normalized.slice(groupStart + 1, groupEnd))
      .flatMap((part) => expandRustUseTree(part, base));
  }
  const leaf = normalized.replace(/\s+/gu, "").replace(/^::/u, "");
  return [[prefix, leaf].filter(Boolean).join("::")];
}

function canonicalRustImports(source) {
  const code = stripRustCommentsAndLiterals(source);
  return [...code.matchAll(/\b(?:pub(?:\([^)]*\))?\s+)?use\s+([^;]+);/gu)]
    .flatMap((match) => expandRustUseTree(match[1]))
    .map((entry) => entry.toLowerCase())
    .sort();
}

function rustStringLiterals(source) {
  const withoutComments = source
    .replace(/\/\*[\s\S]*?\*\//gu, " ")
    .replace(/\/\/[^\n]*/gu, " ");
  return [
    ...withoutComments.matchAll(/r(#+)?"([\s\S]*?)"\1|"((?:\\.|[^"\\])*)"/gu),
  ].map((match) => (match[2] ?? match[3] ?? "").toLowerCase());
}

function runFrozenRustHarness() {
  return spawnSync(
    process.execPath,
    [
      path.join(repoRoot, "tools/scripts/cargo-client.mjs"),
      "test",
      "--manifest-path",
      path.join(repoRoot, "crates/licoup-native/Cargo.toml"),
      "--test",
      "orchestrator_ipc_acceptance",
    ],
    {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
      timeout: 180_000,
    },
  );
}

function assertSchemaSample(validate, sample, expected, label) {
  const actual = validate(sample);
  assert.equal(actual, expected, `${label}: ${JSON.stringify(validate.errors)}`);
}

function assertClosedAndBounded(schema, node, label, seen = new Set()) {
  if (node.$ref) {
    const prefix = "#/$defs/";
    assert.equal(node.$ref.startsWith(prefix), true, `${label}: local ref required`);
    const definition = node.$ref.slice(prefix.length);
    if (seen.has(definition)) return;
    seen.add(definition);
    assertClosedAndBounded(schema, schema.$defs[definition], definition, seen);
    return;
  }
  for (const [index, branch] of (node.oneOf || []).entries()) {
    assertClosedAndBounded(schema, branch, `${label}.oneOf[${index}]`, seen);
  }
  for (const [index, branch] of (node.allOf || []).entries()) {
    assertClosedAndBounded(schema, branch, `${label}.allOf[${index}]`, seen);
  }
  if (node.type === "object" || node.properties) {
    if ("additionalProperties" in node) {
      assert.equal(node.additionalProperties, false, `${label}: object must be closed`);
    }
    for (const [property, child] of Object.entries(node.properties || {})) {
      assertClosedAndBounded(schema, child, `${label}.${property}`, seen);
    }
  }
  if (node.type === "array") {
    assert.equal(Number.isSafeInteger(node.maxItems), true, `${label}: maxItems required`);
    assertClosedAndBounded(schema, node.items, `${label}.items`, seen);
  }
  if (node.type === "string") {
    assert.equal(
      Number.isSafeInteger(node.maxLength) || Array.isArray(node.enum) || "const" in node,
      true,
      `${label}: bounded string required`,
    );
  }
}

function request(method, params, extra = {}) {
  return {
    protocolVersion,
    requestId: `request-${method}`,
    clientKind: "cli",
    method,
    params,
    ...extra,
  };
}

function acceptancePolicy() {
  return {
    schemaVersion: 3,
    id: "policy-ipc-synthetic",
    label: "Synthetic IPC policy",
    commander: null,
    modelLibrary: [{
      agentId: "fixture-agent",
      modelId: "fixture-model",
      reasoningLevel: "max",
    }],
    agents: [{
      id: "fixture-agent",
      roles: ["implementation"],
      capabilities: ["conversation.send"],
    }],
    workflow: {
      steps: [{
        id: "implement",
        predecessorId: null,
        purpose: "action",
        roleId: "implementation",
        agentId: "fixture-agent",
        modelId: "fixture-model",
        reasoningLevel: "max",
        contextStepIds: [],
        maxContextBytes: 4096,
        outputMode: "text",
        timeoutMs: 1000,
        maxAttempts: 1,
        failureAction: "stop",
        approval: { required: true },
        condition: null,
        validation: null,
      }],
    },
  };
}

function encodeFrame(value) {
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  const frame = Buffer.allocUnsafe(4 + payload.length);
  frame.writeUInt32BE(payload.length, 0);
  payload.copy(frame, 4);
  return frame;
}

function decodeFrames(buffer) {
  const decoded = [];
  let offset = 0;
  while (offset + 4 <= buffer.length) {
    const length = buffer.readUInt32BE(offset);
    if (offset + 4 + length > buffer.length) break;
    decoded.push(JSON.parse(buffer.subarray(offset + 4, offset + 4 + length).toString("utf8")));
    offset += 4 + length;
  }
  return decoded;
}

function rawSocketFault(
  endpointPath,
  handshake,
  fault,
  maxFrameBytes,
  halfCloseRequest = null,
  timeoutMs = 5_000,
) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ path: endpointPath });
    const chunks = [];
    let totalBytes = 0;
    let timedOut = false;
    let socketError = null;
    const timer = setTimeout(() => {
      timedOut = true;
      socket.destroy();
    }, timeoutMs);
    const finish = () => {
      clearTimeout(timer);
      const raw = Buffer.concat(chunks);
      resolve({ frames: decodeFrames(raw), raw, timedOut, socketError });
    };
    socket.once("error", (error) => { socketError = error.code || "socket_error"; });
    socket.on("data", (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > 64 * 1024) socket.destroy();
      else chunks.push(chunk);
    });
    socket.once("close", finish);
    socket.once("connect", () => {
      const handshakeFrame = encodeFrame(handshake);
      if (fault === "abrupt") {
        socket.end(handshakeFrame);
        return;
      }
      socket.write(handshakeFrame);
      if (fault === "oversize") {
        const header = Buffer.alloc(4);
        header.writeUInt32BE(maxFrameBytes + 1, 0);
        socket.end(header);
      } else if (fault === "truncated") {
        const header = Buffer.alloc(4);
        header.writeUInt32BE(128, 0);
        socket.write(header);
        socket.end(Buffer.from('{"protocolVersion":', "utf8"));
      } else if (fault === "half-close") {
        socket.end(encodeFrame(halfCloseRequest));
      }
    });
  });
}

function startBinary(binary, args, timeoutMs = 10_000, extraEnvironment = {}) {
  let child;
  const completed = new Promise((resolve, reject) => {
    child = spawn(binary, args, {
      cwd: repoRoot,
      env: { ...process.env, ...extraEnvironment },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    const pid = child.pid;
    let timedOut = false;
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (stdout.length + stderr.length > 64 * 1024) child.kill("SIGKILL");
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
      if (stdout.length + stderr.length > 64 * 1024) child.kill("SIGKILL");
    });
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, pid, signal, stdout, stderr, timedOut });
    });
  });
  return { child, completed, pid: child.pid };
}

function runBinary(binary, args, timeoutMs = 10_000, extraEnvironment = {}) {
  return startBinary(binary, args, timeoutMs, extraEnvironment).completed;
}

async function waitForJson(file, attempts = 200) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      return JSON.parse(await fs.readFile(file, "utf8"));
    } catch (error) {
      if (error?.code !== "ENOENT" && !(error instanceof SyntaxError)) throw error;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
  assert.fail("orchestrator acceptance service did not become ready");
}

async function waitForExit(child, timeoutMs = 5_000) {
  if (child.exitCode !== null || child.signalCode !== null) return true;
  return new Promise((resolve) => {
    let settled = false;
    let killTimer;
    let deadline;
    const finish = (exited) => {
      if (settled) return;
      settled = true;
      clearTimeout(killTimer);
      clearTimeout(deadline);
      resolve(exited);
    };
    killTimer = setTimeout(() => child.kill("SIGKILL"), timeoutMs / 2);
    deadline = setTimeout(() => finish(false), timeoutMs);
    child.once("exit", () => finish(true));
  });
}

async function waitForPidExit(pid, attempts = 200) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      process.kill(pid, 0);
    } catch (error) {
      if (error?.code === "ESRCH") return true;
      throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
}

function readMacProcessCommand(pid) {
  const inspected = spawnSync("/bin/ps", [
    "-ww",
    "-p",
    String(pid),
    "-o",
    "command=",
  ], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
    maxBuffer: 64 * 1024,
    timeout: 2_000,
  });
  assert.equal(inspected.status, 0, "macOS service argv inspection failed");
  assert.equal(inspected.stdout.length > 0 && inspected.stdout.length <= 64 * 1024, true);
  return inspected.stdout.trim();
}

async function writeRequest(directory, name, payload) {
  const target = path.join(directory, `${name}.json`);
  await fs.writeFile(target, `${JSON.stringify(payload)}\n`, { mode: 0o600 });
  return target;
}

async function readBoundedRegularFiles(root, limits = {
  entries: 256,
  directories: 64,
  files: 128,
  depth: 16,
  // SQLite WAL preallocation is page-oriented even for this tiny fixture.
  // Keep the privacy scan bounded without mistaking sparse database capacity
  // for leaked application payload.
  fileBytes: 8 * 1024 * 1024,
  totalBytes: 16 * 1024 * 1024,
}) {
  const contents = [];
  let entryCount = 0;
  let directoryCount = 1;
  let fileCount = 0;
  let totalBytes = 0;
  async function visit(directory, depth) {
    assert.equal(depth <= limits.depth, true, "state tree depth exceeded");
    const entries = (await fs.readdir(directory, { withFileTypes: true }))
      .sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      entryCount += 1;
      assert.equal(entryCount <= limits.entries, true, "state entry count exceeded");
      const target = path.join(directory, entry.name);
      const metadata = await fs.lstat(target);
      assert.equal(metadata.isSymbolicLink(), false, "state root must not contain symlinks");
      if (metadata.isDirectory()) {
        directoryCount += 1;
        assert.equal(
          directoryCount <= limits.directories,
          true,
          "state directory count exceeded",
        );
        await visit(target, depth + 1);
      }
      else if (metadata.isFile()) {
        fileCount += 1;
        assert.equal(fileCount <= limits.files, true, "state file count exceeded");
        assert.equal(metadata.size <= limits.fileBytes, true, "state file size exceeded");
        totalBytes += metadata.size;
        assert.equal(totalBytes <= limits.totalBytes, true, "state cumulative size exceeded");
        contents.push(await fs.readFile(target));
      }
    }
  }
  await visit(root, 0);
  return Buffer.concat(contents).toString("utf8");
}

function stripAllowedDiscoveryValues(serialized, endpointPaths) {
  let sanitized = serialized;
  for (const endpointPath of endpointPaths) {
    sanitized = sanitized
      .replaceAll(endpointPath, "<structural-endpoint>")
      .replaceAll(path.dirname(endpointPath), "<structural-runtime-dir>");
  }
  return sanitized;
}

function parseSuccessfulReceipt(execution, expectedRequestId) {
  assert.equal(execution.timedOut, false, "orchestrator client command timed out");
  const errorCode = safeReceiptErrorCode(execution.stdout);
  assert.equal(
    execution.code,
    0,
    `orchestrator client command failed: ${errorCode}`,
  );
  assert.equal(execution.signal, null);
  const receipt = JSON.parse(execution.stdout);
  assert.equal(receipt.protocolVersion, protocolVersion);
  assert.equal(receipt.requestId, expectedRequestId);
  assert.equal(receipt.ok, true);
  return receipt;
}

function parseAnySuccessfulReceipt(execution) {
  assert.equal(execution.timedOut, false, "orchestrator client command timed out");
  const errorCode = safeReceiptErrorCode(execution.stdout);
  assert.equal(
    execution.code,
    0,
    `orchestrator client command failed: ${errorCode}`,
  );
  const receipt = JSON.parse(execution.stdout);
  assert.equal(receipt.protocolVersion, protocolVersion);
  assert.equal(typeof receipt.requestId, "string");
  assert.equal(receipt.requestId.length > 0 && receipt.requestId.length <= 128, true);
  assert.equal(receipt.ok, true);
  return receipt;
}

function safeReceiptErrorCode(stdout) {
  try {
    const code = JSON.parse(stdout)?.error?.code;
    return typeof code === "string" ? code : "unknown";
  } catch {
    return "unparseable";
  }
}

function parseErrorReceipt(execution, expectedCode) {
  assert.equal(execution.timedOut, false, "orchestrator client command timed out");
  assert.notEqual(execution.code, 0);
  const receipt = JSON.parse(execution.stdout);
  assert.equal(receipt.ok, false);
  assert.equal(receipt.error.code, expectedCode);
  return receipt;
}

function startService(binary, stateRoot, readyFile, acceptanceControlRoot) {
  const child = spawn(binary, [
    "orchestrator",
    "serve",
    "--state-root",
    stateRoot,
    "--ready-file",
    readyFile,
    "--acceptance-control-root",
    acceptanceControlRoot,
  ], {
    cwd: repoRoot,
    env: { ...process.env },
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  child.acceptanceOutput = "";
  child.acceptanceOutputExceeded = false;
  const collect = (chunk) => {
    child.acceptanceOutput += chunk.toString("utf8");
    if (child.acceptanceOutput.length > 64 * 1024) {
      child.acceptanceOutputExceeded = true;
      child.kill("SIGKILL");
    }
  };
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);
  child.once("error", () => {});
  return child;
}

test("IPC schema is one closed, versioned, bounded control-plane contract", async () => {
  const schema = JSON.parse(await read(schemaRef));
  assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema");
  assert.deepEqual(schema.oneOf, [
    { $ref: "#/$defs/request" },
    { $ref: "#/$defs/successReceipt" },
    { $ref: "#/$defs/errorReceipt" },
  ]);
  assert.deepEqual(enumAt(schema, "request", "protocolVersion"), [protocolVersion]);
  assert.deepEqual(enumAt(schema, "request", "method"), methods);
  assert.deepEqual(enumAt(schema, "error", "code"), stableErrors);

  const requestSchema = resolveLocalSchemaRef(schema, schema.$defs.request);
  if ("additionalProperties" in requestSchema) {
    assert.equal(requestSchema.additionalProperties, false);
  }
  assert.deepEqual(requiredFields(schema, requestSchema), [
    "protocolVersion",
    "requestId",
    "clientKind",
    "method",
    "params",
  ]);
  const requestIdSchema = propertySchema(schema, requestSchema, "requestId");
  const idempotencySchema = propertySchema(schema, requestSchema, "idempotencyKey");
  const clientKindSchema = propertySchema(schema, requestSchema, "clientKind");
  assert.equal(requestIdSchema.maxLength > 0, true);
  assert.equal(requestIdSchema.maxLength <= 128, true);
  assert.equal(idempotencySchema.maxLength <= 128, true);
  assert.equal(clientKindSchema.enum.includes("codex-mcp"), true);
  assert.equal(clientKindSchema.enum.includes("desktop"), true);
  assert.equal(clientKindSchema.enum.includes("cli"), true);
  const collectedBindings = collectMethodBindings(schema, requestSchema);
  assert.equal(collectedBindings.length, methods.length);
  const paramsBindings = Object.fromEntries(collectedBindings);
  assert.deepEqual(paramsBindings, Object.fromEntries(
    Object.entries(paramsDefinitionByMethod).map(([method, definition]) => [
      method,
      `#/$defs/${definition}`,
    ]),
  ));
  for (const definition of Object.values(paramsDefinitionByMethod)) {
    const paramsSchema = resolveLocalSchemaRef(schema, schema.$defs[definition]);
    if ("additionalProperties" in paramsSchema) {
      assert.equal(paramsSchema.additionalProperties, false, definition);
    }
    assertClosedAndBounded(schema, paramsSchema, definition);
  }

  const successReceipt = resolveLocalSchemaRef(schema, schema.$defs.successReceipt);
  if ("additionalProperties" in successReceipt) {
    assert.equal(successReceipt.additionalProperties, false);
  }
  assert.deepEqual(requiredFields(schema, successReceipt), [
    "protocolVersion",
    "requestId",
    "ok",
    "result",
  ]);
  assert.equal(propertySchema(schema, successReceipt, "ok").const, true);
  assert.deepEqual(propertySchema(schema, successReceipt, "protocolVersion").enum, [protocolVersion]);

  const errorReceipt = resolveLocalSchemaRef(schema, schema.$defs.errorReceipt);
  if ("additionalProperties" in errorReceipt) {
    assert.equal(errorReceipt.additionalProperties, false);
  }
  assert.deepEqual(requiredFields(schema, errorReceipt), [
    "protocolVersion",
    "requestId",
    "ok",
    "error",
  ]);
  assert.equal(propertySchema(schema, errorReceipt, "ok").const, false);
  assert.deepEqual(propertySchema(schema, errorReceipt, "protocolVersion").enum, [protocolVersion]);
  assert.notEqual(propertySchema(schema, errorReceipt, "error"), undefined);
  assertClosedAndBounded(schema, successReceipt, "successReceipt");
  assertClosedAndBounded(schema, errorReceipt, "errorReceipt");

  const events = resolveLocalSchemaRef(schema, schema.$defs.workflowEventsParams);
  assert.deepEqual(requiredFields(schema, events), ["workflowId", "afterCursor", "limit"]);
  assert.equal(propertySchema(schema, events, "afterCursor").minimum, 0);
  assert.equal(propertySchema(schema, events, "limit").minimum, 1);
  assert.equal(propertySchema(schema, events, "limit").maximum <= 256, true);

  const serialized = JSON.stringify(schema).toLowerCase();
  for (const forbidden of [
    "prompt",
    "reasoning",
    "credential",
    "accountidentifier",
    "nativesessionid",
    "rawoutput",
    "filepath",
    "filename",
    "modelid",
    "strategy",
  ]) {
    assert.equal(serialized.includes(forbidden), false, forbidden);
  }

  const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);
  const statusRequest = request("service.status", {});
  const stopRequest = request(
    "service.stop",
    {},
    { idempotencyKey: "stop-synthetic-schema" },
  );
  const workflowStatusRequest = request("workflow.status", {
    workflowId: "workflow-synthetic",
  });
  const eventsRequest = request("workflow.events", {
    workflowId: "workflow-synthetic",
    afterCursor: 0,
    limit: 32,
  });
  const cancelRequest = request(
    "workflow.cancel",
    { workflowId: "workflow-synthetic" },
    { idempotencyKey: "cancel-synthetic-1" },
  );
  const submitRequest = request(
    "workflow.submit",
    {
      policyRevisionId: "policy-synthetic",
      inputArtifactHandle: "artifact-synthetic",
      inputDigest: "a".repeat(64),
    },
    { idempotencyKey: "submit-synthetic-1" },
  );
  const waitRequest = request("workflow.wait", {
    workflowId: "workflow-synthetic",
    afterCursor: 0,
    limit: 64,
    timeoutMs: 30_000,
  });
  const messageRequest = request(
    "workflow.message",
    {
      workflowId: "workflow-synthetic",
      messageArtifactHandle: "message-artifact-synthetic",
      messageDigest: "b".repeat(64),
    },
    { idempotencyKey: "message-synthetic-1" },
  );
  const approveRequest = request(
    "workflow.approve",
    {
      workflowId: "workflow-synthetic",
      approvalId: "approval-synthetic",
      decision: "approved",
    },
    { idempotencyKey: "approve-synthetic-1" },
  );
  assertSchemaSample(validate, statusRequest, true, "status request");
  assertSchemaSample(validate, stopRequest, true, "stop mutation");
  assertSchemaSample(validate, workflowStatusRequest, true, "workflow status request");
  assertSchemaSample(validate, eventsRequest, true, "events request");
  assertSchemaSample(validate, cancelRequest, true, "idempotent mutation");
  assertSchemaSample(validate, submitRequest, true, "submit mutation");
  assertSchemaSample(validate, waitRequest, true, "bounded wakeable wait");
  assertSchemaSample(validate, messageRequest, true, "digest-bound child message");
  assertSchemaSample(validate, approveRequest, true, "approve mutation");
  assertSchemaSample(validate, {
    protocolVersion,
    requestId: "receipt-success",
    ok: true,
    result: { state: "running", cursor: 0 },
  }, true, "success receipt");
  assertSchemaSample(validate, {
    protocolVersion,
    requestId: "receipt-error",
    ok: false,
    error: { code: "operation_forbidden" },
  }, true, "error receipt");

  assertSchemaSample(validate, {
    ...statusRequest,
    params: eventsRequest.params,
  }, false, "method and params mismatch");
  for (const mutation of [
    stopRequest,
    submitRequest,
    cancelRequest,
    approveRequest,
    messageRequest,
  ]) {
    const { idempotencyKey: _omitted, ...withoutIdempotency } = mutation;
    assertSchemaSample(
      validate,
      withoutIdempotency,
      false,
      `${mutation.method} without idempotency key`,
    );
  }
  assertSchemaSample(validate, {
    ...statusRequest,
    unexpected: true,
  }, false, "extra request field");
  assertSchemaSample(validate, {
    ...statusRequest,
    params: { unexpected: true },
  }, false, "extra params field");
  assertSchemaSample(validate, {
    ...eventsRequest,
    params: { ...eventsRequest.params, limit: 257 },
  }, false, "event page over bound");
  assertSchemaSample(validate, {
    ...waitRequest,
    params: { ...waitRequest.params, timeoutMs: 30_001 },
  }, false, "wait over bound");
  assertSchemaSample(validate, {
    ...statusRequest,
    requestId: "x".repeat(129),
  }, false, "request id over bound");
  assertSchemaSample(validate, {
    ...submitRequest,
    params: { ...submitRequest.params, inputDigest: "a".repeat(65) },
  }, false, "digest over bound");
  for (const field of ["prompt", "reasoning", "credential", "rawOutput"]) {
    assertSchemaSample(validate, {
      ...cancelRequest,
      params: { ...cancelRequest.params, [field]: "synthetic-private-canary" },
    }, false, `privacy field ${field}`);
  }
  assertSchemaSample(validate, {
    protocolVersion,
    requestId: "receipt-extra",
    ok: false,
    error: { code: "operation_forbidden" },
    extra: true,
  }, false, "extra receipt field");
  assertSchemaSample(validate, {
    protocolVersion,
    requestId: "receipt-result-extra",
    ok: true,
    result: { state: "running", cursor: 0, rawOutput: "synthetic-private-canary" },
  }, false, "extra private receipt result field");
});

test("Rust import normalization preserves lifetimes and labels before imports", () => {
  const synthetic = `
fn require_static<T: 'static>() {}
fn labeled() { 'retry: loop { break 'retry; } }
const MARKER: char = 'x';
use crate::platform::orchestrator_ipc::Server as IpcServer;
use crate::platform::{
  orchestrator_ipc::{Client as IpcClient},
  orchestrator_service as service,
};
`;
  assert.deepEqual(canonicalRustImports(synthetic), [
    "crate::platform::orchestrator_ipc::client",
    "crate::platform::orchestrator_ipc::server",
    "crate::platform::orchestrator_service",
  ]);
});

test("private service source owns local IPC admission and bounded lifecycle only", async () => {
  const sources = await readSources();
  const ipc = `${sources[`${ipcRoot}/mod.rs`]}\n${sources[`${ipcRoot}/client.rs`]}`;
  const lifecycle = sources["crates/licoup-native/src/platform/orchestrator_service.rs"];
  const cli = sources["crates/licoup-native/src/bin/licoup/orchestrator.rs"];
  const platform = sources["crates/licoup-native/src/platform/mod.rs"];
  const ownedSource = `${ipc}\n${lifecycle}\n${cli}`;
  const joined = ownedSource.toLowerCase();

  for (const required of [
    "OrchestratorIpcServer",
    "OrchestratorIpcClient",
    "OrchestratorIpcHandler",
    "MAX_FRAME_BYTES",
    "MAX_CONNECTIONS",
    "MAX_REQUESTS_PER_WINDOW",
    "protocol_mismatch",
    "peer_rejected",
    "rate_limited",
  ]) assert.equal(ipc.includes(required), true, required);

  for (const required of [
    "OrchestratorServiceLifecycle",
    "discover_or_start",
    "rotate",
    "drain",
    "stop",
  ]) assert.equal(lifecycle.includes(required), true, required);

  assert.match(platform, /pub\s+mod\s+orchestrator_ipc\s*;/u);
  assert.match(platform, /pub\s+mod\s+orchestrator_service\s*;/u);
  for (const retained of [
    /mod\s+acp_driver_runtime\s*;/u,
    /mod\s+conversation_lane\s*;/u,
    /mod\s+process_supervisor\s*;/u,
    /pub\s+mod\s+runtime_adapters\s*;/u,
    /pub\s+use\s+conversation_lane\s*::\s*\{/u,
  ]) assert.match(platform, retained);
  assert.doesNotMatch(platform, /include!\s*\(/u);
  assert.doesNotMatch(platform, /#\s*\[\s*path\s*=/u);
  assert.doesNotMatch(platform, /platform_exports/u);

  const imports = canonicalRustImports(ownedSource);
  const platformImports = imports.flatMap((entry) => {
    const match = /^(?:crate|licoup_native)::platform::([a-z][a-z0-9_]*)/u.exec(entry);
    return match ? [match[1]] : [];
  });
  assert.equal(platformImports.length > 0, true);

  for (const forbidden of [
    "tcplistener",
    "tcpstream",
    "udpsocket",
    "127.0.0.1",
    "localhost",
    "conversation_lane",
    "agentconversationdriver",
    "policyevaluator",
    "compile_policy",
  ]) assert.equal(joined.includes(forbidden), false, forbidden);
  for (const imported of imports) {
    assert.doesNotMatch(
      imported,
      /(?:^|::)(?:policy|routing|route_selector|[a-z0-9_]*adapters?)(?:::|$)/u,
    );
  }

  const controlPlane = `${ipc}\n${cli}`;
  const controlPlaneImports = canonicalRustImports(controlPlane);
  for (const imported of controlPlaneImports) {
    assert.doesNotMatch(imported, /^std::process::command(?:::|$)/u);
  }
  const literals = rustStringLiterals(controlPlane);
  for (const literal of literals) {
    assert.doesNotMatch(literal, /^(?:frontend|backend|planner)$/u);
    assert.doesNotMatch(literal, /(?:kimi|claude|deepseek|gpt-)/u);
  }
  assert.doesNotMatch(
    controlPlane,
    /(?:std::process::)?command::new\s*\(\s*["'][^"']+["']/iu,
  );
});

test("CLI is a thin client of the same IPC request and receipt schema", async () => {
  const sources = await readSources();
  const cli = sources["crates/licoup-native/src/bin/licoup/orchestrator.rs"];
  for (const command of [
    "serve",
    "status",
    "stop",
    "submit",
    "workflow-status",
    "cancel",
    "approve",
    "events",
  ]) assert.equal(cli.includes(command), true, command);
  assert.equal(cli.includes("OrchestratorIpcClient"), true);
  assert.equal(cli.includes("OrchestratorIpcRequest"), true);
  assert.equal(cli.includes("OrchestratorIpcReceipt"), true);
  for (const forbidden of [
    "conversation_lane",
    "Command::new(\"kimi",
    "Command::new(\"claude",
    "PolicyEvaluator",
  ]) assert.equal(cli.includes(forbidden), false, forbidden);
});

test("frozen external Rust harness observes pre-handler fault behavior", () => {
  const metadata = spawnSync("cargo", [
    "metadata",
    "--no-deps",
    "--format-version",
    "1",
    "--manifest-path",
    path.join(repoRoot, "crates/licoup-native/Cargo.toml"),
  ], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
    timeout: 30_000,
  });
  assert.equal(metadata.status, 0, "cargo metadata failed for frozen harness");
  const expectedSource = path.join(
    repoRoot,
    "crates/licoup-native/tests/orchestrator_ipc_acceptance.rs",
  );
  const targets = JSON.parse(metadata.stdout).packages
    .flatMap((pkg) => pkg.targets)
    .filter((target) => target.name === "orchestrator_ipc_acceptance");
  assert.equal(targets.length, 1);
  assert.deepEqual(targets[0].kind, ["test"]);
  assert.equal(path.resolve(targets[0].src_path), expectedSource);
  const result = runFrozenRustHarness();
  assert.equal(result.status, 0, "orchestrator IPC acceptance harness failed");
});

test("normal macOS CLI auto-authenticates, auto-starts, reuses, and crash-recovers", {
  skip: process.platform !== "darwin",
}, async () => {
  const build = spawnSync(process.execPath, [
    path.join(repoRoot, "tools/scripts/cargo-client.mjs"),
    "build",
    "--manifest-path",
    path.join(repoRoot, "crates/licoup-native/Cargo.toml"),
    "--bin",
    "licoup",
  ], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
    timeout: 180_000,
  });
  assert.equal(build.status, 0, "normal bootstrap binary did not build");
  const binary = path.join(repoRoot, NATIVE_CARGO_TEST_TARGET, "debug", "licoup");
  const stateRoot = await fs.mkdtemp(path.join(os.tmpdir(), "lico-normal-bootstrap-"));
  const environment = { LICOUP_STATE_ROOT: stateRoot };
  const statusArgs = ["orchestrator", "status"];
  const outputs = [];
  let lastDiscovery = null;
  try {
    assert.equal(statusArgs.join(" ").includes(stateRoot), false);
    assert.equal(statusArgs.includes("--capability-handle"), false);
    assert.equal(statusArgs.some((arg) => arg.startsWith("--acceptance")), false);
    assert.equal(statusArgs.includes("--ready-file"), false);
    const firstExecution = await runBinary(binary, statusArgs, 10_000, environment);
    const first = parseAnySuccessfulReceipt(firstExecution);
    outputs.push(firstExecution.stdout, firstExecution.stderr);

    const discoveryPath = path.join(stateRoot, "orchestrator.discovery.json");
    const capabilityPath = path.join(stateRoot, "orchestrator.capability");
    const [discoveryStat, capabilityStat, rootStat] = await Promise.all([
      fs.lstat(discoveryPath),
      fs.lstat(capabilityPath),
      fs.lstat(stateRoot),
    ]);
    assert.equal(rootStat.isDirectory(), true);
    assert.equal(discoveryStat.isFile(), true);
    assert.equal(capabilityStat.isFile(), true);
    assert.equal(rootStat.mode & 0o777, 0o700);
    assert.equal(discoveryStat.mode & 0o777, 0o600);
    assert.equal(capabilityStat.mode & 0o777, 0o600);
    const capability = await fs.readFile(capabilityPath);
    assert.equal(capability.length >= 32, true);
    const discovery = JSON.parse(await fs.readFile(discoveryPath, "utf8"));
    lastDiscovery = discovery;
    assert.equal(discovery.endpointGeneration, first.result.endpointGeneration);
    assert.equal(discovery.serviceInstanceId, first.result.serviceInstanceId);
    assert.equal(path.isAbsolute(discovery.endpointPath), true);
    assert.equal(path.normalize(discovery.endpointPath), discovery.endpointPath);
    assert.equal(discovery.endpointPath.startsWith(`${stateRoot}${path.sep}`), false);
    assert.equal(Buffer.byteLength(discovery.endpointPath, "utf8") <= 100, true);
    const runtimeDirectory = path.dirname(discovery.endpointPath);
    const [runtimeStat, endpointStat] = await Promise.all([
      fs.lstat(runtimeDirectory),
      fs.lstat(discovery.endpointPath),
    ]);
    assert.equal(runtimeStat.mode & 0o777, 0o700);
    assert.equal(runtimeStat.isDirectory(), true);
    assert.equal(runtimeStat.uid, process.getuid());
    assert.equal(endpointStat.isSocket(), true);
    assert.equal(endpointStat.mode & 0o777, 0o600);
    const serviceCommand = readMacProcessCommand(discovery.servicePid);
    const orchestratorOffset = serviceCommand.lastIndexOf("orchestrator");
    assert.equal(orchestratorOffset >= 0, true, "service argv lacks orchestrator command");
    const serviceArguments = serviceCommand.slice(orchestratorOffset);
    assert.equal(
      /^orchestrator serve(?: --(?:autostarted|background-service|owner-private))*$/u
        .test(serviceArguments),
      true,
      "service argv contains an unapproved flag",
    );
    for (const forbidden of [
      stateRoot,
      discoveryPath,
      capabilityPath,
      runtimeDirectory,
      discovery.endpointPath,
      capability.toString("hex"),
      capability.toString("base64"),
    ]) {
      assert.equal(serviceCommand.includes(forbidden), false, "service argv exposed private material");
    }
    assert.doesNotMatch(
      serviceCommand,
      /(?:capability|credential|password|secret|token|private[-_]?path)/iu,
      "service argv exposed a secret-bearing argument",
    );

    const secondExecution = await runBinary(binary, statusArgs, 10_000, environment);
    const second = parseAnySuccessfulReceipt(secondExecution);
    outputs.push(secondExecution.stdout, secondExecution.stderr);
    assert.equal(secondExecution.pid === firstExecution.pid, false);
    assert.equal(second.result.serviceInstanceId, first.result.serviceInstanceId);
    assert.equal(second.result.endpointGeneration, first.result.endpointGeneration);

    process.kill(discovery.servicePid, "SIGKILL");
    assert.equal(await waitForPidExit(discovery.servicePid), true);
    const recoveredExecution = await runBinary(binary, statusArgs, 10_000, environment);
    if (recoveredExecution.code !== 0) {
      const failedDiscovery = JSON.parse(await fs.readFile(discoveryPath, "utf8"));
      const replacementAlive = !await waitForPidExit(failedDiscovery.servicePid, 1);
      assert.fail(
        `orchestrator recovery failed: ${safeReceiptErrorCode(recoveredExecution.stdout)}; `
          + `generationRotated=${failedDiscovery.endpointGeneration !== discovery.endpointGeneration}; `
          + `instanceRotated=${failedDiscovery.serviceInstanceId !== discovery.serviceInstanceId}; `
          + `replacementAlive=${replacementAlive}`,
      );
    }
    const recovered = parseAnySuccessfulReceipt(recoveredExecution);
    outputs.push(recoveredExecution.stdout, recoveredExecution.stderr);
    const recoveredDiscovery = JSON.parse(await fs.readFile(discoveryPath, "utf8"));
    lastDiscovery = recoveredDiscovery;
    assert.notEqual(recovered.result.serviceInstanceId, first.result.serviceInstanceId);
    assert.notEqual(recovered.result.endpointGeneration, first.result.endpointGeneration);
    assert.notEqual(recoveredDiscovery.endpointPath, discovery.endpointPath);
    assert.equal(Buffer.byteLength(recoveredDiscovery.endpointPath, "utf8") <= 100, true);

    const stopExecution = await runBinary(
      binary,
      ["orchestrator", "stop", "--idempotency-key", "normal-stop"],
      10_000,
      environment,
    );
    outputs.push(stopExecution.stdout, stopExecution.stderr);
    assert.equal(stopExecution.code, 0);
    const projected = outputs.join("\n");
    for (const forbidden of [
      stateRoot,
      discovery.endpointPath,
      recoveredDiscovery.endpointPath,
      capability.toString("utf8"),
      "--capability-handle",
    ]) assert.equal(projected.includes(forbidden), false);
  } finally {
    if (lastDiscovery?.servicePid && !await waitForPidExit(lastDiscovery.servicePid, 1)) {
      try { process.kill(lastDiscovery.servicePid, "SIGKILL"); } catch {}
      await waitForPidExit(lastDiscovery.servicePid);
    }
    await fs.rm(stateRoot, { recursive: true, force: true });
  }
});

test("real private endpoint proves cross-process auth, reconnect, rotation, and drain", {
  skip: process.platform !== "darwin",
}, async () => {
  const build = spawnSync(process.execPath, [
    path.join(repoRoot, "tools/scripts/cargo-client.mjs"),
    "build",
    "--manifest-path",
    path.join(repoRoot, "crates/licoup-native/Cargo.toml"),
    "--bin",
    "licoup",
  ], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
    timeout: 180_000,
  });
  assert.equal(build.status, 0, "licoup acceptance binary did not build");
  const binary = path.join(
    repoRoot,
    NATIVE_CARGO_TEST_TARGET,
    "debug",
    process.platform === "win32" ? "licoup.exe" : "licoup",
  );
  const stateRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "lico-orchestrator-acceptance-"),
  );
  const fixtureRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), "lico-orchestrator-fixtures-"),
  );
  const readyOne = path.join(fixtureRoot, "ready-one.json");
  const readyTwo = path.join(fixtureRoot, "ready-two.json");
  const controlRoot = path.join(fixtureRoot, "server-control");
  let service = startService(binary, stateRoot, readyOne, controlRoot);
  let firstServiceOutput = "";
  const auxiliaryChildren = [];
  try {
    const firstServicePid = service.pid;
    const firstReady = await waitForJson(readyOne);
    assert.equal(firstReady.protocolVersion, protocolVersion);
    assert.equal(firstReady.state, "running");
    assert.equal(firstReady.ownerPrivate, true);
    assert.equal(firstReady.admission, "owner-private");
    assert.equal(typeof firstReady.endpointGeneration, "string");
    assert.equal(firstReady.endpointGeneration.length > 0, true);
    for (const capability of [
      firstReady.capabilities?.workflow,
      firstReady.capabilities?.statusOnly,
      firstReady.capabilities?.lifecycle,
    ]) {
      assert.equal(typeof capability, "string");
      assert.equal(capability.length >= 32, true);
    }
    assert.equal(path.resolve(firstReady.endpointPath).startsWith(`${stateRoot}${path.sep}`), false);
    assert.equal(path.resolve(firstReady.discoveryPath).startsWith(`${stateRoot}${path.sep}`), true);
    assert.equal(path.normalize(firstReady.endpointPath), firstReady.endpointPath);
    assert.equal(Buffer.byteLength(firstReady.endpointPath, "utf8") <= 100, true);
    if (process.platform === "darwin") {
      const [rootStat, runtimeStat, endpointStat, discoveryStat, readyStat] = await Promise.all([
        fs.stat(stateRoot),
        fs.stat(path.dirname(firstReady.endpointPath)),
        fs.lstat(firstReady.endpointPath),
        fs.stat(firstReady.discoveryPath),
        fs.stat(readyOne),
      ]);
      assert.equal(rootStat.mode & 0o777, 0o700);
      assert.equal(runtimeStat.mode & 0o777, 0o700);
      assert.equal(runtimeStat.uid, process.getuid());
      assert.equal(endpointStat.isSocket(), true);
      assert.equal(endpointStat.mode & 0o777, 0o600);
      assert.equal(discoveryStat.isFile(), true);
      assert.equal(discoveryStat.mode & 0o777, 0o600);
      assert.equal(readyStat.mode & 0o777, 0o600);
    }
    const competingReady = path.join(fixtureRoot, "ready-competing.json");
    const competingServe = await runBinary(binary, [
      "orchestrator", "serve", "--state-root", stateRoot,
      "--ready-file", competingReady,
    ], 3_000);
    parseErrorReceipt(competingServe, "service_already_running");
    await assert.rejects(fs.access(competingReady));

    const registerRequest = request(
      "policy.register",
      { policy: acceptancePolicy() },
      { idempotencyKey: "register-synthetic-1" },
    );
    const registerFile = await writeRequest(
      fixtureRoot,
      "register-policy",
      registerRequest,
    );
    const registerExecution = await runBinary(binary, [
      "orchestrator", "register-policy", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.workflow,
      "--request-file", registerFile,
    ]);
    const registerReceipt = parseSuccessfulReceipt(
      registerExecution,
      registerRequest.requestId,
    );
    const policyRevisionId = registerReceipt.result.policyRevisionId;
    assert.equal(typeof policyRevisionId, "string");
    assert.equal(policyRevisionId.length > 0, true);

    const activateRequest = request(
      "policy.activate",
      { policyRevisionId },
      { idempotencyKey: "activate-synthetic-1" },
    );
    const activateFile = await writeRequest(
      fixtureRoot,
      "activate-policy",
      activateRequest,
    );
    const activateExecution = await runBinary(binary, [
      "orchestrator", "activate-policy", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.workflow,
      "--request-file", activateFile,
    ]);
    parseSuccessfulReceipt(activateExecution, activateRequest.requestId);

    const inputArtifactHandle = "artifact-ipc-synthetic";
    const inputArtifact = Buffer.from("synthetic IPC input", "utf8");
    const inputDigest = createHash("sha256").update(inputArtifact).digest("hex");
    await fs.writeFile(
      path.join(stateRoot, "artifacts", `${inputArtifactHandle}.txt`),
      inputArtifact,
      { mode: 0o600 },
    );
    const submitRequest = request("workflow.submit", {
      policyRevisionId,
      inputArtifactHandle,
      inputDigest,
    }, { idempotencyKey: "submit-synthetic-1" });
    const submitFile = await writeRequest(fixtureRoot, "submit", submitRequest);
    const submitExecution = await runBinary(binary, [
      "orchestrator", "submit", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.workflow,
      "--request-file", submitFile,
    ]);
    const submitReceipt = parseSuccessfulReceipt(
      submitExecution,
      submitRequest.requestId,
    );
    assert.equal(typeof submitReceipt.result.workflowId, "string");
    assert.equal(submitReceipt.result.workflowId.length > 0, true);

    const statusRequest = request("workflow.status", {
      workflowId: submitReceipt.result.workflowId,
    });
    const statusFile = await writeRequest(fixtureRoot, "workflow-status", statusRequest);
    const statusExecution = await runBinary(binary, [
      "orchestrator", "workflow-status", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.workflow,
      "--request-file", statusFile,
    ]);
    const statusReceipt = parseSuccessfulReceipt(statusExecution, statusRequest.requestId);
    assert.equal(statusReceipt.result.workflowId, submitReceipt.result.workflowId);
    assert.equal(statusReceipt.result.state, "awaiting_approval");
    assert.equal(typeof statusReceipt.result.approvalId, "string");
    assert.equal(statusReceipt.result.approvalId.length > 0, true);

    const eventsRequest = request("workflow.events", {
      workflowId: submitReceipt.result.workflowId,
      afterCursor: 0,
      limit: 32,
    });
    const eventsFile = await writeRequest(fixtureRoot, "events-one", eventsRequest);
    const eventsExecution = await runBinary(binary, [
      "orchestrator", "events", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.workflow,
      "--request-file", eventsFile,
    ]);
    const eventsReceipt = parseSuccessfulReceipt(eventsExecution, eventsRequest.requestId);
    assert.equal(Array.isArray(eventsReceipt.result.events), true);
    assert.equal(eventsReceipt.result.events.length > 0, true);
    const reconnectCursor = eventsReceipt.result.nextCursor;
    assert.equal(Number.isSafeInteger(reconnectCursor), true);

    // Leave the workflow at its durable approval boundary. This endpoint test
    // exercises transport isolation and cancellation without invoking a real
    // machine-installed agent or a process-local fake adapter.
    const stableCursor = reconnectCursor;

    const transportStatusRequest = request("service.status", {});
    const transportStatusFile = await writeRequest(
      fixtureRoot,
      "transport-status",
      transportStatusRequest,
    );
    const transportBeforeExecution = await runBinary(binary, [
      "orchestrator", "status", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.statusOnly,
      "--request-file", transportStatusFile,
    ]);
    const transportBefore = parseSuccessfulReceipt(
      transportBeforeExecution,
      transportStatusRequest.requestId,
    ).result.transportDiagnostics;
    for (const counter of ["transportClosed", "preHandlerRejected", "handlerMutations"]) {
      assert.equal(Number.isSafeInteger(transportBefore[counter]), true, counter);
    }

    assert.equal(Number.isSafeInteger(firstReady.maxFrameBytes), true);
    assert.equal(firstReady.maxFrameBytes >= 1_024, true);
    const rawHandshake = {
      protocolVersion,
      clientKind: "cli",
      connectionNonce: "n".repeat(32),
      capabilityHandle: firstReady.capabilities.workflow,
    };
    const halfCloseRequest = request("workflow.status", {
      workflowId: submitReceipt.result.workflowId,
    });
    const rawFaultResults = [];
    for (const fault of ["oversize", "truncated", "half-close", "abrupt"]) {
      const observed = await rawSocketFault(
        firstReady.endpointPath,
        { ...rawHandshake, connectionNonce: `${fault}-nonce`.padEnd(32, "n") },
        fault,
        firstReady.maxFrameBytes,
        halfCloseRequest,
      );
      assert.equal(observed.timedOut, false, `${fault} socket fault timed out`);
      assert.equal(observed.raw.length <= 64 * 1024, true, `${fault} reply exceeded bound`);
      rawFaultResults.push(observed);
      if (fault === "oversize" || fault === "truncated") {
        const expected = fault === "oversize" ? "frame_too_large" : "frame_truncated";
        assert.equal(
          observed.frames.some((frame) => frame.error?.code === expected),
          true,
          `${fault} must return stable framing error`,
        );
      } else if (fault === "half-close") {
        assert.equal(
          observed.frames.some((frame) => (
            frame.requestId === halfCloseRequest.requestId && frame.ok === true
          )),
          true,
          "half-close must preserve the admitted response",
        );
      } else if (fault === "abrupt") {
        assert.equal(
          observed.frames.some((frame) => frame.requestId === halfCloseRequest.requestId),
          false,
          "no request receipt may exist after headerless disconnect",
        );
      }
    }
    let transportAfterExecution = null;
    let transportAfter = null;
    for (let attempt = 0; attempt < 20; attempt += 1) {
      transportAfterExecution = await runBinary(binary, [
        "orchestrator", "status", "--state-root", stateRoot,
        "--capability-handle", firstReady.capabilities.statusOnly,
        "--request-file", transportStatusFile,
      ], 500);
      if (!transportAfterExecution.timedOut && transportAfterExecution.code === 0) {
        transportAfter = parseSuccessfulReceipt(
          transportAfterExecution,
          transportStatusRequest.requestId,
        ).result.transportDiagnostics;
        if (transportAfter.transportClosed >= transportBefore.transportClosed + 1) break;
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.notEqual(transportAfter, null, "transport diagnostics did not advance");
    assert.equal(transportAfter.transportClosed, transportBefore.transportClosed + 1);
    assert.equal(transportAfter.preHandlerRejected >= transportBefore.preHandlerRejected + 3, true);
    assert.equal(transportAfter.handlerMutations, transportBefore.handlerMutations);
    assert.equal(transportAfter.lastErrorCode, "transport_closed");
    const healthyAfterFaultsExecution = await runBinary(binary, [
      "orchestrator", "workflow-status", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.workflow,
      "--request-file", statusFile,
    ]);
    const healthyAfterFaults = parseSuccessfulReceipt(
      healthyAfterFaultsExecution,
      statusRequest.requestId,
    );
    assert.deepEqual(healthyAfterFaults.result, statusReceipt.result);
    const noMutationEventsRequest = request("workflow.events", {
      workflowId: submitReceipt.result.workflowId,
      afterCursor: stableCursor,
      limit: 32,
    });
    const noMutationEventsFile = await writeRequest(
      fixtureRoot,
      "events-after-faults",
      noMutationEventsRequest,
    );
    const noMutationEventsExecution = await runBinary(binary, [
      "orchestrator", "events", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.workflow,
      "--request-file", noMutationEventsFile,
    ]);
    const noMutationEvents = parseSuccessfulReceipt(
      noMutationEventsExecution,
      noMutationEventsRequest.requestId,
    );
    assert.deepEqual(noMutationEvents.result.events, []);
    assert.equal(noMutationEvents.result.nextCursor, stableCursor);

    const cancelRequest = request("workflow.cancel", {
      workflowId: submitReceipt.result.workflowId,
    }, { idempotencyKey: "cancel-synthetic-1" });
    const cancelFile = await writeRequest(fixtureRoot, "cancel", cancelRequest);
    const cancelExecution = await runBinary(binary, [
      "orchestrator", "cancel", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.workflow,
      "--request-file", cancelFile,
    ]);
    parseSuccessfulReceipt(cancelExecution, cancelRequest.requestId);

    const reconnectRequest = request("workflow.events", {
      workflowId: submitReceipt.result.workflowId,
      afterCursor: stableCursor,
      limit: 32,
    });
    const reconnectFile = await writeRequest(fixtureRoot, "events-reconnect", reconnectRequest);
    const reconnectExecution = await runBinary(binary, [
      "orchestrator", "events", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.workflow,
      "--request-file", reconnectFile,
    ]);
    const reconnectReceipt = parseSuccessfulReceipt(
      reconnectExecution,
      reconnectRequest.requestId,
    );
    assert.equal(reconnectReceipt.result.events.length > 0, true);
    assert.equal(
      reconnectReceipt.result.events.every((event) => event.cursor > stableCursor),
      true,
    );

    const privateStop = request(
      "service.stop",
      {
        prompt: privacyCanaries[4],
        credential: privacyCanaries[1],
        accountIdentifier: privacyCanaries[0],
        nativeSessionId: privacyCanaries[3],
        filePath: privacyCanaries[2],
      },
      { idempotencyKey: "private-stop-synthetic" },
    );
    const privateStopFile = await writeRequest(
      fixtureRoot,
      "private-invalid-stop",
      privateStop,
    );
    const privateStopExecution = await runBinary(binary, [
      "orchestrator", "stop", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.lifecycle,
      "--request-file", privateStopFile,
    ]);
    parseErrorReceipt(privateStopExecution, "invalid_request");
    const livePersistedState = stripAllowedDiscoveryValues(
      await readBoundedRegularFiles(stateRoot),
      [firstReady.endpointPath],
    );
    const livePrivacyCorpus = [
      service.acceptanceOutput,
      privateStopExecution.stdout,
      privateStopExecution.stderr,
      livePersistedState,
    ].join("\n");
    for (const canary of privacyCanaries) {
      assert.equal(livePrivacyCorpus.includes(canary), false, canary);
    }
    for (const capability of Object.values(firstReady.capabilities)) {
      assert.equal(livePrivacyCorpus.includes(capability), false);
    }
    for (const privatePath of [stateRoot, fixtureRoot, firstReady.endpointPath]) {
      assert.equal(livePrivacyCorpus.includes(privatePath), false, "live private path persisted");
    }
    const normalizedLivePrivacy = livePrivacyCorpus.toLowerCase();
    for (const rawField of [
      '"prompt"',
      '"reasoning"',
      '"credential"',
      '"accountidentifier"',
      '"nativesessionid"',
      '"filepath"',
      '"rawoutput"',
    ]) {
      assert.equal(normalizedLivePrivacy.includes(rawField), false, rawField);
    }

    const forbiddenStop = request(
      "service.stop",
      {},
      { idempotencyKey: "forbidden-stop-synthetic" },
    );
    const forbiddenFile = await writeRequest(fixtureRoot, "forbidden-stop", forbiddenStop);
    const forbiddenExecution = await runBinary(binary, [
      "orchestrator", "stop", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.statusOnly,
      "--request-file", forbiddenFile,
    ]);
    parseErrorReceipt(forbiddenExecution, "operation_forbidden");

    const liveStatusRequest = request("service.status", {});
    const liveStatusFile = await writeRequest(
      fixtureRoot,
      "service-status-after-forbidden",
      liveStatusRequest,
    );
    const liveStatusExecution = await runBinary(binary, [
      "orchestrator", "status", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.statusOnly,
      "--request-file", liveStatusFile,
    ]);
    const liveStatusReceipt = parseSuccessfulReceipt(
      liveStatusExecution,
      liveStatusRequest.requestId,
    );
    assert.equal(liveStatusReceipt.result.state, "running");

    const missingCapabilityExecution = await runBinary(binary, [
      "orchestrator", "status", "--state-root", stateRoot,
      "--request-file", liveStatusFile,
    ]);
    parseErrorReceipt(missingCapabilityExecution, "capability_missing");
    const forgedCapability = "f".repeat(64);
    const forgedCapabilityExecution = await runBinary(binary, [
      "orchestrator", "status", "--state-root", stateRoot,
      "--capability-handle", forgedCapability,
      "--request-file", liveStatusFile,
    ]);
    parseErrorReceipt(forgedCapabilityExecution, "capability_rejected");
    const healthyAfterCapabilityReject = await runBinary(binary, [
      "orchestrator", "status", "--state-root", stateRoot,
      "--capability-handle", firstReady.capabilities.statusOnly,
      "--request-file", liveStatusFile,
    ]);
    parseSuccessfulReceipt(healthyAfterCapabilityReject, liveStatusRequest.requestId);

    const pidSet = new Set([
      firstServicePid,
      competingServe.pid,
      registerExecution.pid,
      activateExecution.pid,
      submitExecution.pid,
      statusExecution.pid,
      eventsExecution.pid,
      transportBeforeExecution.pid,
      transportAfterExecution.pid,
      healthyAfterFaultsExecution.pid,
      noMutationEventsExecution.pid,
      cancelExecution.pid,
      reconnectExecution.pid,
      privateStopExecution.pid,
      forbiddenExecution.pid,
      liveStatusExecution.pid,
      missingCapabilityExecution.pid,
      forgedCapabilityExecution.pid,
      healthyAfterCapabilityReject.pid,
    ]);
    assert.equal(pidSet.size, 19, "service and clients must not share process memory");

    service.kill("SIGKILL");
    assert.equal(await waitForExit(service), true);
    assert.equal(service.acceptanceOutputExceeded, false);
    firstServiceOutput = service.acceptanceOutput;
    service = startService(binary, stateRoot, readyTwo, controlRoot);
    const secondReady = await waitForJson(readyTwo);
    assert.equal(secondReady.ownerPrivate, true);
    for (const capability of Object.values(secondReady.capabilities || {})) {
      assert.equal(typeof capability, "string");
      assert.equal(capability.length >= 32, true);
    }
    assert.deepEqual(
      Object.keys(secondReady.capabilities || {}).sort(),
      ["lifecycle", "statusOnly", "workflow"],
    );
    assert.notEqual(secondReady.endpointGeneration, firstReady.endpointGeneration);
    assert.notEqual(secondReady.endpointPath, firstReady.endpointPath);
    assert.equal(secondReady.endpointPath.startsWith(`${stateRoot}${path.sep}`), false);
    assert.equal(Buffer.byteLength(secondReady.endpointPath, "utf8") <= 100, true);
    assert.notEqual(service.pid, firstServicePid);
    assert.equal(pidSet.has(service.pid), false);
    if (process.platform === "darwin") {
      const [runtimeStat, endpointStat, discoveryStat] = await Promise.all([
        fs.stat(path.dirname(secondReady.endpointPath)),
        fs.lstat(secondReady.endpointPath),
        fs.stat(secondReady.discoveryPath),
      ]);
      assert.equal(endpointStat.isSocket(), true);
      assert.equal(runtimeStat.mode & 0o777, 0o700);
      assert.equal(runtimeStat.uid, process.getuid());
      assert.equal(endpointStat.mode & 0o777, 0o600);
      assert.equal(discoveryStat.mode & 0o777, 0o600);
    }

    const stopRequest = request(
      "service.stop",
      {},
      { idempotencyKey: "stop-synthetic-1" },
    );
    const stopFile = await writeRequest(fixtureRoot, "stop", stopRequest);
    const holdId = "held-status-acceptance";
    const holdReady = path.join(controlRoot, `${holdId}.admitted.json`);
    const releaseHold = path.join(controlRoot, `${holdId}.release.json`);
    const holdCompleted = path.join(controlRoot, `${holdId}.completed.json`);
    const heldClient = startBinary(binary, [
      "orchestrator", "status", "--state-root", stateRoot,
      "--capability-handle", secondReady.capabilities.statusOnly,
      "--request-file", liveStatusFile,
      "--acceptance-hold-id", holdId,
    ], 10_000);
    auxiliaryChildren.push(heldClient.child);
    const heldAdmission = await waitForJson(holdReady);
    assert.equal(heldAdmission.state, "admitted");
    assert.equal(heldAdmission.requestId, liveStatusRequest.requestId);
    assert.equal(heldAdmission.servicePid, service.pid);
    assert.equal(heldAdmission.endpointGeneration, secondReady.endpointGeneration);
    assert.equal(heldAdmission.source, "orchestrator-service");
    assert.equal(typeof heldAdmission.admissionId, "string");
    assert.equal(heldAdmission.requestDigest.length, 64);
    assert.notEqual(heldAdmission.servicePid, heldClient.pid);
    assert.equal((await fs.stat(holdReady)).mode & 0o777, 0o600);
    const holdProofExecution = await runBinary(binary, [
      "orchestrator", "status", "--state-root", stateRoot,
      "--capability-handle", secondReady.capabilities.statusOnly,
      "--request-file", transportStatusFile,
    ]);
    const holdProof = parseSuccessfulReceipt(
      holdProofExecution,
      transportStatusRequest.requestId,
    );
    assert.equal(
      holdProof.result.admissionDiagnostics.inFlightAdmissionIds
        .includes(heldAdmission.admissionId),
      true,
      "service status must own the held admission",
    );

    const stoppingClient = startBinary(binary, [
      "orchestrator", "stop", "--state-root", stateRoot,
      "--capability-handle", secondReady.capabilities.lifecycle,
      "--request-file", stopFile,
    ], 10_000);
    auxiliaryChildren.push(stoppingClient.child);
    const stopRemainsPending = await Promise.race([
      stoppingClient.completed.then(() => false),
      new Promise((resolve) => setTimeout(() => resolve(true), 100)),
    ]);
    assert.equal(stopRemainsPending, true, "stop completed before held request release");
    let drainingExecution = null;
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const observed = await runBinary(binary, [
        "orchestrator", "status", "--state-root", stateRoot,
        "--capability-handle", secondReady.capabilities.statusOnly,
        "--request-file", liveStatusFile,
      ], 250);
      if (observed.code !== 0 && !observed.timedOut && observed.stdout.trim()) {
        const receipt = JSON.parse(observed.stdout);
        if (receipt.error?.code === "service_draining") {
          drainingExecution = observed;
          break;
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.notEqual(drainingExecution, null, "new admission must observe service_draining");
    parseErrorReceipt(drainingExecution, "service_draining");
    await fs.writeFile(releaseHold, "{\"release\":true}\n", { mode: 0o600 });
    const heldExecution = await heldClient.completed;
    const heldReceipt = parseSuccessfulReceipt(heldExecution, liveStatusRequest.requestId);
    assert.equal(heldReceipt.result.state, "running");
    const completedMarker = await waitForJson(holdCompleted);
    assert.equal(completedMarker.source, "orchestrator-service");
    assert.equal(completedMarker.servicePid, service.pid);
    assert.equal(completedMarker.admissionId, heldAdmission.admissionId);
    assert.equal(completedMarker.state, "completed");
    const stopExecution = await stoppingClient.completed;
    const stopReceipt = parseSuccessfulReceipt(stopExecution, stopRequest.requestId);
    assert.equal(stopReceipt.result.state, "stopped");
    assert.equal(await waitForExit(service), true);
    assert.equal(service.exitCode, 0);
    assert.equal(service.acceptanceOutputExceeded, false);

    const afterDrain = await runBinary(binary, [
      "orchestrator", "workflow-status", "--state-root", stateRoot,
      "--request-file", statusFile,
    ]);
    parseErrorReceipt(afterDrain, "service_unavailable");
    const projectedOutput = [
      registerExecution,
      activateExecution,
      submitExecution,
      statusExecution,
      eventsExecution,
      transportBeforeExecution,
      transportAfterExecution,
      healthyAfterFaultsExecution,
      noMutationEventsExecution,
      cancelExecution,
      reconnectExecution,
      privateStopExecution,
      forbiddenExecution,
      liveStatusExecution,
      competingServe,
      missingCapabilityExecution,
      forgedCapabilityExecution,
      healthyAfterCapabilityReject,
      stopExecution,
      heldExecution,
      holdProofExecution,
      drainingExecution,
      afterDrain,
    ].map((execution) => `${execution.stdout}\n${execution.stderr}`).join("\n");
    const rawFaultOutput = Buffer.concat(rawFaultResults.map((result) => result.raw))
      .toString("utf8");
    const allOutput = `${firstServiceOutput}\n${service.acceptanceOutput}\n${projectedOutput}\n${rawFaultOutput}`;
    const persistedState = stripAllowedDiscoveryValues(
      await readBoundedRegularFiles(stateRoot),
      [firstReady.endpointPath, secondReady.endpointPath],
    );
    const leakageCorpus = `${allOutput}\n${persistedState}`;
    for (const privatePath of [
      stateRoot,
      fixtureRoot,
      firstReady.endpointPath,
      secondReady.endpointPath,
      privacyCanaries[2],
    ]) {
      assert.equal(leakageCorpus.includes(privatePath), false, "private path projected");
    }
    for (const canary of privacyCanaries) {
      assert.equal(leakageCorpus.includes(canary), false, canary);
    }
    for (const capability of [
      ...Object.values(firstReady.capabilities),
      ...Object.values(secondReady.capabilities),
      forgedCapability,
    ]) {
      assert.equal(leakageCorpus.includes(capability), false);
    }
  } finally {
    for (const child of auxiliaryChildren) {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      await waitForExit(child);
    }
    if (service.exitCode === null && service.signalCode === null) service.kill("SIGKILL");
    await waitForExit(service);
    await fs.rm(stateRoot, { recursive: true, force: true });
    await fs.rm(fixtureRoot, { recursive: true, force: true });
  }
});

test("synthetic privacy canaries are contract-only and never expected in output", () => {
  const acceptanceSource = privacyCanaries.join("\n");
  assert.equal(acceptanceSource.includes("synthetic"), true);
  assert.equal(privacyCanaries.every((canary) => canary.length <= 64), true);
});
