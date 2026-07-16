import { randomUUID } from "node:crypto";
import { parityModelForAgent } from "../agent-ids.mjs";
import { AcpClient } from "../clients/acp-client.mjs";
import { acceptanceMode, sidecarArgs } from "../constants.mjs";
import { AcceptanceError, requireFact, safeErrorCode } from "../errors.mjs";
import { nativeAppServerReadback, nativeAppServerTurn } from "./app-server.mjs";
import { nativePiReadback, nativePiTurn, notificationTexts, sessionSettings } from "./pi.mjs";
import { runBoundedProcess } from "../process.mjs";

export async function nativeTurn(context, requestedSessionId, prompt) {
  if (context.config.laneFamily === "app-server") {
    return nativeAppServerTurn(context, requestedSessionId, prompt);
  }
  if (context.config.laneFamily === "rpc") {
    return nativePiTurn(context, requestedSessionId, prompt);
  }
  const client = new AcpClient(
    context.wrapper.wrapperPath,
    context.config.acpArgs,
    { ...context, environment: context.wrapper.environment },
  );
  try {
    const initializeResult = await client.initialize();
    const historyStart = client.notifications.length;
    const method = requestedSessionId ? "session/load" : "session/new";
    const params = { cwd: context.cwd, mcpServers: [] };
    if (requestedSessionId) params.sessionId = requestedSessionId;
    const sessionResult = await client.request(method, params);
    const sessionId = requestedSessionId || sessionResult?.sessionId || "";
    requireFact(typeof sessionId === "string" && sessionId.length > 0, "native_session_id_missing");
    requireFact(
      !requestedSessionId || sessionResult?.sessionId === undefined || sessionResult.sessionId === requestedSessionId,
      "native_session_identity_mismatch",
    );
    context.observedSessions?.add(sessionId);
    const forcedModel = parityModelForAgent(context.config.id);
    if (forcedModel) {
      await client.request("session/set_config_option", {
        sessionId,
        configId: "model",
        value: forcedModel,
      });
    }
    const historyNotifications = client.notifications.slice(historyStart);
    const promptStart = client.notifications.length;
    const promptResult = await client.request("session/prompt", {
      sessionId,
      messageId: randomUUID(),
      prompt: [{ type: "text", text: prompt }],
    });
    requireFact(promptResult?.stopReason === "end_turn", "native_turn_not_completed");
    const turnNotifications = client.notifications.slice(promptStart);
    const final = notificationTexts(turnNotifications, sessionId);
    requireFact(!final.sessionMismatch, "native_event_session_mismatch");
    requireFact(final.text.length > 0, "native_final_message_missing");
    return {
      sessionId,
      output: final.text.trim(),
      historyNotifications,
      settings: sessionSettings(sessionResult, context.cwd),
      protocolVersion: initializeResult.protocolVersion,
      permissionRequests: client.permissionRequests,
      unsupportedRequests: client.unsupportedRequests,
      boundedOutput: client.outputBytes <= context.maxOutputBytes
        && client.stderrBytes <= context.maxOutputBytes,
    };
  } finally {
    await client.close();
  }
}

export async function nativeReadback(context, sessionId) {
  if (context.config.laneFamily === "app-server") {
    return nativeAppServerReadback(context, sessionId);
  }
  if (context.config.laneFamily === "rpc") {
    return nativePiReadback(context, sessionId);
  }
  const client = new AcpClient(
    context.wrapper.wrapperPath,
    context.config.acpArgs,
    { ...context, environment: context.wrapper.environment },
  );
  try {
    await client.initialize();
    const start = client.notifications.length;
    const result = await client.request("session/load", {
      sessionId,
      cwd: context.cwd,
      mcpServers: [],
    });
    requireFact(result?.sessionId === undefined || result.sessionId === sessionId, "readback_session_identity_mismatch");
    const notifications = client.notifications.slice(start);
    const text = notificationTexts(notifications, sessionId);
    requireFact(!text.sessionMismatch, "readback_event_session_mismatch");
    return {
      text: text.text,
      settings: sessionSettings(result, context.cwd),
      boundedOutput: client.outputBytes <= context.maxOutputBytes
        && client.stderrBytes <= context.maxOutputBytes,
    };
  } finally {
    await client.close();
  }
}

export function parseSidecarStreamStdout(stdout) {
  const events = [];
  let result = null;
  for (const line of String(stdout || "").split(/\r?\n/u)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let parsed;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      throw new AcceptanceError("sidecar_invalid_json");
    }
    const eventKind = typeof parsed?.event === "string" ? parsed.event : "";
    if (eventKind && eventKind !== "done") {
      events.push(eventKind);
    }
    if (parsed?.event === "done" || Object.hasOwn(parsed || {}, "ok")) {
      result = parsed;
    }
  }
  if (!result) {
    throw new AcceptanceError("sidecar_invalid_json");
  }
  const streamingSeen = events.includes("agent.message.chunk");
  const structuredSeen = events.includes("agent.message.completed")
    && (events.includes("dispatch.turn.started") || events.includes("agent.message.chunk"));
  return { result, events, streamingSeen, structuredSeen };
}

export async function runSidecar(context, request) {
  const streamEvents = request?.streamEvents === true;
  const args = streamEvents
    ? [...sidecarArgs, "--stream-events", "true"]
    : sidecarArgs;
  const run = await runBoundedProcess(
    context.sidecar,
    args,
    {
      cwd: context.cwd,
      environment: context.wrapper.environment,
      timeoutMs: context.timeoutMs,
      maxOutputBytes: context.maxOutputBytes,
      stdinText: JSON.stringify({ ...request, acceptanceMode }),
    },
  );
  let result;
  let streamingSeen = false;
  let structuredSeen = false;
  try {
    if (streamEvents) {
      const parsed = parseSidecarStreamStdout(run.stdout);
      result = parsed.result;
      streamingSeen = parsed.streamingSeen;
      structuredSeen = parsed.structuredSeen;
    } else {
      result = JSON.parse(run.stdout);
    }
  } catch {
    throw new AcceptanceError(
      run.statusCode === 0 ? "sidecar_invalid_json" : "sidecar_process_failed",
    );
  }
  if (result?.ok !== true) {
    const code = safeErrorCode(result?.error?.code || "sidecar_rejected");
    throw new AcceptanceError(code);
  }
  requireFact(run.statusCode === 0, "sidecar_process_failed");
  requireFact(result?.schemaVersion === 3, "sidecar_schema_mismatch");
  requireFact(result?.adapterId === context.config.id, "sidecar_adapter_mismatch");
  requireFact(result?.driverId === context.config.driverId, "sidecar_driver_mismatch");
  requireFact(result?.runtimeProtocol === context.config.runtimeProtocol, "sidecar_protocol_mismatch");
  requireFact(
    result?.turnStatus === "end_turn" || result?.turnStatus === "completed",
    "sidecar_turn_not_completed",
  );
  const nativeSessionId = result?.nativeSessionId || result?.sessionId || "";
  if (typeof nativeSessionId === "string" && nativeSessionId.length > 0) {
    context.observedSessions?.add(nativeSessionId);
  }
  return {
    result,
    streamingSeen,
    structuredSeen,
    boundedOutput: run.stdoutBytes <= context.maxOutputBytes
      && run.stderrBytes <= context.maxOutputBytes,
  };
}
