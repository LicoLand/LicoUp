import { existsSync, readFileSync } from "node:fs";
import { parityModelForAgent } from "./agent-ids.mjs";
import { sidecarArgs, verificationTurnCount } from "./constants.mjs";
import { AcceptanceError, digest, requireFact, stableJson } from "./errors.mjs";
import { nativeReadback, runSidecar } from "./native/acp-turn.mjs";
import { arcSettings } from "./native/pi.mjs";
import { cleanupSession } from "./session-cleanup.mjs";
import { listSessions, officialHistory } from "./session-query.mjs";
import {
  canaryPrompt,
  failedParityFactCode,
  makeCanary,
  normalizedMarker,
  outputCategoryCode,
  roundConversationFactsReady,
  roundFactsReady,
} from "./round-facts.mjs";

function sidecarBinaryPath(context) {
  return context.sidecarBinaryPath
    || (context.config.promptInArguments ? context.binary : context.wrapper.wrapperPath);
}

function sidecarSessionId(result) {
  return result?.nativeSessionId || result?.sessionId || result?.threadId || "";
}

function verificationRequest(context, text, sessionId, model, reasoningEffort) {
  return {
    agent: context.config.id,
    text,
    ...(sessionId ? { sessionId } : {}),
    workingDirectory: context.cwd,
    binaryPath: sidecarBinaryPath(context),
    timeoutMs: context.timeoutMs,
    maxStdoutBytes: context.maxOutputBytes,
    maxStderrBytes: context.maxOutputBytes,
    streamEvents: true,
    ...(model ? { model } : {}),
    ...(reasoningEffort ? { reasoningEffort } : {}),
  };
}

export async function runRound(context, roundIndex, selfTestEvidence) {
  const canaries = [makeCanary(), makeCanary()];
  const expectedReplies = [11, 13].map((value) => String(roundIndex * 1000 + value));
  const knownSessions = new Set();
  const before = await listSessions(context);
  const previousObservedSessions = context.observedSessions;
  context.observedSessions = knownSessions;
  let cleanupCount = 0;
  let cleanupVerified = false;
  let testedSessions = 0;
  let requestCount = 0;
  let successfulRequestCount = 0;
  let facts;
  let roundError = null;
  try {
    requireFact(verificationTurnCount === 2, "verification_turn_contract_invalid");
    const forcedModel = parityModelForAgent(context.config.id);
    const forcedCodexModel = context.config.id === "codex" ? forcedModel : "";
    const forcedCodexEffort = context.config.id === "codex"
      ? (process.env.LICO_CODEX_PARITY_REASONING_EFFORT
        || (forcedCodexModel.toLowerCase().includes("spark") ? "low" : ""))
      : "";

    requestCount += 1;
    const created = await runSidecar(context, verificationRequest(
      context,
      canaryPrompt(canaries[0], expectedReplies[0]),
      "",
      forcedModel,
      forcedCodexEffort,
    ));
    successfulRequestCount += 1;
    const sessionId = sidecarSessionId(created.result);
    requireFact(typeof sessionId === "string" && sessionId.length > 0, "arc_session_id_missing");
    knownSessions.add(sessionId);
    testedSessions = 1;

    requestCount += 1;
    const resumed = await runSidecar(context, verificationRequest(
      context,
      canaryPrompt(canaries[1], expectedReplies[1]),
      sessionId,
      forcedModel,
      forcedCodexEffort,
    ));
    successfulRequestCount += 1;
    requireFact(sidecarSessionId(resumed.result) === sessionId, "exact_resume_session_mismatch");

    const readback = await nativeReadback(context, sessionId);
    const official = await officialHistory(context, sessionId, context.temporaryDirectory);
    const history = `${readback.text}\n${official}`;
    const capture = existsSync(context.wrapper.capturePath)
      ? readFileSync(context.wrapper.capturePath, "utf8")
      : "";
    const argvCanariesAbsent = context.config.promptInArguments
      ? canaries.every((canary) => !sidecarArgs.some((argument) => argument.includes(canary)))
        && canaries.every((canary) => !context.config.acpArgs.some((argument) => argument.includes(canary)))
      : canaries.every((canary) => !capture.includes(canary))
        && canaries.every((canary) => !context.config.acpArgs.some((argument) => argument.includes(canary)))
        && canaries.every((canary) => !sidecarArgs.some((argument) => argument.includes(canary)));

    const createdSettings = arcSettings(created.result);
    const resumedSettings = arcSettings(resumed.result);
    const settingsKeys = ["cwd", "model", "reasoningEffort", "mode", "runtimeAgent", "allowAll"];
    const settingsParityMask = settingsKeys
      .map((key) => [createdSettings, resumedSettings]
        .every((entry) => stableJson(entry[key]) === stableJson(readback.settings[key])) ? "1" : "0")
      .join("");
    const settingsParity = settingsParityMask === "111111";
    const createdOutput = String(created.result.output || "").trim();
    const resumedOutput = String(resumed.result.output || "").trim();
    const createdFinalCanaryPresent = createdOutput.includes(expectedReplies[0]);
    const resumedFinalCanaryPresent = resumedOutput.includes(expectedReplies[1]);
    const createdFinalCanary = createdOutput === expectedReplies[0];
    const resumedFinalCanary = resumedOutput === expectedReplies[1];
    const createdFinalCanaryNormalized = normalizedMarker(createdOutput)
      === normalizedMarker(expectedReplies[0]);
    const resumedFinalCanaryNormalized = normalizedMarker(resumedOutput)
      === normalizedMarker(expectedReplies[1]);

    facts = {
      openNew: sessionId.length > 0,
      exactResume: sidecarSessionId(resumed.result) === sessionId,
      nativeToArc: created.result.sessionId === sessionId
        && created.result.threadId === sessionId,
      arcToNative: history.includes(expectedReplies[0]) && history.includes(expectedReplies[1]),
      realSessionIds: sessionId.length > 0,
      nativeFirstFinalCanaryPresent: createdFinalCanaryPresent,
      nativeFirstFinalCanaryNormalized: createdFinalCanaryNormalized,
      nativeFirstFinalCanary: createdFinalCanary,
      arcResumeFinalCanaryPresent: resumedFinalCanaryPresent,
      arcResumeFinalCanaryNormalized: resumedFinalCanaryNormalized,
      arcResumeFinalCanary: resumedFinalCanary,
      firstSessionOutputsEqual: createdOutput === resumedOutput,
      allOutputsEqual: createdOutput === resumedOutput,
      nativeFirstOutputCategory: outputCategoryCode(createdOutput),
      arcResumeOutputCategory: outputCategoryCode(resumedOutput),
      finalCanaries: createdFinalCanaryNormalized && resumedFinalCanaryNormalized,
      cwdParity: createdSettings.cwd === context.cwd
        && resumedSettings.cwd === context.cwd
        && readback.settings.cwd === context.cwd,
      settingsParity,
      settingsParityMask,
      argvCanariesAbsent,
      historyReadback: context.config.cleanupKind === "cursor-cli-chat-leaf"
        ? expectedReplies.every((reply) => `${createdOutput}\n${resumedOutput}`.includes(reply))
        : expectedReplies.every((reply) => history.includes(reply)),
      noPermissionRequests: true,
      noUnsupportedRequests: true,
      boundedOutput: created.boundedOutput && resumed.boundedOutput && readback.boundedOutput,
      streamingSeen: created.streamingSeen === true && resumed.streamingSeen === true,
      structuredSeen: created.structuredSeen === true && resumed.structuredSeen === true,
      cleanupVerified: false,
      permissionFailClosed: selfTestEvidence.permissionFailClosed,
      errorFailClosed: selfTestEvidence.errorFailClosed,
      settingsDigest: digest([createdSettings, resumedSettings, readback.settings]),
      turnOutputBytes: [
        Buffer.byteLength(createdOutput),
        Buffer.byteLength(resumedOutput),
      ],
    };
  } catch (error) {
    roundError = error instanceof AcceptanceError ? error : new AcceptanceError("unexpected_failure");
  } finally {
    let after = new Map();
    try {
      after = await listSessions(context);
    } catch {
      roundError ||= new AcceptanceError("session_list_after_failed");
    }
    for (const [sessionId, record] of after) {
      if (!before.has(sessionId) && canaries.some((canary) => record.includes(canary))) {
        knownSessions.add(sessionId);
      }
    }
    let allDeleted = true;
    for (const sessionId of knownSessions) {
      const deleted = await cleanupSession(context, sessionId, context.temporaryDirectory);
      if (deleted) cleanupCount += 1;
      else allDeleted = false;
    }
    try {
      const verified = await listSessions(context);
      cleanupVerified = allDeleted
        && [...knownSessions].every((sessionId) => !verified.has(sessionId));
    } catch {
      cleanupVerified = false;
    }
    context.observedSessions = previousObservedSessions;
  }
  if (!facts) {
    return {
      ready: false,
      roundIndex,
      cleanupCount,
      cleanupVerified,
      testedSessions,
      requestCount,
      successfulRequestCount,
      errorCode: roundError?.code || "round_failed",
      facts: null,
    };
  }
  facts.cleanupVerified = cleanupVerified;
  const ready = roundFactsReady(facts)
    && facts.permissionFailClosed
    && facts.errorFailClosed;
  const conversationReady = roundConversationFactsReady(facts)
    && facts.permissionFailClosed
    && facts.errorFailClosed;
  return {
    ready,
    conversationReady,
    roundIndex,
    cleanupCount,
    cleanupVerified,
    testedSessions,
    requestCount,
    successfulRequestCount,
    errorCode: ready ? null : (roundError?.code || failedParityFactCode(facts)),
    facts,
  };
}
