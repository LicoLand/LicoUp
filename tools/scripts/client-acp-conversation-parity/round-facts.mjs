import { randomUUID } from "node:crypto";
import { join } from "node:path";

export function makeCanary() {
  // Keep the marker unique without resembling a credential. Some native
  // agents correctly refuse to repeat long opaque token-shaped strings, which
  // would turn a model safety behavior into a false transport-parity failure.
  return `LICO-PARITY-MARKER-${randomUUID().replaceAll("-", "").slice(0, 12).toUpperCase()}`;
}

export function canaryPrompt(canary, expectedReply) {
  return `Acceptance marker ${canary}; do not repeat the marker. Reply with exactly ${expectedReply} and no other text. Do not call tools or request permissions.`;
}

export function normalizedMarker(value) {
  return String(value || "").toLowerCase().replaceAll(/[^a-z0-9]/gu, "");
}

export function outputCategoryCode(value) {
  const output = String(value || "").toLowerCase();
  const categories = [
    ["a", /auth|login|credential|unauthorized|token/u],
    ["q", /quota|rate.?limit|usage.?limit/u],
    ["p", /permission|sandbox|denied|forbidden/u],
    ["s", /server|service|internal|unavailable|network|connect/u],
    ["r", /cannot|can't|unable|refus|policy/u],
  ];
  return categories.find(([, pattern]) => pattern.test(output))?.[0] || "o";
}

export function roundFactsReady(facts) {
  return roundConversationFactsReady(facts)
    && facts.cleanupVerified;
}

export const processLocalBooleanFactKeys = Object.freeze([
  "persistentHost",
  "openNew",
  "exactSessionId",
  "processLocalContinuation",
  "orderedStreaming",
  "historyReadback",
  "boundedHistory",
  "cleanupVerified",
  "cleanupSynchronized",
  "registryAbsent",
  "historyCleared",
  "hostLiveAfterCleanup",
  "argvCanariesAbsent",
  "noResumeArgument",
  "noPersistenceArgument",
  "genericModelForwarded",
  "noPromptHistory",
  "noPersistedTranscript",
  "boundedOutput",
  "cancelNotAdvertised",
  "structuredSeen",
  "permissionFailClosed",
  "errorFailClosed",
]);

export function processLocalRoundFactsReady(facts) {
  return facts?.continuityScope === "process-local"
    && processLocalBooleanFactKeys.every((key) => facts[key] === true);
}

export function processLocalHostShutdownEvidence(options) {
  const complete = options !== null
    && typeof options === "object"
    && Object.hasOwn(options, "hostShutdownPassed")
    && typeof options.hostShutdownPassed === "boolean";
  return {
    complete,
    passed: complete && options.hostShutdownPassed === true,
  };
}

export function failedProcessLocalFactCode(facts) {
  const orderedFacts = [
    ["persistentHost", "persistent_host"],
    ["openNew", "open_new"],
    ["exactSessionId", "exact_session"],
    ["processLocalContinuation", "continuation"],
    ["orderedStreaming", "streaming"],
    ["historyReadback", "history"],
    ["boundedHistory", "history_bound"],
    ["cleanupVerified", "cleanup"],
    ["cleanupSynchronized", "cleanup_sync"],
    ["registryAbsent", "registry"],
    ["historyCleared", "history_clear"],
    ["hostLiveAfterCleanup", "host_liveness"],
    ["argvCanariesAbsent", "argv_privacy"],
    ["noResumeArgument", "argv_resume"],
    ["noPersistenceArgument", "no_persistence"],
    ["genericModelForwarded", "model_forwarding"],
    ["noPromptHistory", "prompt_history"],
    ["noPersistedTranscript", "disk_persistence"],
    ["boundedOutput", "bounded_output"],
    ["cancelNotAdvertised", "cancel_capability"],
    ["structuredSeen", "structured_event"],
    ["permissionFailClosed", "permission"],
    ["errorFailClosed", "error"],
  ];
  const failed = orderedFacts.find(([key]) => facts?.[key] !== true);
  return failed ? `process_local_${failed[1]}_failed` : "process_local_fact_failed";
}

export function roundConversationFactsReady(facts) {
  return facts.nativeToArc
    && facts.arcToNative
    && facts.realSessionIds
    && facts.finalCanaries
    && facts.cwdParity
    && facts.settingsParity
    && facts.argvCanariesAbsent
    && facts.historyReadback
    && facts.noPermissionRequests
    && facts.noUnsupportedRequests
    && facts.boundedOutput
    && facts.streamingSeen;
}

export function failedParityFactCode(facts) {
  if (facts.finalCanaries !== true) {
    const presentMask = [
      facts.nativeFirstFinalCanaryPresent,
      facts.arcResumeFinalCanaryPresent,
      facts.arcFirstFinalCanaryPresent,
      facts.nativeResumeFinalCanaryPresent,
    ].map((value) => value === true ? "1" : "0").join("");
    const exactMask = [
      facts.nativeFirstFinalCanary,
      facts.arcResumeFinalCanary,
      facts.arcFirstFinalCanary,
      facts.nativeResumeFinalCanary,
    ].map((value) => value === true ? "1" : "0").join("");
    const normalizedMask = [
      facts.nativeFirstFinalCanaryNormalized,
      facts.arcResumeFinalCanaryNormalized,
      facts.arcFirstFinalCanaryNormalized,
      facts.nativeResumeFinalCanaryNormalized,
    ].map((value) => value === true ? "1" : "0").join("");
    const equalityMask = [
      facts.firstSessionOutputsEqual,
      facts.secondSessionOutputsEqual,
      facts.allOutputsEqual,
    ].map((value) => value === true ? "1" : "0").join("");
    const categoryMask = [
      facts.nativeFirstOutputCategory,
      facts.arcResumeOutputCategory,
      facts.arcFirstOutputCategory,
      facts.nativeResumeOutputCategory,
    ].map((value) => /^[aqpsro]$/u.test(value) ? value : "o").join("");
    return `parity_final_p${presentMask}_n${normalizedMask}_e${exactMask}_q${equalityMask}_c${categoryMask}`;
  }
  if (facts.settingsParity !== true && /^[01]{6}$/u.test(facts.settingsParityMask || "")) {
    return `parity_settings_m${facts.settingsParityMask}_failed`;
  }
  const orderedFacts = [
    ["nativeToArc", "native_to_arc"],
    ["arcToNative", "arc_to_native"],
    ["realSessionIds", "real_session_ids"],
    ["nativeFirstFinalCanaryPresent", "native_first_final_canary_missing"],
    ["nativeFirstFinalCanary", "native_first_final_canary"],
    ["arcResumeFinalCanaryPresent", "arc_resume_final_canary_missing"],
    ["arcResumeFinalCanary", "arc_resume_final_canary"],
    ["arcFirstFinalCanaryPresent", "arc_first_final_canary_missing"],
    ["arcFirstFinalCanary", "arc_first_final_canary"],
    ["nativeResumeFinalCanaryPresent", "native_resume_final_canary_missing"],
    ["nativeResumeFinalCanary", "native_resume_final_canary"],
    ["finalCanaries", "final_canaries"],
    ["cwdParity", "cwd_parity"],
    ["settingsParity", "settings_parity"],
    ["argvCanariesAbsent", "argv_privacy"],
    ["historyReadback", "history_readback"],
    ["noPermissionRequests", "permission_request"],
    ["noUnsupportedRequests", "unsupported_request"],
    ["boundedOutput", "bounded_output"],
    ["streamingSeen", "streaming"],
    ["cleanupVerified", "cleanup"],
  ];
  const failed = orderedFacts.find(([key]) => facts[key] !== true);
  return failed ? `parity_${failed[1]}_failed` : "parity_fact_failed";
}
