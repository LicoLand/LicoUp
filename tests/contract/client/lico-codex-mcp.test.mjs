import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const pluginRoot = path.join(repoRoot, "plugins/lico-arc-codex");
const manifestPath = path.join(pluginRoot, ".codex-plugin/plugin.json");
const serverConfigPath = path.join(pluginRoot, "mcp/server.json");
const skillPath = path.join(pluginRoot, "skills/lico-arc-orchestration/SKILL.md");
const rustPath = path.join(repoRoot, "crates/lico-client-native/src/bin/lico-codex-mcp.rs");
const cargoPath = path.join(repoRoot, "crates/lico-client-native/Cargo.toml");
const packagingPath = path.join(repoRoot, "apps/desktop/packaging.modules.json");
const binaryPath = path.join(
  repoRoot,
  "build/crates/lico-client-native/target/debug",
  process.platform === "win32" ? "lico-codex-mcp.exe" : "lico-codex-mcp",
);
const releaseBinaryPath = path.join(
  repoRoot,
  "build/crates/lico-client-native/target/release",
  process.platform === "win32" ? "lico-codex-mcp.exe" : "lico-codex-mcp",
);
const activeMcpProcesses = new Set();

const protocolVersion = "2025-06-18";
const ipcProtocolVersion = "lico.orchestrator.ipc.v1";
const maxMcpFrameBytes = 64 * 1024;
const expectedTools = [
  "lico_agent_capabilities",
  "lico_strategy_preview",
  "lico_workflow_approve",
  "lico_workflow_cancel",
  "lico_workflow_message",
  "lico_workflow_status",
  "lico_workflow_submit",
  "lico_workflow_wait",
];
const expectedMethodByTool = new Map([
  ["lico_agent_capabilities", "service.status"],
  ["lico_strategy_preview", "workflow.preview"],
  ["lico_workflow_approve", "workflow.approve"],
  ["lico_workflow_cancel", "workflow.cancel"],
  ["lico_workflow_message", "workflow.message"],
  ["lico_workflow_submit", "workflow.submit"],
  ["lico_workflow_wait", "workflow.wait"],
]);
const sensitiveCanaries = Object.freeze({
  prompt: "SENSITIVE_PROMPT_CANARY_7f3a",
  reasoning: "SENSITIVE_REASONING_CANARY_b246",
  rawOutput: "SENSITIVE_RAW_OUTPUT_CANARY_5d91",
  nativeSessionId: "SENSITIVE_NATIVE_SESSION_CANARY_942e",
  privatePath: "SENSITIVE_PRIVATE_PATH_CANARY_63aa",
});

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

function fileDigest(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function canonicalPluginValidator() {
  const roots = [
    process.env.CODEX_PLUGIN_CREATOR_SKILL_ROOT,
    path.join(os.homedir(), ".codex/skills/.system/plugin-creator"),
    path.join(os.homedir(), ".agents/skills/plugin-creator"),
  ].filter(Boolean);
  const script = roots
    .map((root) => path.join(root, "scripts/validate_plugin.py"))
    .find((candidate) => existsSync(candidate));
  assert.equal(typeof script, "string", "canonical plugin-creator validator is unavailable");
  const validation = spawnSync("python3", [script, pluginRoot], {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 30_000,
    maxBuffer: 256 * 1024,
  });
  assert.equal(validation.status, 0, "canonical plugin-creator validation failed");
}

function assertClosedBoundedSchema(node, label) {
  assert.equal(node && typeof node === "object" && !Array.isArray(node), true, `${label}: schema object required`);
  for (const [index, branch] of (node.oneOf || []).entries()) {
    assertClosedBoundedSchema(branch, `${label}.oneOf[${index}]`);
  }
  for (const [index, branch] of (node.anyOf || []).entries()) {
    assertClosedBoundedSchema(branch, `${label}.anyOf[${index}]`);
  }
  if (node.type === "object" || node.properties) {
    assert.equal(node.additionalProperties, false, `${label}: object schema must be closed`);
    for (const [name, property] of Object.entries(node.properties || {})) {
      assertClosedBoundedSchema(property, `${label}.${name}`);
    }
  }
  if (node.type === "array") {
    assert.equal(Number.isSafeInteger(node.maxItems), true, `${label}: arrays must be bounded`);
    assertClosedBoundedSchema(node.items, `${label}.items`);
  }
  if (node.type === "string") {
    assert.equal(
      Number.isSafeInteger(node.maxLength) || Array.isArray(node.enum) || Object.hasOwn(node, "const"),
      true,
      `${label}: strings must be bounded`,
    );
  }
}

function collectPropertyNames(node, names = new Set()) {
  if (!node || typeof node !== "object") return names;
  for (const name of Object.keys(node.properties || {})) names.add(name);
  for (const child of Object.values(node.properties || {})) collectPropertyNames(child, names);
  for (const child of node.oneOf || []) collectPropertyNames(child, names);
  for (const child of node.anyOf || []) collectPropertyNames(child, names);
  if (node.items) collectPropertyNames(node.items, names);
  return names;
}

function buildMcpBinary(mode) {
  const releaseArguments = mode === "release" ? ["--release", "--locked"] : [];
  const result = spawnSync(
    process.execPath,
    [
      path.join(repoRoot, "tools/scripts/cargo-client.mjs"),
      "build",
      "--manifest-path",
      cargoPath,
      ...releaseArguments,
      "--bin",
      "lico-codex-mcp",
    ],
    { cwd: repoRoot, encoding: "utf8", timeout: 180_000, maxBuffer: 4 * 1024 * 1024 },
  );
  assert.equal(result.status, 0, "lico-codex-mcp must build through the managed artifact lifecycle");
  const expected = mode === "release" ? releaseBinaryPath : binaryPath;
  assert.equal(existsSync(expected), true, `managed ${mode} MCP binary is missing`);
  return expected;
}

class McpProcess {
  constructor(extraEnvironment = {}, executable = binaryPath) {
    this.child = spawn(executable, [], {
      cwd: repoRoot,
      env: {
        ...process.env,
        LICO_CODEX_MCP_ACCEPTANCE_TIMEOUT_MS: "300",
        ...extraEnvironment,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.pending = new Map();
    this.notifications = [];
    this.responseCounts = new Map();
    this.stdoutBuffer = "";
    this.stderr = "";
    this.child.stdout.setEncoding("utf8");
    this.child.stderr.setEncoding("utf8");
    this.child.stdout.on("data", (chunk) => this.#consume(chunk));
    this.child.stderr.on("data", (chunk) => {
      this.stderr = `${this.stderr}${chunk}`.slice(-16 * 1024);
    });
    activeMcpProcesses.add(this);
    this.child.once("exit", () => activeMcpProcesses.delete(this));
  }

  #consume(chunk) {
    this.stdoutBuffer += chunk;
    assert.equal(Buffer.byteLength(this.stdoutBuffer), Math.min(Buffer.byteLength(this.stdoutBuffer), maxMcpFrameBytes * 2), "MCP stdout buffering is unbounded");
    while (true) {
      const newline = this.stdoutBuffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.stdoutBuffer.slice(0, newline).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      const message = JSON.parse(line);
      if (Object.hasOwn(message, "id")) {
        const responseKey = String(message.id);
        this.responseCounts.set(responseKey, (this.responseCounts.get(responseKey) || 0) + 1);
        const waiter = this.pending.get(responseKey);
        if (waiter) {
          this.pending.delete(responseKey);
          waiter.resolve(message);
        } else {
          this.notifications.push(message);
        }
      } else {
        this.notifications.push(message);
      }
    }
  }

  send(message) {
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(id, method, params = {}) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`MCP response timeout for ${method}`));
      }, 3_000);
      this.pending.set(String(id), {
        resolve: (message) => {
          clearTimeout(timer);
          resolve(message);
        },
      });
      this.send({ jsonrpc: "2.0", id, method, params });
    });
  }

  raw(line) {
    this.child.stdin.write(`${line}\n`);
  }

  async initialize(id = 1) {
    const response = await this.request(id, "initialize", {
      protocolVersion,
      capabilities: {},
      clientInfo: { name: "frozen-acceptance", version: "1.0.0" },
    });
    assert.deepEqual(response, {
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "lico-arc-orchestration", version: "0.1.0" },
      },
    });
    this.send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
  }

  async close() {
    if (this.child.exitCode !== null) return;
    this.child.stdin.end();
    await Promise.race([
      new Promise((resolve) => this.child.once("exit", resolve)),
      new Promise((_, reject) => setTimeout(() => reject(new Error("MCP server did not exit after EOF")), 1_000)),
    ]);
    assert.equal(this.child.exitCode, 0, `MCP server EOF exit failed: ${this.stderr}`);
  }

  async forceClose() {
    if (this.child.exitCode !== null) return;
    this.child.stdin.end();
    try {
      await Promise.race([
        new Promise((resolve) => this.child.once("exit", resolve)),
        new Promise((_, reject) => setTimeout(() => reject(new Error("force close timeout")), 250)),
      ]);
    } catch {
      this.child.kill();
      await new Promise((resolve) => this.child.once("exit", resolve));
    }
  }
}

async function stagePackagedFixture(packageRoot, platform, mode) {
  const { stageSelectedModuleArtifacts } = await import(
    path.join(repoRoot, "apps/desktop/scripts/package-client/resource-assembly.mjs")
  );
  assert.equal(typeof stageSelectedModuleArtifacts, "function", "canonical package staging API is missing");
  const packaging = readJson(packagingPath);
  const selected = ["codex-orchestration-mcp", "codex-orchestration-plugin"].map((id) => ({
    id,
    ...packaging.modules[id],
  }));
  const bundle = {
    executableDir: path.join(packageRoot, platform, mode, "executables"),
    moduleResourceDir: path.join(packageRoot, platform, mode, "modules"),
  };
  mkdirSync(bundle.executableDir, { recursive: true });
  mkdirSync(bundle.moduleResourceDir, { recursive: true });
  const copied = stageSelectedModuleArtifacts(selected, bundle, { platform, mode });
  const suffix = platform === "windows" ? ".exe" : "";
  const executable = path.join(bundle.executableDir, `lico-codex-mcp${suffix}`);
  const moduleDirectory = path.join(
    bundle.moduleResourceDir,
    "codex-orchestration-plugin/lico-arc-codex",
  );
  assert.equal(copied.includes(executable), true, `${platform} package omitted MCP binary`);
  assert.equal(copied.includes(moduleDirectory), true, `${platform} package omitted plugin module`);
  assert.equal(existsSync(executable), true);
  assert.equal(existsSync(path.join(moduleDirectory, ".codex-plugin/plugin.json")), true);
  assert.equal(existsSync(path.join(moduleDirectory, "mcp/server.json")), true);
  assert.equal(existsSync(path.join(moduleDirectory, "skills/lico-arc-orchestration/SKILL.md")), true);
  return { executable, moduleDirectory, copied };
}

function encodeFrame(value) {
  const payload = Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value), "utf8");
  const frame = Buffer.allocUnsafe(payload.length + 4);
  frame.writeUInt32BE(payload.length, 0);
  payload.copy(frame, 4);
  return frame;
}

class FrameReader {
  constructor(socket, onFrame) {
    this.buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      while (this.buffer.length >= 4) {
        const length = this.buffer.readUInt32BE(0);
        if (this.buffer.length < length + 4) return;
        const payload = this.buffer.subarray(4, length + 4);
        this.buffer = this.buffer.subarray(length + 4);
        onFrame(payload);
      }
    });
  }
}

class FakePrivateBackend {
  constructor(root) {
    this.root = root;
    this.workflowCapability = "f".repeat(64);
    this.statusCapability = "e".repeat(64);
    this.lifecycleCapability = "d".repeat(64);
    this.workflows = new Map();
    this.requests = [];
    this.handshakes = [];
    this.inFlight = 0;
    this.maxInFlight = 0;
    this.inFlightSockets = new Set();
    this.submitCount = 0;
    this.activeSockets = new Set();
    this.pendingSockets = new Map();
    this.abortedWorkflowIds = new Set();
    this.abortedWorkflowCounts = new Map();
    this.lateReceiptAttempts = 0;
    this.server = null;
  }

  async start() {
    mkdirSync(this.root, { recursive: true, mode: 0o700 });
    chmodSync(this.root, 0o700);
    const generation = `${process.pid.toString(16).padStart(8, "0")}${Date.now().toString(16).padStart(16, "0")}`.slice(-32).padStart(32, "a");
    const runtimeBase = process.platform === "win32" ? os.tmpdir() : "/tmp";
    const runtimeRoot = path.join(runtimeBase, `licoarc-orchestrator-${process.getuid?.() ?? 0}`);
    mkdirSync(runtimeRoot, { recursive: true, mode: 0o700 });
    chmodSync(runtimeRoot, 0o700);
    this.socketPath = path.join(runtimeRoot, `o-${generation.slice(0, 12)}.sock`);
    rmSync(this.socketPath, { force: true });
    this.server = net.createServer((socket) => this.#accept(socket));
    await new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(this.socketPath, resolve);
    });
    chmodSync(this.socketPath, 0o600);
    assert.equal(statSync(this.socketPath).mode & 0o777, 0o600, "fake IPC endpoint must be owner-private");
    const discovery = {
      endpointGeneration: generation,
      serviceInstanceId: "b".repeat(32),
      endpointPath: this.socketPath,
      servicePid: process.pid,
      acceptanceMode: false,
    };
    writeFileSync(path.join(this.root, "orchestrator.discovery.json"), JSON.stringify(discovery), { mode: 0o600 });
    writeFileSync(path.join(this.root, "orchestrator.capability"), JSON.stringify({
      workflow: this.workflowCapability,
      statusOnly: this.statusCapability,
      lifecycle: this.lifecycleCapability,
    }), { mode: 0o600 });
  }

  #accept(socket) {
    this.activeSockets.add(socket);
    socket.once("close", () => {
      this.activeSockets.delete(socket);
      this.#releaseInFlight(socket);
      const workflowId = this.pendingSockets.get(socket);
      if (workflowId) {
        this.abortedWorkflowIds.add(workflowId);
        this.abortedWorkflowCounts.set(
          workflowId,
          (this.abortedWorkflowCounts.get(workflowId) || 0) + 1,
        );
        this.pendingSockets.delete(socket);
      }
    });
    const frames = [];
    new FrameReader(socket, (payload) => {
      frames.push(payload);
      if (frames.length !== 2) return;
      let handshake;
      let request;
      try {
        handshake = JSON.parse(frames[0].toString("utf8"));
        request = JSON.parse(frames[1].toString("utf8"));
      } catch {
        socket.end(encodeFrame({ broken: true }));
        return;
      }
      this.handshakes.push(handshake);
      this.requests.push(request);
      this.inFlightSockets.add(socket);
      this.inFlight = this.inFlightSockets.size;
      this.maxInFlight = Math.max(this.maxInFlight, this.inFlight);
      const finish = (receipt) => {
        this.#releaseInFlight(socket);
        this.pendingSockets.delete(socket);
        if (!socket.destroyed) {
          socket.end(encodeFrame(receipt));
        } else {
          this.lateReceiptAttempts += 1;
        }
      };
      const expectedCapability = request.method === "service.status"
        ? this.statusCapability
        : this.workflowCapability;
      if (handshake.protocolVersion !== ipcProtocolVersion || handshake.clientKind !== "codex-mcp") {
        finish(this.#error(request.requestId, "peer_rejected"));
        return;
      }
      if (handshake.capabilityHandle !== expectedCapability) {
        finish(this.#error(request.requestId, "capability_rejected"));
        return;
      }
      if (request.params?.workflowId === "workflow-timeout") {
        this.pendingSockets.set(socket, request.params.workflowId);
        setTimeout(() => finish(this.#success(request.requestId, { state: "running" })), 900);
        return;
      }
      if (request.params?.workflowId === "workflow-malformed") {
        this.#releaseInFlight(socket);
        socket.end(encodeFrame(Buffer.from("{not-json", "utf8")));
        return;
      }
      if (request.params?.workflowId === "workflow-oversized") {
        this.#releaseInFlight(socket);
        const header = Buffer.alloc(4);
        header.writeUInt32BE(maxMcpFrameBytes + 1, 0);
        socket.end(header);
        return;
      }
      if (request.params?.workflowId === "workflow-denied") {
        finish(this.#error(request.requestId, "operation_forbidden"));
        return;
      }
      setTimeout(() => finish(this.#handle(request)), request.params?.workflowId?.startsWith("workflow-concurrent-") ? 80 : 0);
    });
  }

  #success(requestId, result) {
    return { protocolVersion: ipcProtocolVersion, requestId, ok: true, result };
  }

  #releaseInFlight(socket) {
    if (this.inFlightSockets.delete(socket)) {
      this.inFlight = this.inFlightSockets.size;
    }
  }

  #error(requestId, code) {
    return { protocolVersion: ipcProtocolVersion, requestId, ok: false, error: { code } };
  }

  #handle(request) {
    const { method, params = {} } = request;
    if (method === "service.status") {
      return this.#success(request.requestId, {
        state: "running",
        admissionState: "accepting",
        capabilityRevisionId: "capability-revision-1",
        readyTargetCount: 2,
        ...sensitiveCanaries,
      });
    }
    if (method === "workflow.preview") {
      return this.#success(request.requestId, {
        state: "previewed",
        policyRevisionId: params.policyRevisionId,
        compiledRevisionId: "compiled-revision-1",
        stepCount: 3,
        ...sensitiveCanaries,
      });
    }
    if (method === "workflow.submit") {
      if (params.policyRevisionId === "policy-admission-closed") {
        return this.#error(request.requestId, "product_admission_closed");
      }
      this.submitCount += 1;
      const workflowId = `workflow-${this.submitCount}`;
      this.workflows.set(workflowId, {
        workflowId,
        state: "awaiting_approval",
        cursor: 1,
        receiptId: `receipt-${this.submitCount}`,
        approvalId: `approval-${this.submitCount}`,
        events: [{ cursor: 1, type: "workflow.submitted", state: "awaiting_approval" }],
      });
      const workflow = this.workflows.get(workflowId);
      return this.#success(request.requestId, { ...workflow, events: undefined, ...sensitiveCanaries });
    }
    if (method === "workflow.status") {
      const workflow = this.workflows.get(params.workflowId) || {
        workflowId: params.workflowId,
        state: "running",
        cursor: 4,
        receiptId: "receipt-status",
      };
      return this.#success(request.requestId, { ...workflow, events: undefined, ...sensitiveCanaries });
    }
    if (method === "workflow.events") {
      const workflow = this.workflows.get(params.workflowId);
      const events = (workflow?.events || [
        { cursor: 2, type: "step.started", state: "running" },
        { cursor: 3, type: "step.completed", state: "running" },
        { cursor: 4, type: "workflow.completed", state: "completed" },
      ]).filter((event) => event.cursor > params.afterCursor).slice(0, params.limit);
      return this.#success(request.requestId, {
        events: events.map((event) => ({ ...event, ...sensitiveCanaries })),
        nextCursor: events.at(-1)?.cursor ?? params.afterCursor,
        hasMore: false,
      });
    }
    if (method === "workflow.wait") {
      return this.#success(request.requestId, {
        workflowId: params.workflowId,
        events: [{
          cursor: 2,
          type: "child.output.progress",
          state: "running",
          stepId: "implement",
          agentId: "codex",
          outputBytes: 4096,
          ...sensitiveCanaries,
        }],
        nextCursor: 2,
        hasMore: false,
        cursorExpired: false,
        timedOut: false,
        active: true,
        terminal: false,
      });
    }
    if (method === "workflow.message") {
      return this.#success(request.requestId, {
        workflowId: params.workflowId,
        messageId: "message-1",
        state: "queued",
        deliveryMode: "bridge_follow_up",
        ...sensitiveCanaries,
      });
    }
    if (method === "workflow.approve") {
      const workflow = this.workflows.get(params.workflowId);
      if (workflow) {
        workflow.state = params.decision === "approved" ? "running" : "rejected";
        workflow.cursor += 1;
        workflow.events.push({ cursor: workflow.cursor, type: `approval.${params.decision}`, state: workflow.state });
      }
      return this.#success(request.requestId, {
        workflowId: params.workflowId,
        state: workflow?.state || "running",
        cursor: workflow?.cursor || 2,
        receiptId: "receipt-approval",
        approvalId: params.approvalId,
        ...sensitiveCanaries,
      });
    }
    if (method === "workflow.cancel") {
      const workflow = this.workflows.get(params.workflowId);
      if (workflow) {
        workflow.state = "cancelled";
        workflow.cursor += 1;
        workflow.events.push({ cursor: workflow.cursor, type: "workflow.cancelled", state: "cancelled" });
      }
      return this.#success(request.requestId, {
        workflowId: params.workflowId,
        state: "cancelled",
        cursor: workflow?.cursor || 2,
        receiptId: "receipt-cancel",
        ...sensitiveCanaries,
      });
    }
    return this.#error(request.requestId, "unknown_method");
  }

  async close() {
    if (this.server) {
      const server = this.server;
      this.server = null;
      await new Promise((resolve) => server.close(resolve));
    }
    if (this.socketPath) rmSync(this.socketPath, { force: true });
  }
}

function toolCall(name, arguments_) {
  return { name, arguments: arguments_ };
}

async function waitFor(predicate, label, timeoutMs = 1_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(label);
}

function structured(response) {
  assert.equal(response.error, undefined, `unexpected MCP error: ${JSON.stringify(response.error)}`);
  assert.equal(response.result.isError, false);
  assert.deepEqual(response.result.content, [{ type: "text", text: JSON.stringify(response.result.structuredContent) }]);
  const serialized = JSON.stringify(response.result);
  for (const canary of Object.values(sensitiveCanaries)) {
    assert.equal(serialized.includes(canary), false, "MCP projected sensitive backend data");
  }
  return response.result.structuredContent;
}

function assertRedactedError(response, expectedReasonCode, retryable = false) {
  assert.equal(response.error, undefined);
  assert.equal(response.result.isError, true);
  assert.deepEqual(response.result.structuredContent, {
    schemaVersion: "lico.arc.mcp.error.v1",
    reasonCode: expectedReasonCode,
    retryable,
  });
  assert.deepEqual(response.result.content, [{ type: "text", text: JSON.stringify(response.result.structuredContent) }]);
  assert.equal(JSON.stringify(response).length < 2048, true, "error projection must remain bounded");
}

function invalidArgumentMatrix(tool, valid) {
  const schema = tool.inputSchema;
  const cases = [
    ["root-null", null],
    ["root-array", []],
    ["root-string", "invalid"],
    ["root-number", 7],
    ["extra-property", { ...valid, unexpected: true }],
  ];
  for (const required of schema.required || []) {
    const candidate = structuredClone(valid);
    delete candidate[required];
    cases.push([`missing-${required}`, candidate]);
  }
  for (const [name, property] of Object.entries(schema.properties || {})) {
    const replace = (value, suffix) => {
      const candidate = structuredClone(valid);
      candidate[name] = value;
      cases.push([`${name}-${suffix}`, candidate]);
    };
    replace(null, "null");
    if (property.type === "string") {
      replace(1, "wrong-type");
      replace("", "empty");
      if (Number.isSafeInteger(property.maxLength)) replace("x".repeat(property.maxLength + 1), "overlength");
      if (Array.isArray(property.enum)) replace("not-an-enum-value", "bad-enum");
      if (property.pattern) replace("not-a-valid-digest", "bad-pattern");
    } else if (property.type === "integer") {
      replace("1", "wrong-type");
      replace(1.5, "fractional");
      if (Number.isFinite(property.minimum)) replace(property.minimum - 1, "below-minimum");
      if (Number.isFinite(property.maximum)) replace(property.maximum + 1, "above-maximum");
    } else if (property.type === "object") {
      replace("object", "wrong-type");
      replace({ ...valid[name], unexpected: true }, "nested-extra");
      for (const nestedRequired of property.required || []) {
        const nested = structuredClone(valid[name]);
        delete nested[nestedRequired];
        replace(nested, `nested-missing-${nestedRequired}`);
      }
      for (const [nestedName, nestedProperty] of Object.entries(property.properties || {})) {
        const nestedWrongType = structuredClone(valid[name]);
        nestedWrongType[nestedName] = 1;
        replace(nestedWrongType, `nested-${nestedName}-wrong-type`);
        if (nestedProperty.type === "string") {
          const nestedEmpty = structuredClone(valid[name]);
          nestedEmpty[nestedName] = "";
          replace(nestedEmpty, `nested-${nestedName}-empty`);
          if (Number.isSafeInteger(nestedProperty.maxLength)) {
            const nestedLong = structuredClone(valid[name]);
            nestedLong[nestedName] = "x".repeat(nestedProperty.maxLength + 1);
            replace(nestedLong, `nested-${nestedName}-overlength`);
          }
          if (nestedProperty.pattern) {
            const nestedPattern = structuredClone(valid[name]);
            nestedPattern[nestedName] = "bad-digest";
            replace(nestedPattern, `nested-${nestedName}-bad-pattern`);
          }
        }
      }
    }
  }
  return cases;
}

test("plugin manifest, MCP declaration, skill, Cargo target, and package lifecycle are valid", () => {
  canonicalPluginValidator();
  const manifest = readJson(manifestPath);
  const serverConfig = readJson(serverConfigPath);
  assert.deepEqual(Object.keys(manifest).sort(), [
    "author", "description", "interface", "license", "mcpServers", "name", "skills", "version",
  ]);
  assert.equal(manifest.name, "lico-arc-codex");
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/u);
  assert.equal(manifest.author.name, "LicoMesh");
  assert.equal(manifest.license, "GPL-3.0-or-later");
  assert.equal(manifest.skills, "./skills/");
  assert.equal(typeof manifest.mcpServers, "object");
  assert.equal(Array.isArray(manifest.mcpServers), false);
  assert.deepEqual(manifest.mcpServers, serverConfig.mcpServers);
  assert.equal(path.resolve(pluginRoot, manifest.skills), path.join(pluginRoot, "skills"));
  assert.deepEqual(
    [skillPath].filter((candidate) => existsSync(candidate)),
    [skillPath],
    "authoritative plugin skill discovery failed",
  );
  assert.deepEqual(manifest.interface, {
    displayName: "Lico Arc Orchestration",
    shortDescription: "Submit and observe Lico Arc governed workflows.",
    longDescription: "A local, privacy-minimal Codex control plane for backend-owned Lico Arc workflows.",
    developerName: "LicoMesh",
    category: "Productivity",
    capabilities: ["Read", "Write"],
    defaultPrompt: [
      "Preview my active Lico Arc workflow policy.",
      "Submit this plan to Lico Arc and track its receipt.",
    ],
  });

  assert.deepEqual(serverConfig, {
    mcpServers: {
      "lico-arc-orchestration": {
        type: "stdio",
        command: "lico-codex-mcp",
        args: [],
      },
    },
  });
  const skill = readFileSync(skillPath, "utf8");
  assert.match(skill, /^---\nname: lico-arc-orchestration\ndescription: [^\n]+\n---\n/u);
  for (const tool of expectedTools) assert.match(skill, new RegExp(`\\b${tool}\\b`, "u"));
  assert.match(skill, /Lico Arc remains the workflow and dispatch authority/u);
  assert.doesNotMatch(skill, /(?:Kimi|Claude|DeepSeek|GPT-?5|provider-specific)/iu);

  const cargo = readFileSync(cargoPath, "utf8");
  assert.match(cargo, /\[\[bin\]\]\s+name\s*=\s*"lico-codex-mcp"\s+path\s*=\s*"src\/bin\/lico-codex-mcp\.rs"/u);
  const packaging = readJson(packagingPath);
  assert.deepEqual(packaging.modules["codex-orchestration-mcp"], {
    label: "Lico Arc local Codex MCP control plane",
    category: "agents",
    enabled: true,
    required: true,
    platforms: ["macos", "linux"],
    packaging: "sidecar-binary",
    cargoBin: "lico-codex-mcp",
    requires: ["native-sidecar"],
  });
  assert.deepEqual(packaging.modules["codex-orchestration-plugin"], {
    label: "Lico Arc Codex plugin bundle",
    category: "agents",
    enabled: true,
    required: true,
    platforms: ["macos", "linux"],
    packaging: "module-resources",
    includePaths: ["plugins/lico-arc-codex"],
    requires: ["codex-orchestration-mcp"],
  });
});

test("plugin and MCP implementation stay a thin privacy-minimal private-IPC client", () => {
  const rust = readFileSync(rustPath, "utf8");
  const pluginFiles = [manifestPath, serverConfigPath, skillPath].map((entry) => readFileSync(entry, "utf8"));
  const source = [rust, ...pluginFiles].join("\n");
  for (const token of [
    "mcp_adapter", "mcp_streamable_http", "collaboration_plugin", "collaboration_bridge",
    "conversation_lane", "agent_conversation", "rusqlite", "sqlite", "Command::new",
    "std::process::Command", "tokio::process", "workflow_store", "policy_evaluator",
  ]) {
    assert.equal(source.toLowerCase().includes(token.toLowerCase()), false, `thin MCP boundary contains forbidden ${token}`);
  }
  assert.doesNotMatch(rust, /(?:Kimi|Claude|DeepSeek|GPT-?5|frontend\s*=>|backend\s*=>)/iu);
  assert.doesNotMatch(rust, /(?:TcpListener|TcpStream|reqwest|ureq|https?:\/\/)/u);
  assert.match(rust, /OrchestratorIpcClient/u);
  assert.match(rust, /client_kind|clientKind/u);
  assert.match(rust, /codex-mcp/u);
  assert.match(rust, /cfg!\(debug_assertions\)|cfg\(debug_assertions\)/u);
  assert.match(rust, /LICO_CODEX_MCP_ACCEPTANCE_STATE_ROOT/u);
  assert.match(rust, /with_client_kind\(\s*"codex-mcp"\s*\)/u);
  assert.match(rust, /with_auto_start\(\s*false\s*\)/u);
  assert.doesNotMatch(rust, /discover_or_start/u);
  assert.match(rust, /const\s+MAX_IPC_CONCURRENCY\s*:\s*usize\s*=\s*8\s*;/u);
  assert.match(rust, /const\s+MAX_PENDING_TOOL_CALLS\s*:\s*usize\s*=\s*32\s*;/u);
  assert.match(rust, /mpsc::sync_channel::<ToolJob>\(MAX_PENDING_TOOL_CALLS\)/u);
  assert.match(rust, /jobs\s*:\s*Mutex\s*<\s*Option\s*<\s*SyncSender\s*<\s*ToolJob\s*>\s*>\s*>/u);
  assert.doesNotMatch(rust, /jobs\s*:\s*[^\n]*Vec\s*</u);
  assert.match(rust, /Vec::with_capacity\(MAX_IPC_CONCURRENCY\)/u);
  assert.match(rust, /for\s+_\s+in\s+0\.\.MAX_IPC_CONCURRENCY/u);
  assert.equal([...rust.matchAll(/\bthread::spawn\s*\(/gu)].length, 1, "MCP must create only its fixed worker pool");
  assert.equal([...rust.matchAll(/\bworkers\.push\s*\(/gu)].length, 1, "worker handles may grow only during fixed-pool construction");
  const callDispatcher = rust.slice(rust.indexOf("fn start_tool_call"), rust.indexOf("fn execute_tool"));
  assert.doesNotMatch(callDispatcher, /(?:thread::spawn|JoinHandle|Vec\s*<|Vec::new|\.push\s*\()/u);
  assert.match(callDispatcher, /TrySendError::Full/u);
  assert.match(callDispatcher, /tool_error_with_retryability\(\s*"server_busy"\s*,\s*true\s*\)/u);
  for (const canary of Object.values(sensitiveCanaries)) assert.equal(source.includes(canary), false);
  assert.equal(source.includes(repoRoot), false, "plugin persisted a private workspace path");
  for (const forbiddenField of ["prompt", "reasoning", "rawOutput", "nativeSessionId", "privatePath", "filename", "accountId", "credential"] ) {
    assert.doesNotMatch(rust, new RegExp(`\\b${forbiddenField}\\b`, "u"));
  }
});

test("STDIO MCP is strict, closed, restart-safe, bounded, cancellable, and fail-closed", async (t) => {
  buildMcpBinary("debug");
  buildMcpBinary("release");
  const fixtureRoot = mkdtempSync(path.join(os.tmpdir(), "lico-codex-mcp-acceptance-"));
  const packageRoot = mkdtempSync(path.join(os.tmpdir(), "lico-codex-mcp-package-"));
  const packagedDebug = await stagePackagedFixture(packageRoot, "macos", "debug");
  const packagedMacosRelease = await stagePackagedFixture(packageRoot, "macos", "release");
  const packagedLinuxRelease = await stagePackagedFixture(packageRoot, "linux", "release");
  assert.notEqual(packagedDebug.executable, packagedMacosRelease.executable);
  assert.notEqual(packagedDebug.moduleDirectory, packagedMacosRelease.moduleDirectory);
  assert.notEqual(packagedMacosRelease.executable, packagedLinuxRelease.executable);
  assert.notEqual(packagedMacosRelease.moduleDirectory, packagedLinuxRelease.moduleDirectory);
  assert.notEqual(
    fileDigest(packagedDebug.executable),
    fileDigest(packagedMacosRelease.executable),
    "macOS debug and release package stages must contain distinct build artifacts",
  );
  const packagedBinary = packagedDebug.executable;
  const backend = new FakePrivateBackend(fixtureRoot);
  await backend.start();
  t.after(async () => {
    await Promise.all([...activeMcpProcesses].map((client) => client.forceClose()));
    await backend.close();
    rmSync(fixtureRoot, { recursive: true, force: true });
    rmSync(packageRoot, { recursive: true, force: true });
  });
  const acceptanceEnvironment = {
    LICO_CODEX_MCP_ACCEPTANCE_STATE_ROOT: fixtureRoot,
  };

  const inactiveRoot = path.join(fixtureRoot, "release-inactive");
  mkdirSync(inactiveRoot, { recursive: true, mode: 0o700 });
  chmodSync(inactiveRoot, 0o700);
  const inactive = new McpProcess({
    LICO_ARC_STATE_ROOT: inactiveRoot,
  }, packagedMacosRelease.executable);
  await inactive.initialize(1);
  const releaseClosedCalls = [
    ["lico_agent_capabilities", {}],
    ["lico_strategy_preview", {
      policyRevisionId: "policy-revision-closed",
      inputDigest: "a".repeat(64),
    }],
    ["lico_workflow_approve", {
      workflowId: "workflow-closed",
      approvalId: "approval-closed",
      decision: "approved",
      idempotencyKey: "approve-closed-1",
    }],
    ["lico_workflow_cancel", {
      workflowId: "workflow-closed",
      idempotencyKey: "cancel-closed-1",
    }],
    ["lico_workflow_status", {
      workflowId: "workflow-closed",
      afterCursor: 0,
      limit: 16,
    }],
    ["lico_workflow_wait", {
      workflowId: "workflow-closed",
      afterCursor: 0,
      limit: 16,
      timeoutMs: 100,
    }],
    ["lico_workflow_message", {
      workflowId: "workflow-closed",
      messageArtifact: { handle: "message-closed", digest: "a".repeat(64) },
      idempotencyKey: "message-closed-1",
    }],
    ["lico_workflow_submit", {
      policyRevisionId: "policy-revision-closed",
      inputArtifact: { handle: "artifact-input-closed", digest: "a".repeat(64) },
      idempotencyKey: "submit-closed-1",
    }],
  ];
  let releaseRequestId = 2;
  for (const [name, arguments_] of releaseClosedCalls) {
    const closed = await inactive.request(
      releaseRequestId,
      "tools/call",
      toolCall(name, arguments_),
    );
    releaseRequestId += 1;
    assertRedactedError(closed, "service_unavailable");
  }
  assert.equal(backend.handshakes.length, 0, "release MCP reached an IPC handshake");
  assert.equal(backend.requests.length, 0, "inactive product MCP reached orchestration IPC");
  await inactive.close();

  if (process.platform !== "win32") {
    const assertUnsafePermissionsRejected = async (target, unsafeMode, safeMode, label, id) => {
      chmodSync(target, unsafeMode);
      const beforeHandshakes = backend.handshakes.length;
      const beforeRequests = backend.requests.length;
      const client = new McpProcess(acceptanceEnvironment, packagedBinary);
      await client.initialize(id);
      const response = await client.request(id + 1, "tools/call", toolCall("lico_agent_capabilities", {}));
      assertRedactedError(response, "unsafe_local_state");
      await client.close();
      assert.equal(backend.handshakes.length, beforeHandshakes, `${label} reached IPC handshake`);
      assert.equal(backend.requests.length, beforeRequests, `${label} reached IPC request`);
      chmodSync(target, safeMode);
    };
    await assertUnsafePermissionsRejected(fixtureRoot, 0o755, 0o700, "unsafe state root", 400);
    await assertUnsafePermissionsRejected(
      path.join(fixtureRoot, "orchestrator.discovery.json"), 0o644, 0o600, "unsafe discovery", 410,
    );
    await assertUnsafePermissionsRejected(
      path.join(fixtureRoot, "orchestrator.capability"), 0o644, 0o600, "unsafe capability", 420,
    );
    await assertUnsafePermissionsRejected(backend.socketPath, 0o666, 0o600, "unsafe endpoint", 430);
  }

  const first = new McpProcess(acceptanceEnvironment, packagedBinary);
  const beforeInitialize = await first.request(8, "tools/list", {});
  assert.equal(beforeInitialize.error.code, -32002, "tools must be unavailable before initialize");
  const wrongVersion = await first.request(9, "initialize", {
    protocolVersion: "2099-01-01",
    capabilities: {},
    clientInfo: { name: "frozen-acceptance", version: "1.0.0" },
  });
  assert.equal(wrongVersion.error.code, -32602, "unsupported MCP versions must fail closed");
  await first.initialize(10);
  const list = await first.request(11, "tools/list", {});
  assert.equal(list.jsonrpc, "2.0");
  const tools = list.result.tools;
  assert.deepEqual(tools.map((entry) => entry.name).sort(), expectedTools);
  for (const tool of tools) {
    assert.deepEqual(Object.keys(tool).sort(), ["description", "inputSchema", "name", "outputSchema"]);
    assert.equal(tool.description.length > 0 && tool.description.length <= 256, true);
    assertClosedBoundedSchema(tool.inputSchema, `${tool.name}.inputSchema`);
    assertClosedBoundedSchema(tool.outputSchema, `${tool.name}.outputSchema`);
    const outputFields = collectPropertyNames(tool.outputSchema);
    for (const forbidden of ["prompt", "reasoning", "rawOutput", "nativeSessionId", "privatePath", "filename", "accountId", "credential"]) {
      assert.equal(outputFields.has(forbidden), false, `${tool.name} output exposes ${forbidden}`);
    }
  }
  const statusSchema = tools.find((entry) => entry.name === "lico_workflow_status").inputSchema;
  assert.deepEqual(statusSchema.required, ["workflowId", "afterCursor", "limit"]);
  assert.equal(statusSchema.properties.afterCursor.minimum, 0);
  assert.equal(statusSchema.properties.afterCursor.maximum, Number.MAX_SAFE_INTEGER);
  assert.equal(statusSchema.properties.limit.maximum, 128);
  const requiredInputs = new Map([
    ["lico_agent_capabilities", []],
    ["lico_strategy_preview", ["policyRevisionId", "inputDigest"]],
    ["lico_workflow_approve", ["workflowId", "approvalId", "decision", "idempotencyKey"]],
    ["lico_workflow_cancel", ["workflowId", "idempotencyKey"]],
    ["lico_workflow_status", ["workflowId", "afterCursor", "limit"]],
    ["lico_workflow_wait", ["workflowId", "afterCursor", "limit", "timeoutMs"]],
    ["lico_workflow_message", ["workflowId", "messageArtifact", "idempotencyKey"]],
    ["lico_workflow_submit", ["policyRevisionId", "inputArtifact", "idempotencyKey"]],
  ]);
  for (const tool of tools) {
    assert.deepEqual(tool.inputSchema.required || [], requiredInputs.get(tool.name));
  }
  const submitSchema = tools.find((entry) => entry.name === "lico_workflow_submit").inputSchema;
  assert.deepEqual(submitSchema.properties.inputArtifact.required, ["handle", "digest"]);
  assert.equal(submitSchema.properties.inputArtifact.properties.digest.pattern, "^[0-9a-f]{64}$");
  const previewSchema = tools.find((entry) => entry.name === "lico_strategy_preview").inputSchema;
  assert.equal(previewSchema.properties.inputDigest.pattern, "^[0-9a-f]{64}$");

  const validArguments = new Map([
    ["lico_agent_capabilities", {}],
    ["lico_strategy_preview", { policyRevisionId: "policy-revision-1", inputDigest: "a".repeat(64) }],
    ["lico_workflow_approve", {
      workflowId: "workflow-validation",
      approvalId: "approval-validation",
      decision: "approved",
      idempotencyKey: "approve-validation",
    }],
    ["lico_workflow_cancel", { workflowId: "workflow-validation", idempotencyKey: "cancel-validation" }],
    ["lico_workflow_status", { workflowId: "workflow-validation", afterCursor: 0, limit: 16 }],
    ["lico_workflow_wait", {
      workflowId: "workflow-validation",
      afterCursor: 0,
      limit: 16,
      timeoutMs: 100,
    }],
    ["lico_workflow_message", {
      workflowId: "workflow-validation",
      messageArtifact: { handle: "message-validation", digest: "a".repeat(64) },
      idempotencyKey: "message-validation",
    }],
    ["lico_workflow_submit", {
      policyRevisionId: "policy-revision-1",
      inputArtifact: { handle: "artifact-validation", digest: "a".repeat(64) },
      idempotencyKey: "submit-validation",
    }],
  ]);
  let invalidRequestId = 1_000;
  for (const tool of tools) {
    for (const [label, arguments_] of invalidArgumentMatrix(tool, validArguments.get(tool.name))) {
      const before = backend.requests.length;
      const rejected = await first.request(
        invalidRequestId,
        "tools/call",
        toolCall(tool.name, arguments_),
      );
      invalidRequestId += 1;
      assert.equal(rejected.error?.code, -32602, `${tool.name}/${label} was not rejected`);
      assert.equal(backend.requests.length, before, `${tool.name}/${label} reached IPC`);
    }
  }

  first.raw("{malformed-json");
  await new Promise((resolve) => setTimeout(resolve, 25));
  assert.equal(first.notifications.some((entry) => entry.error?.code === -32700), true, "malformed JSON lacks parse error");
  const stillAlive = await first.request(12, "ping", {});
  assert.deepEqual(stillAlive, { jsonrpc: "2.0", id: 12, result: {} });
  first.raw(JSON.stringify({ jsonrpc: "2.0", id: 13, method: "ping", params: { padding: "x".repeat(maxMcpFrameBytes) } }));
  await new Promise((resolve) => setTimeout(resolve, 25));
  assert.equal(
    first.notifications.some((entry) => entry.id === 13 && entry.error?.code === -32600),
    true,
    "oversized MCP frame lacks a bounded invalid-request receipt",
  );
  const afterOversize = await first.request(14, "ping", {});
  assert.deepEqual(afterOversize, { jsonrpc: "2.0", id: 14, result: {} });

  const beforeInvalid = backend.requests.length;
  const invalid = await first.request(15, "tools/call", toolCall("lico_workflow_submit", {
    policyRevisionId: "policy-revision-1",
    inputArtifact: { handle: "artifact-1", digest: "a".repeat(64) },
    idempotencyKey: "submit-1",
    unexpected: true,
  }));
  assert.equal(invalid.error.code, -32602);
  assert.equal(backend.requests.length, beforeInvalid, "invalid tool input reached IPC");
  const unknown = await first.request(16, "tools/call", toolCall("unlisted_tool", {}));
  assert.equal(unknown.error.code, -32601);

  const preview = structured(await first.request(17, "tools/call", toolCall("lico_strategy_preview", {
    policyRevisionId: "policy-revision-1",
    inputDigest: "b".repeat(64),
  })));
  assert.deepEqual(preview, {
    schemaVersion: "lico.arc.mcp.receipt.v1",
    operation: "strategy.preview",
    state: "previewed",
    policyRevisionId: "policy-revision-1",
    compiledRevisionId: "compiled-revision-1",
    stepCount: 3,
  });
  const capabilities = structured(await first.request(18, "tools/call", toolCall("lico_agent_capabilities", {})));
  assert.deepEqual(capabilities, {
    schemaVersion: "lico.arc.mcp.receipt.v1",
    operation: "agent.capabilities",
    state: "running",
    admissionState: "accepting",
    capabilityRevisionId: "capability-revision-1",
    readyTargetCount: 2,
  });

  const submitStarted = Date.now();
  const submitted = structured(await first.request(19, "tools/call", toolCall("lico_workflow_submit", {
    policyRevisionId: "policy-revision-1",
    inputArtifact: { handle: "artifact-input-1", digest: "c".repeat(64) },
    idempotencyKey: "submit-workflow-1",
  })));
  assert.equal(Date.now() - submitStarted < 500, true, "submit waited for workflow execution");
  assert.deepEqual(submitted, {
    schemaVersion: "lico.arc.mcp.receipt.v1",
    operation: "workflow.submit",
    workflowId: "workflow-1",
    state: "awaiting_approval",
    cursor: 1,
    receiptId: "receipt-1",
    approvalId: "approval-1",
  });
  assert.equal(backend.submitCount, 1);
  const submitIpc = backend.requests.find((entry) => entry.method === "workflow.submit");
  assert.deepEqual(submitIpc.params, {
    policyRevisionId: "policy-revision-1",
    inputArtifactHandle: "artifact-input-1",
    inputDigest: "c".repeat(64),
  });
  assert.equal(submitIpc.idempotencyKey, "submit-workflow-1");
  assert.equal(submitIpc.clientKind, "codex-mcp");
  const waited = structured(await first.request(20, "tools/call", toolCall("lico_workflow_wait", {
    workflowId: "workflow-1",
    afterCursor: 1,
    limit: 16,
    timeoutMs: 100,
  })));
  assert.deepEqual(waited, {
    schemaVersion: "lico.arc.mcp.receipt.v1",
    operation: "workflow.wait",
    workflowId: "workflow-1",
    events: [{
      cursor: 2,
      outputBytes: 4096,
      type: "child.output.progress",
      state: "running",
      stepId: "implement",
      agentId: "codex",
    }],
    nextCursor: 2,
    hasMore: false,
    active: true,
    terminal: false,
    timedOut: false,
    cursorExpired: false,
  });
  const messaged = structured(await first.request(21, "tools/call", toolCall("lico_workflow_message", {
    workflowId: "workflow-1",
    messageArtifact: { handle: "message-input-1", digest: "d".repeat(64) },
    idempotencyKey: "message-workflow-1",
  })));
  assert.deepEqual(messaged, {
    schemaVersion: "lico.arc.mcp.receipt.v1",
    operation: "workflow.message",
    workflowId: "workflow-1",
    state: "queued",
    messageId: "message-1",
    deliveryMode: "bridge_follow_up",
  });
  const messageIpc = backend.requests.find((entry) => entry.method === "workflow.message");
  assert.deepEqual(messageIpc.params, {
    workflowId: "workflow-1",
    messageArtifactHandle: "message-input-1",
    messageDigest: "d".repeat(64),
  });
  assert.equal(messageIpc.idempotencyKey, "message-workflow-1");
  await first.close();

  const second = new McpProcess(acceptanceEnvironment, packagedBinary);
  await second.initialize(30);
  const observed = structured(await second.request(31, "tools/call", toolCall("lico_workflow_status", {
    workflowId: "workflow-1",
    afterCursor: 0,
    limit: 16,
  })));
  assert.deepEqual(observed, {
    schemaVersion: "lico.arc.mcp.receipt.v1",
    operation: "workflow.status",
    workflowId: "workflow-1",
    state: "awaiting_approval",
    cursor: 1,
    receiptId: "receipt-1",
    approvalId: "approval-1",
    events: [{ cursor: 1, type: "workflow.submitted", state: "awaiting_approval" }],
    nextCursor: 1,
    hasMore: false,
  });
  assert.deepEqual(
    backend.requests.slice(-2).map((entry) => entry.method),
    ["workflow.status", "workflow.events"],
    "status must page backend-owned events by cursor",
  );
  const approved = structured(await second.request(32, "tools/call", toolCall("lico_workflow_approve", {
    workflowId: "workflow-1",
    approvalId: "approval-1",
    decision: "approved",
    idempotencyKey: "approve-workflow-1",
  })));
  assert.equal(approved.state, "running");
  assert.equal(approved.workflowId, "workflow-1");
  const cancelled = structured(await second.request(33, "tools/call", toolCall("lico_workflow_cancel", {
    workflowId: "workflow-1",
    idempotencyKey: "cancel-workflow-1",
  })));
  assert.deepEqual(cancelled, {
    schemaVersion: "lico.arc.mcp.receipt.v1",
    operation: "workflow.cancel",
    workflowId: "workflow-1",
    state: "cancelled",
    cursor: 3,
    receiptId: "receipt-cancel",
  });

  const concurrent = await Promise.all(Array.from({ length: 20 }, (_, index) => second.request(
    100 + index,
    "tools/call",
    toolCall("lico_workflow_status", {
      workflowId: `workflow-concurrent-${index}`,
      afterCursor: 0,
      limit: 4,
    }),
  )));
  assert.equal(concurrent.every((response) => response.result || response.error), true);
  assert.equal(backend.maxInFlight <= 8, true, `MCP exceeded bounded IPC concurrency: ${backend.maxInFlight}`);

  const saturated = await Promise.all(Array.from({ length: 48 }, (_, index) => second.request(
    5_000 + index,
    "tools/call",
    toolCall("lico_workflow_status", {
      workflowId: "workflow-timeout",
      afterCursor: 0,
      limit: 4,
    }),
  )));
  const busyResponses = saturated.filter(
    (response) => response.result?.structuredContent?.reasonCode === "server_busy",
  );
  assert.equal(busyResponses.length > 0, true, "bounded MCP queue never reported saturation");
  for (const response of busyResponses) assertRedactedError(response, "server_busy", true);
  for (const response of saturated.filter((entry) => !busyResponses.includes(entry))) {
    assertRedactedError(response, "backend_timeout");
  }
  assert.equal(backend.maxInFlight <= 8, true, `saturation exceeded fixed worker count: ${backend.maxInFlight}`);
  await waitFor(
    () => backend.activeSockets.size === 0,
    "saturated MCP backlog did not release IPC resources",
    2_500,
  );
  const recovered = structured(await second.request(5_100, "tools/call", toolCall("lico_workflow_status", {
    workflowId: "workflow-recovery",
    afterCursor: 0,
    limit: 4,
  })));
  assert.equal(recovered.operation, "workflow.status");
  assert.equal(recovered.workflowId, "workflow-recovery");
  assert.equal(recovered.state, "running");
  assert.equal(backend.maxInFlight <= 8, true, "post-saturation recovery exceeded fixed worker count");

  const timeout = await second.request(200, "tools/call", toolCall("lico_workflow_status", {
    workflowId: "workflow-timeout",
    afterCursor: 0,
    limit: 4,
  }));
  assertRedactedError(timeout, "backend_timeout");

  const timeoutRequestsBeforeCancel = backend.requests.filter(
    (entry) => entry.params?.workflowId === "workflow-timeout",
  ).length;
  const abortsBeforeCancel = backend.abortedWorkflowCounts.get("workflow-timeout") || 0;
  const cancelledCall = second.request(201, "tools/call", toolCall("lico_workflow_status", {
    workflowId: "workflow-timeout",
    afterCursor: 0,
    limit: 4,
  }));
  await waitFor(
    () => backend.requests.filter((entry) => entry.params?.workflowId === "workflow-timeout").length > timeoutRequestsBeforeCancel,
    "cancelled request never reached the fake backend",
  );
  second.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 201, reason: "acceptance" } });
  const cancelledResponse = await cancelledCall;
  assert.equal(cancelledResponse.error.code, -32800);
  assert.equal(JSON.stringify(cancelledResponse).includes("acceptance"), false, "cancellation reason leaked");
  await waitFor(
    () => (backend.abortedWorkflowCounts.get("workflow-timeout") || 0) > abortsBeforeCancel,
    "MCP cancellation did not abort the in-flight IPC socket",
    500,
  );
  await new Promise((resolve) => setTimeout(resolve, 950));
  assert.equal(backend.lateReceiptAttempts >= 1, true, "late backend receipt path was not exercised");
  assert.equal(second.responseCounts.get("201"), 1, "late IPC receipt produced a second MCP response");
  assert.equal(second.notifications.some((entry) => entry.id === 201), false, "late IPC receipt escaped suppression");
  assert.equal(backend.activeSockets.size, 0, "cancelled IPC connection was not cleaned up");

  for (const [id, workflowId] of [[210, "workflow-malformed"], [211, "workflow-oversized"]]) {
    const broken = await second.request(id, "tools/call", toolCall("lico_workflow_status", {
      workflowId,
      afterCursor: 0,
      limit: 4,
    }));
    assertRedactedError(broken, "backend_transport_error");
  }
  const denied = await second.request(212, "tools/call", toolCall("lico_workflow_status", {
    workflowId: "workflow-denied",
    afterCursor: 0,
    limit: 4,
  }));
  assertRedactedError(denied, "operation_forbidden");
  await second.close();

  const capabilityPath = path.join(fixtureRoot, "orchestrator.capability");
  writeFileSync(capabilityPath, JSON.stringify({ workflow: "0".repeat(64), statusOnly: "0".repeat(64), lifecycle: "0".repeat(64) }), { mode: 0o600 });
  const unauthorized = new McpProcess(acceptanceEnvironment, packagedBinary);
  await unauthorized.initialize(300);
  const rejected = await unauthorized.request(301, "tools/call", toolCall("lico_agent_capabilities", {}));
  assertRedactedError(rejected, "capability_rejected");
  await unauthorized.close();

  await backend.close();
  const unavailable = new McpProcess(acceptanceEnvironment, packagedBinary);
  await unavailable.initialize(310);
  const missing = await unavailable.request(311, "tools/call", toolCall("lico_agent_capabilities", {}));
  assertRedactedError(missing, "service_unavailable");
  await unavailable.close();

  for (const handshake of backend.handshakes) {
    assert.equal(handshake.clientKind, "codex-mcp");
    assert.equal(handshake.protocolVersion, ipcProtocolVersion);
    assert.equal(typeof handshake.connectionNonce, "string");
    assert.equal(handshake.connectionNonce.length, 32);
  }
  for (const request of backend.requests) {
    assert.equal(request.protocolVersion, ipcProtocolVersion);
    assert.equal(request.clientKind, "codex-mcp");
    assert.equal(request.requestId.length <= 128, true);
    const mapped = [...expectedMethodByTool.values()].includes(request.method)
      || request.method === "workflow.status"
      || request.method === "workflow.events"
      || request.method === "workflow.wait";
    assert.equal(mapped, true, `unexpected IPC method ${request.method}`);
  }
});
