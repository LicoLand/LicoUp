import { spawn } from "node:child_process";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { AcceptanceError, requireFact, safeErrorCode } from "../errors.mjs";

export class AcpClient {
  constructor(executable, args, options) {
    this.timeoutMs = options.timeoutMs;
    this.maxOutputBytes = options.maxOutputBytes;
    this.outputBytes = 0;
    this.stderrBytes = 0;
    this.nextId = 1;
    this.pending = new Map();
    this.notifications = [];
    this.failure = null;
    this.closed = false;
    this.permissionRequests = 0;
    this.unsupportedRequests = 0;
    this.child = spawn(executable, args, {
      cwd: options.cwd,
      env: options.environment,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.once("error", () => this.abort("acp_start_failed"));
    this.child.once("close", () => {
      if (!this.closed && !this.failure) this.abort("acp_exited_early");
    });
    this.child.stderr.on("data", (chunk) => {
      this.stderrBytes += chunk.length;
      if (this.stderrBytes > this.maxOutputBytes) this.abort("acp_stderr_limit");
    });
    const lines = createInterface({ input: this.child.stdout });
    lines.on("line", (line) => {
      this.outputBytes += Buffer.byteLength(line) + 1;
      if (this.outputBytes > this.maxOutputBytes) {
        this.abort("acp_stdout_limit");
        return;
      }
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.abort("acp_invalid_json");
        return;
      }
      this.handleMessage(message);
    });
  }

  handleMessage(message) {
    if (message && Object.hasOwn(message, "id") && typeof message.method === "string") {
      this.handleServerRequest(message);
      return;
    }
    if (message && Object.hasOwn(message, "id")) {
      const pending = this.pending.get(String(message.id));
      if (!pending) return;
      this.pending.delete(String(message.id));
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(new AcceptanceError("acp_request_rejected"));
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (message && typeof message.method === "string") this.notifications.push(message);
  }

  handleServerRequest(message) {
    const method = message.method;
    const responseId = message.id;
    if (method === "session/request_permission") {
      this.permissionRequests += 1;
      this.write({
        jsonrpc: "2.0",
        id: responseId,
        result: { outcome: { outcome: "cancelled" } },
      });
      const sessionId = message?.params?.sessionId;
      if (typeof sessionId === "string" && sessionId.length > 0) {
        this.write({
          jsonrpc: "2.0",
          method: "session/cancel",
          params: { sessionId },
        });
      }
      this.abort("acp_permission_required");
      return;
    }
    this.unsupportedRequests += 1;
    this.write({
      jsonrpc: "2.0",
      id: responseId,
      error: { code: -32601, message: "Client capability is unavailable." },
    });
    this.abort("acp_client_request_unsupported");
  }

  write(message) {
    if (this.failure || !this.child.stdin.writable) {
      throw new AcceptanceError(this.failure || "acp_stdin_closed");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params) {
    const id = this.nextId++;
    return new Promise((resolveRequest, rejectRequest) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        rejectRequest(new AcceptanceError("acp_request_timeout"));
        this.abort("acp_request_timeout");
      }, this.timeoutMs);
      this.pending.set(String(id), { resolve: resolveRequest, reject: rejectRequest, timer });
      try {
        this.write({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(String(id));
        rejectRequest(error);
      }
    });
  }

  abort(code) {
    if (this.failure) return;
    this.failure = safeErrorCode(code);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new AcceptanceError(this.failure));
    }
    this.pending.clear();
    this.child.kill();
  }

  async initialize() {
    const result = await this.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {
        fs: { readTextFile: false, writeTextFile: false },
        terminal: false,
        auth: { terminal: false },
      },
      clientInfo: { name: "lico-arc-parity", title: "Lico Arc Parity", version: "1" },
    });
    requireFact(result?.protocolVersion === 1, "acp_protocol_version_mismatch");
    requireFact(result?.agentCapabilities?.loadSession === true, "acp_load_session_unavailable");
    return result;
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.child.stdin.end();
    if (this.child.exitCode === null) this.child.kill();
    await Promise.race([
      new Promise((resolveClose) => this.child.once("close", resolveClose)),
      new Promise((resolveClose) => setTimeout(resolveClose, 1_000)),
    ]);
  }
}
