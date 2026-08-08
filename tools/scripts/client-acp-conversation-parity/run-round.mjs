import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parityModelForAgent } from "./agent-ids.mjs";
import { sidecarArgs } from "./constants.mjs";
import { AcceptanceError, digest, requireFact, stableJson } from "./errors.mjs";
import { nativeReadback, nativeTurn, runSidecar } from "./native/acp-turn.mjs";
import { arcSettings } from "./native/pi.mjs";
import { cleanupSession } from "./session-cleanup.mjs";
import { listSessions, officialHistory } from "./session-query.mjs";
import { canaryPrompt, failedParityFactCode, makeCanary, normalizedMarker, outputCategoryCode, roundConversationFactsReady, roundFactsReady } from "./round-facts.mjs";

function sidecarBinaryPath(context) {
  return context.config.promptInArguments ? context.binary : context.wrapper.wrapperPath;
}

export async function runRound(context, roundIndex, selfTestEvidence) {
  const canaries = [makeCanary(), makeCanary(), makeCanary(), makeCanary()];
  const expectedReplies = [11, 13, 17, 19].map((value) => String(roundIndex * 1000 + value));
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
    const forcedModel = parityModelForAgent(context.config.id);
    const forcedCodexModel = context.config.id === "codex" ? forcedModel : "";
    const forcedCodexEffort = context.config.id === "codex"
      ? (process.env.LICO_CODEX_PARITY_REASONING_EFFORT || (forcedCodexModel.toLowerCase().includes("spark") ? "low" : ""))
      : "";
    requestCount += 1;
    const nativeFirst = await nativeTurn(
      context,
      "",
      canaryPrompt(canaries[0], expectedReplies[0]),
    );
    successfulRequestCount += 1;
    knownSessions.add(nativeFirst.sessionId);
    testedSessions += 1;
    requestCount += 1;
    const arcResume = await runSidecar(context, {
      agent: context.config.id,
      text: canaryPrompt(canaries[1], expectedReplies[1]),
      sessionId: nativeFirst.sessionId,
      workingDirectory: context.cwd,
      binaryPath: sidecarBinaryPath(context),
      timeoutMs: context.timeoutMs,
      maxStdoutBytes: context.maxOutputBytes,
      maxStderrBytes: context.maxOutputBytes,
      streamEvents: true,
      ...(forcedModel ? { model: forcedModel } : {}),
      ...(forcedCodexEffort ? { reasoningEffort: forcedCodexEffort } : {}),
    });
    successfulRequestCount += 1;
    const readFirst = await nativeReadback(context, nativeFirst.sessionId);
    const officialFirst = await officialHistory(context, nativeFirst.sessionId, context.temporaryDirectory);

    requestCount += 1;
    const arcFirst = await runSidecar(context, {
      agent: context.config.id,
      text: canaryPrompt(canaries[2], expectedReplies[2]),
      workingDirectory: context.cwd,
      binaryPath: sidecarBinaryPath(context),
      timeoutMs: context.timeoutMs,
      maxStdoutBytes: context.maxOutputBytes,
      maxStderrBytes: context.maxOutputBytes,
      streamEvents: true,
      ...(forcedModel ? { model: forcedModel } : {}),
      ...(forcedCodexEffort ? { reasoningEffort: forcedCodexEffort } : {}),
    });
    successfulRequestCount += 1;
    const arcSessionId = arcFirst.result?.sessionId || "";
    requireFact(typeof arcSessionId === "string" && arcSessionId.length > 0, "arc_session_id_missing");
    knownSessions.add(arcSessionId);
    testedSessions += 1;
    requestCount += 1;
    const nativeResume = await nativeTurn(
      context,
      arcSessionId,
      canaryPrompt(canaries[3], expectedReplies[3]),
    );
    successfulRequestCount += 1;
    const readSecond = await nativeReadback(context, arcSessionId);
    const officialSecond = await officialHistory(context, arcSessionId, context.temporaryDirectory);

    const capture = existsSync(context.wrapper.capturePath)
      ? readFileSync(context.wrapper.capturePath, "utf8")
      : "";
    const argvCanariesAbsent = context.config.promptInArguments
      ? canaries.every((canary) => !sidecarArgs.some((argument) => argument.includes(canary)))
        && canaries.every((canary) => !context.config.acpArgs.some((argument) => argument.includes(canary)))
      : canaries.every((canary) => !capture.includes(canary))
        && canaries.every((canary) => !context.config.acpArgs.some((argument) => argument.includes(canary)))
        && canaries.every((canary) => !sidecarArgs.some((argument) => argument.includes(canary)));
    const firstHistory = `${readFirst.text}\n${officialFirst}`;
    const secondHistory = `${readSecond.text}\n${officialSecond}`;
    const arcResumeSettings = arcSettings(arcResume.result);
    const arcFirstSettings = arcSettings(arcFirst.result);
    const settingsPairs = [
      [nativeFirst.settings, arcResumeSettings],
      [nativeResume.settings, arcFirstSettings],
      [readFirst.settings, nativeFirst.settings],
      [readSecond.settings, nativeResume.settings],
    ];
    const settingsKeys = ["cwd", "model", "reasoningEffort", "mode", "runtimeAgent", "allowAll"];
    const settingsParityMask = settingsKeys
      .map((key) => settingsPairs.every(([left, right]) => stableJson(left[key]) === stableJson(right[key])) ? "1" : "0")
      .join("");
    const settingsParity = settingsParityMask === "111111";
    const arcResumeOutput = String(arcResume.result.output || "").trim();
    const arcFirstOutput = String(arcFirst.result.output || "").trim();
    const nativeFirstFinalCanaryPresent = nativeFirst.output.includes(expectedReplies[0]);
    const nativeFirstFinalCanary = nativeFirst.output === expectedReplies[0];
    const arcResumeFinalCanaryPresent = arcResumeOutput.includes(expectedReplies[1]);
    const arcResumeFinalCanary = arcResumeOutput === expectedReplies[1];
    const arcFirstFinalCanaryPresent = arcFirstOutput.includes(expectedReplies[2]);
    const arcFirstFinalCanary = arcFirstOutput === expectedReplies[2];
    const nativeResumeFinalCanaryPresent = nativeResume.output.includes(expectedReplies[3]);
    const nativeResumeFinalCanary = nativeResume.output === expectedReplies[3];
    const nativeFirstFinalCanaryNormalized = normalizedMarker(nativeFirst.output)
      === normalizedMarker(expectedReplies[0]);
    const arcResumeFinalCanaryNormalized = normalizedMarker(arcResumeOutput)
      === normalizedMarker(expectedReplies[1]);
    const arcFirstFinalCanaryNormalized = normalizedMarker(arcFirstOutput)
      === normalizedMarker(expectedReplies[2]);
    const nativeResumeFinalCanaryNormalized = normalizedMarker(nativeResume.output)
      === normalizedMarker(expectedReplies[3]);
    const firstSessionOutputsEqual = nativeFirst.output === arcResumeOutput;
    const secondSessionOutputsEqual = arcFirstOutput === nativeResume.output;
    const allOutputsEqual = firstSessionOutputsEqual
      && secondSessionOutputsEqual
      && nativeFirst.output === arcFirstOutput;
    const nativeFirstOutputCategory = outputCategoryCode(nativeFirst.output);
    const arcResumeOutputCategory = outputCategoryCode(arcResumeOutput);
    const arcFirstOutputCategory = outputCategoryCode(arcFirstOutput);
    const nativeResumeOutputCategory = outputCategoryCode(nativeResume.output);
    const publicStreamingSeen = [arcResume, arcFirst]
      .every((turn) => turn.streamingSeen === true);
    facts = {
      nativeToArc: arcResume.result.sessionId === nativeFirst.sessionId
        && arcResume.result.threadId === nativeFirst.sessionId,
      arcToNative: nativeResume.sessionId === arcSessionId,
      realSessionIds: nativeFirst.sessionId.length > 0
        && arcSessionId.length > 0
        && nativeFirst.sessionId !== arcSessionId,
      nativeFirstFinalCanaryPresent,
      nativeFirstFinalCanaryNormalized,
      nativeFirstFinalCanary,
      arcResumeFinalCanaryPresent,
      arcResumeFinalCanaryNormalized,
      arcResumeFinalCanary,
      arcFirstFinalCanaryPresent,
      arcFirstFinalCanaryNormalized,
      arcFirstFinalCanary,
      nativeResumeFinalCanaryPresent,
      nativeResumeFinalCanaryNormalized,
      nativeResumeFinalCanary,
      firstSessionOutputsEqual,
      secondSessionOutputsEqual,
      allOutputsEqual,
      nativeFirstOutputCategory,
      arcResumeOutputCategory,
      arcFirstOutputCategory,
      nativeResumeOutputCategory,
      finalCanaries: nativeFirstFinalCanaryNormalized
        && arcResumeFinalCanaryNormalized
        && arcFirstFinalCanaryNormalized
        && nativeResumeFinalCanaryNormalized,
      cwdParity: arcSettings(arcResume.result).cwd === context.cwd
        && arcSettings(arcFirst.result).cwd === context.cwd
        && nativeFirst.settings.cwd === context.cwd
        && nativeResume.settings.cwd === context.cwd,
      settingsParity,
      settingsParityMask,
      argvCanariesAbsent,
      historyReadback: context.config.cleanupKind === "cursor-cli-chat-leaf"
        ? expectedReplies.slice(0, 2).every((reply) =>
          `${nativeFirst.output}\n${arcResume.result.output}`.includes(reply))
          && expectedReplies.slice(2).every((reply) =>
            `${arcFirst.result.output}\n${nativeResume.output}`.includes(reply))
        : expectedReplies.slice(0, 2).every((reply) => firstHistory.includes(reply))
          && expectedReplies.slice(2).every((reply) => secondHistory.includes(reply)),
      noPermissionRequests: nativeFirst.permissionRequests === 0
        && nativeResume.permissionRequests === 0,
      noUnsupportedRequests: nativeFirst.unsupportedRequests === 0
        && nativeResume.unsupportedRequests === 0,
      boundedOutput: nativeFirst.boundedOutput
        && nativeResume.boundedOutput
        && readFirst.boundedOutput
        && readSecond.boundedOutput
        && arcResume.boundedOutput
        && arcFirst.boundedOutput,
      streamingSeen: publicStreamingSeen,
      structuredSeen: arcResume.structuredSeen === true && arcFirst.structuredSeen === true,
      cleanupVerified: false,
      permissionFailClosed: selfTestEvidence.permissionFailClosed,
      errorFailClosed: selfTestEvidence.errorFailClosed,
      settingsDigest: digest([
        nativeFirst.settings,
        arcSettings(arcResume.result),
        nativeResume.settings,
        arcSettings(arcFirst.result),
      ]),
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
      cleanupVerified = allDeleted && [...knownSessions].every((sessionId) => !verified.has(sessionId));
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
