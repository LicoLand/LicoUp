import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";

export const fakeRuntimeSource = String.raw`#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { createInterface } from "node:readline";

const statePath = process.env.LICO_FAKE_ACP_STATE;
const load = () => existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : { counter: 0, sessions: {} };
const save = (state) => writeFileSync(statePath, JSON.stringify(state));
const options = [
  { id: "model", type: "select", currentValue: "fake-model", options: [{ value: "fake-model" }] },
  { id: "variant", type: "select", currentValue: "fake-effort", options: [{ value: "fake-effort" }] },
  { id: "mode", type: "select", currentValue: "fake-mode", options: [{ value: "fake-mode" }] },
  { id: "agent", type: "select", currentValue: "fake-agent", options: [{ value: "fake-agent" }] },
  { id: "allow_all", type: "boolean", currentValue: false },
];
const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");

async function acp() {
  const lines = createInterface({ input: process.stdin });
  let active = "";
  for await (const line of lines) {
    const message = JSON.parse(line);
    if (message.method === "initialize") {
      send({ jsonrpc: "2.0", id: message.id, result: { protocolVersion: 1, agentCapabilities: { loadSession: true, sessionCapabilities: { delete: {}, list: {}, resume: {}, close: {} } } } });
    } else if (message.method === "session/new") {
      const state = load();
      active = "fake-session-" + (++state.counter);
      state.sessions[active] = { cwd: message.params.cwd, messages: [] };
      save(state);
      send({ jsonrpc: "2.0", id: message.id, result: { sessionId: active, configOptions: options, modes: { currentModeId: "fake-mode" } } });
    } else if (message.method === "session/load") {
      const state = load();
      active = message.params.sessionId;
      const session = state.sessions[active];
      if (!session) {
        send({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "missing" } });
        continue;
      }
      for (const entry of session.messages.filter((item) => item.role === "assistant")) {
        send({ jsonrpc: "2.0", method: "session/update", params: { sessionId: active, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: entry.text } } } });
      }
      send({ jsonrpc: "2.0", id: message.id, result: { sessionId: active, configOptions: options, modes: { currentModeId: "fake-mode" } } });
    } else if (message.method === "session/list") {
      const state = load();
      send({ jsonrpc: "2.0", id: message.id, result: { sessions: Object.entries(state.sessions).map(([sessionId, value]) => ({ sessionId, cwd: value.cwd })) } });
    } else if (message.method === "session/close") {
      const state = load();
      delete state.sessions[message.params.sessionId];
      save(state);
      send({ jsonrpc: "2.0", id: message.id, result: {} });
    } else if (message.method === "session/set_config_option") {
      const state = load();
      const session = state.sessions[message.params.sessionId];
      if (!session) {
        send({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "missing" } });
        continue;
      }
      session.config ||= {};
      session.config[message.params.configId] = message.params.value;
      save(state);
      send({ jsonrpc: "2.0", id: message.id, result: { configOptions: options.map((option) => option.id === message.params.configId ? { ...option, currentValue: message.params.value } : option) } });
    } else if (message.method === "session/prompt") {
      const prompt = message.params.prompt[0].text;
      if (prompt.includes("SELFTEST_PERMISSION")) {
        const state = load();
        state.sessions[active].messages.push({ role: "user", text: prompt });
        save(state);
        send({ jsonrpc: "2.0", id: 991, method: "session/request_permission", params: { sessionId: active, options: [] } });
        continue;
      }
      if (prompt.includes("SELFTEST_OVERFLOW")) {
        const state = load();
        state.sessions[active].messages.push({ role: "user", text: prompt });
        save(state);
        send({ jsonrpc: "2.0", method: "session/update", params: { sessionId: active, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "x".repeat(65536) } } } });
        continue;
      }
      const reply = prompt.match(/Reply with exactly ([0-9]+)/u)?.[1] || "0";
      const state = load();
      state.sessions[active].messages.push({ role: "user", text: prompt }, { role: "assistant", text: reply });
      save(state);
      send({ jsonrpc: "2.0", method: "session/update", params: { sessionId: active, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: reply } } } });
      send({ jsonrpc: "2.0", id: message.id, result: { stopReason: "end_turn" } });
    } else if (message.method === "session/cancel" || (message.id === 991 && message.result?.outcome?.outcome === "cancelled")) {
      process.exit(0);
    }
  }
}

async function piRpc() {
  const root = process.env.PI_CODING_AGENT_SESSION_DIR;
  mkdirSync(root, { recursive: true });
  const state = load();
  let active = "fake-pi-" + (++state.counter);
  state.sessions[active] = { cwd: process.cwd(), messages: [] };
  save(state);
  const sessionPath = (id) => root + "/" + id + ".jsonl";
  const persist = () => {
    const current = load().sessions[active];
    const rows = [
      { type: "session", version: 3, id: active, cwd: current.cwd },
      ...current.messages.map((message, index) => ({ type: "message", id: active + "-" + index, message })),
    ];
    writeFileSync(sessionPath(active), rows.map((row) => JSON.stringify(row)).join("\n") + "\n");
  };
  persist();
  const lines = createInterface({ input: process.stdin });
  for await (const line of lines) {
    const command = JSON.parse(line);
    const respond = (success, data = {}) => send({ id: command.id, type: "response", command: command.type, success, data });
    if (command.type === "switch_session") {
      const header = JSON.parse(readFileSync(command.sessionPath, "utf8").split(/\r?\n/u)[0]);
      active = header.id;
      respond(true, { cancelled: false });
    } else if (command.type === "get_state") {
      respond(true, { sessionId: active, model: null, thinkingLevel: "off", isStreaming: false });
    } else if (command.type === "prompt") {
      const reply = command.message.match(/Reply with exactly ([0-9]+)/u)?.[1] || "0";
      const current = load();
      current.sessions[active].messages.push(
        { role: "user", content: [{ type: "text", text: command.message }] },
        { role: "assistant", content: [{ type: "text", text: reply }] },
      );
      save(current);
      persist();
      respond(true);
      send({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: reply } });
      send({ type: "agent_settled" });
    } else if (command.type === "get_last_assistant_text") {
      const messages = load().sessions[active].messages;
      const text = messages.filter((message) => message.role === "assistant").at(-1)?.content?.[0]?.text || null;
      respond(true, { text });
    } else if (command.type === "get_messages") {
      respond(true, { messages: load().sessions[active].messages });
    } else if (command.type === "abort") {
      respond(true);
    } else {
      respond(false);
    }
  }
}

async function sidecar() {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  const request = JSON.parse(input);
  const operation = process.argv.slice(2)[2] || "send";
  const laneFamilies = {
    openclaw: "acp", "claude-code": "stream-json", codex: "app-server",
    antigravity: "unavailable", opencode: "serve-http", copilot: "acp",
    "kilo-code": "serve-http", cursor: "acp", hermes: "acp",
    "kimi-code": "acp", pi: "rpc",
  };
  const exactResume = !["antigravity", "hermes"].includes(request.agent);
  const laneFamily = laneFamilies[request.agent] || "unavailable";
  if (operation === "capabilities") {
    process.stdout.write(JSON.stringify({
      ok: true,
      agentId: request.agent,
      laneFamily,
      runtimeProtocol: "fixture-protocol",
      capabilities: { officialLane: laneFamily !== "unavailable", exactResume },
    }));
    return;
  }
  if (operation === "open") {
    if (laneFamily === "unavailable" || (request.sessionId && !exactResume)) {
      process.stdout.write(JSON.stringify({ ok: false, error: { code: "fixture_open_blocked" } }));
    } else {
      process.stdout.write(JSON.stringify({ ok: true, sessionId: request.sessionId || "" }));
    }
    return;
  }
  if (operation === "stream") {
    process.stdout.write(JSON.stringify({ ok: true, status: "bound_on_send" }));
    return;
  }
  if (operation === "cancel") {
    process.stdout.write(JSON.stringify({ ok: false, error: { code: "dispatch_cancel_unsupported" } }));
    return;
  }
  const emitStream = request.streamEvents === true;
  const writeFinal = (payload) => {
    if (emitStream) {
      process.stdout.write(JSON.stringify({ event: "dispatch.turn.started", sessionId: payload.sessionId || "", turnId: "fake-turn", payload: {} }) + "\n");
      process.stdout.write(JSON.stringify({ event: "agent.message.chunk", sessionId: payload.sessionId || "", turnId: "fake-turn", payload: { text: payload.output || "" } }) + "\n");
      process.stdout.write(JSON.stringify({ event: "agent.message.completed", sessionId: payload.sessionId || "", turnId: "fake-turn", payload: { text: payload.output || "" } }) + "\n");
      process.stdout.write(JSON.stringify({ ...payload, event: "done" }) + "\n");
      return;
    }
    process.stdout.write(JSON.stringify(payload));
  };
  const child = spawn(request.binaryPath, request.agent === "codex" ? ["app-server", "--stdio"] : ["acp"], { cwd: request.workingDirectory, env: process.env, stdio: ["pipe", "pipe", "ignore"] });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map();
  let nextId = 1;
  let output = "";
  let sessionId = request.sessionId || "";
  if (request.agent === "codex") {
    const call = (method, params) => new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(String(id), { resolve, reject });
      child.stdin.write(JSON.stringify({ id, method, params }) + "\n");
    });
    lines.on("line", (line) => {
      const message = JSON.parse(line);
      if (message.method === "item/completed" && message.params?.item?.type === "agentMessage") {
        output += message.params.item.text || "";
      }
      if (Object.hasOwn(message, "id") && !message.method) {
        const waiter = pending.get(String(message.id));
        if (waiter) { pending.delete(String(message.id)); message.error ? waiter.reject(new Error("rejected")) : waiter.resolve(message.result); }
      }
    });
    await call("initialize", { clientInfo: { name: "fake" }, capabilities: { experimentalApi: true } });
    child.stdin.write(JSON.stringify({ method: "initialized" }) + "\n");
    if (sessionId) {
      await call("thread/resume", { threadId: sessionId });
    } else {
      const started = await call("thread/start", { cwd: request.workingDirectory });
      sessionId = started.thread.id;
    }
    output = "";
    const turn = await call("turn/start", { threadId: sessionId, input: [{ type: "text", text: request.text }] });
    await new Promise((resolve) => {
      const timer = setInterval(() => {
        if (output.length > 0) { clearInterval(timer); resolve(); }
      }, 5);
      setTimeout(() => { clearInterval(timer); resolve(); }, 200);
    });
    child.kill();
    writeFinal({
      ok: true,
      schemaVersion: 3,
      adapterId: "codex",
      driverId: "codex-app-server",
      runtimeProtocol: "codex-app-server-stdio-jsonrpc",
      sessionId,
      threadId: sessionId,
      nativeSessionId: sessionId,
      turnStatus: "end_turn",
      output: output || String(turn?.turn?.items?.find((item) => item.type === "agentMessage")?.text || ""),
      effective: { cwd: request.workingDirectory, model: request.model || null, reasoningEffort: request.reasoningEffort || null, mode: null, runtimeAgent: null, allowAll: null },
    });
    return;
  }
  lines.on("line", (line) => {
    const message = JSON.parse(line);
    if (message.method === "session/update") output += message.params?.update?.content?.text || "";
    if (Object.hasOwn(message, "id") && !message.method) {
      const waiter = pending.get(String(message.id));
      if (waiter) { pending.delete(String(message.id)); message.error ? waiter.reject(new Error("rejected")) : waiter.resolve(message.result); }
    }
  });
  const call = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(String(id), { resolve, reject });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  await call("initialize", { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false } });
  const session = await call(request.sessionId ? "session/load" : "session/new", { cwd: request.workingDirectory, mcpServers: [], ...(request.sessionId ? { sessionId: request.sessionId } : {}) });
  sessionId = request.sessionId || session.sessionId;
  output = "";
  const turn = await call("session/prompt", { sessionId, prompt: [{ type: "text", text: request.text }] });
  child.kill();
  const identity = {
    openclaw: ["openclaw-acp", "openclaw-acp-stdio-jsonrpc"],
    hermes: ["hermes-acp", "hermes-acp-stdio-jsonrpc"],
    "kilo-code": ["kilo-code-serve", "kilo-code-serve-http-v1"],
    cursor: ["cursor-acp", "cursor-acp-v1-stdio-jsonrpc"],
    copilot: ["copilot-acp", "copilot-acp-v1-stdio-ndjson"],
    "kimi-code": ["kimi-code-acp", "kimi-code-acp-v1-stdio-ndjson"],
    opencode: ["opencode-serve", "opencode-serve-http-v1"],
  }[request.agent] || ["opencode-serve", "opencode-serve-http-v1"];
  writeFinal({
    ok: true,
    schemaVersion: 3,
    adapterId: request.agent,
    driverId: identity[0],
    runtimeProtocol: identity[1],
    sessionId,
    threadId: sessionId,
    nativeSessionId: sessionId,
    turnStatus: turn.stopReason,
    output,
    effective: { cwd: request.workingDirectory, model: "fake-model", reasoningEffort: "fake-effort", mode: "fake-mode", runtimeAgent: "fake-agent", allowAll: false },
  });
}

async function appServer() {
  const lines = createInterface({ input: process.stdin });
  let nextTurn = 1;
  for await (const line of lines) {
    const message = JSON.parse(line);
    if (message.method === "initialize") {
      process.stdout.write(JSON.stringify({ id: message.id, result: { protocolVersion: 1 } }) + "\n");
    } else if (message.method === "initialized") {
      continue;
    } else if (message.method === "thread/start") {
      const state = load();
      const threadId = "fake-thread-" + (++state.counter);
      state.sessions[threadId] = { cwd: message.params?.cwd || "", model: message.params?.model || null, messages: [], turns: [] };
      save(state);
      process.stdout.write(JSON.stringify({ id: message.id, result: { thread: { id: threadId }, model: state.sessions[threadId].model } }) + "\n");
    } else if (message.method === "thread/resume") {
      const state = load();
      const threadId = message.params.threadId;
      if (!state.sessions[threadId]) {
        process.stdout.write(JSON.stringify({ id: message.id, error: { code: -32000, message: "missing" } }) + "\n");
        continue;
      }
      process.stdout.write(JSON.stringify({ id: message.id, result: { thread: { id: threadId }, model: state.sessions[threadId].model } }) + "\n");
    } else if (message.method === "thread/read") {
      const state = load();
      const thread = state.sessions[message.params.threadId];
      if (!thread) {
        process.stdout.write(JSON.stringify({ id: message.id, error: { code: -32000, message: "missing" } }) + "\n");
        continue;
      }
      process.stdout.write(JSON.stringify({ id: message.id, result: { thread: { id: message.params.threadId, turns: thread.turns }, model: thread.model } }) + "\n");
    } else if (message.method === "thread/list") {
      const state = load();
      process.stdout.write(JSON.stringify({ id: message.id, result: { threads: Object.keys(state.sessions).map((id) => ({ id })) } }) + "\n");
    } else if (message.method === "thread/delete") {
      const state = load();
      delete state.sessions[message.params.threadId];
      save(state);
      process.stdout.write(JSON.stringify({ id: message.id, result: {} }) + "\n");
    } else if (message.method === "turn/start") {
      const prompt = message.params.input[0].text;
      const reply = prompt.match(/Reply with exactly ([0-9]+)/u)?.[1] || "0";
      const turnId = "fake-turn-" + (nextTurn++);
      const state = load();
      const thread = state.sessions[message.params.threadId];
      thread.messages.push({ role: "user", text: prompt }, { role: "assistant", text: reply });
      const turn = { id: turnId, status: "completed", items: [{ type: "agentMessage", text: reply }] };
      thread.turns.push(turn);
      save(state);
      process.stdout.write(JSON.stringify({ id: message.id, result: { turn: { id: turnId } } }) + "\n");
      process.stdout.write(JSON.stringify({ method: "item/completed", params: { threadId: message.params.threadId, turnId, item: { type: "agentMessage", text: reply } } }) + "\n");
      process.stdout.write(JSON.stringify({ method: "turn/completed", params: { threadId: message.params.threadId, turn } }) + "\n");
    }
  }
}

async function sdk() {
  let buffer = Buffer.alloc(0);
  const reply = (id, result) => {
    const body = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id, result }));
    process.stdout.write(Buffer.concat([Buffer.from("Content-Length: " + body.length + "\r\n\r\n"), body]));
  };
  for await (const chunk of process.stdin) {
    buffer = Buffer.concat([buffer, chunk]);
    while (true) {
      const headerEnd = buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) break;
      const match = buffer.subarray(0, headerEnd).toString("ascii").match(/Content-Length:\s*(\d+)/i);
      if (!match) process.exit(3);
      const length = Number(match[1]);
      const bodyStart = headerEnd + 4;
      if (buffer.length < bodyStart + length) break;
      const message = JSON.parse(buffer.subarray(bodyStart, bodyStart + length).toString("utf8"));
      buffer = buffer.subarray(bodyStart + length);
      if (message.method === "connect" || message.method === "ping") {
        reply(message.id, { protocolVersion: 1 });
      } else if (message.method === "session.list") {
        const state = load();
        reply(message.id, { sessions: Object.keys(state.sessions).map((sessionId) => ({ sessionId })) });
      } else if (message.method === "session.delete") {
        const state = load();
        delete state.sessions[message.params.sessionId];
        save(state);
        reply(message.id, { success: true });
      } else {
        process.exit(4);
      }
    }
  }
}

const args = process.argv.slice(2);
if (args[0] === "agent") {
  await sidecar();
} else if (args[0] === "app-server") {
  await appServer();
} else if (args[0] === "--mode" && args[1] === "rpc") {
  await piRpc();
} else if (args.includes("--server") || args.includes("--headless")) {
  await sdk();
} else if (args[0] === "acp" || args[0] === "serve") {
  // Fixture-only: serve-http agents still exercise ACP JSON-RPC through the
  // fake binary. Live release-UI uses the real serve/HTTP attach path.
  await acp();
} else if (args[0] === "session" && args[1] === "list") {
  const state = load();
  process.stdout.write(JSON.stringify(Object.entries(state.sessions).map(([id, session]) => ({ id, title: session.messages[0]?.text || "" }))));
} else if (args[0] === "session" && args[1] === "delete") {
  if (args[2] === "--help") process.exit(0);
  const state = load();
  if (!state.sessions[args[2]]) process.exit(2);
  delete state.sessions[args[2]];
  save(state);
} else if (args[0] === "sessions" && args[1] === "list") {
  const state = load();
  for (const [id, session] of Object.entries(state.sessions)) {
    const stamp = id.startsWith("fake-session-")
      ? ("20260711_000000_" + id.replace(/[^a-f0-9]/gu, "").padEnd(6, "a").slice(0, 6))
      : id;
    process.stdout.write((session.messages[0]?.text || "session") + " " + stamp + "\n");
  }
} else if (args[0] === "sessions" && args[1] === "delete") {
  if (args.includes("--help")) process.exit(0);
  const state = load();
  const target = args[2];
  const match = Object.keys(state.sessions).find((id) => id === target || ("20260711_000000_" + id.replace(/[^a-f0-9]/gu, "").padEnd(6, "a").slice(0, 6)) === target);
  if (!match) process.exit(2);
  delete state.sessions[match];
  save(state);
} else if (args[0] === "sessions" && args[1] === "export") {
  const destination = args[2];
  const sessionId = args[args.indexOf("--session-id") + 1];
  const state = load();
  const match = Object.keys(state.sessions).find((id) => id === sessionId || ("20260711_000000_" + id.replace(/[^a-f0-9]/gu, "").padEnd(6, "a").slice(0, 6)) === sessionId);
  if (!match) process.exit(2);
  writeFileSync(destination, JSON.stringify(state.sessions[match]));
} else if (args[0] === "export") {
  const state = load();
  if (!state.sessions[args[1]]) process.exit(2);
  process.stdout.write(JSON.stringify(state.sessions[args[1]]));
} else {
  process.exit(2);
}
`;
