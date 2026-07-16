import { strictRoundCount } from "./constants.mjs";
import { digest, safeErrorCode } from "./errors.mjs";

export function aggregateResult(agentId, strict, packaged, rounds, selfTestEvidence, options = {}) {
  const releaseUi = options.releaseUi === true;
  const expectedRounds = strict ? strictRoundCount : 1;
  const completed = rounds.filter((round) => round.ready).length;
  const conversationCompleted = rounds.filter((round) => round.conversationReady).length;
  const allFacts = rounds.map((round) => round.facts).filter(Boolean);
  const every = (key) => allFacts.length === expectedRounds && allFacts.every((facts) => facts[key] === true);
  const corePassed = completed === expectedRounds;
  // consecutivePasses / releaseUiPassed / P-10 only advance under --release-ui.
  // Core-only --strict proves lane semantics and must never look like CL-06 ready.
  const result = {
    status: corePassed ? (releaseUi ? "release-ui-passed" : "core-passed") : "failed",
    agent: agentId,
    strict,
    packaged,
    cl06Ready: false,
    releaseUiPassed: releaseUi && corePassed,
    roundsRequired: expectedRounds,
    roundsCompleted: completed,
    conversationRoundsCompleted: conversationCompleted,
    conversationPassed: conversationCompleted === expectedRounds,
    roundsAttempted: rounds.length,
    testedSessions: rounds.reduce((total, round) => total + (round.testedSessions || 0), 0),
    requestCount: rounds.reduce((total, round) => total + (round.requestCount || 0), 0),
    successfulRequestCount: rounds.reduce((total, round) => total + (round.successfulRequestCount || 0), 0),
    roundResults: rounds.map((round) => ({
      round: round.roundIndex,
      conversationPassed: round.conversationReady === true,
      cleanupPassed: round.cleanupVerified === true,
      testedSessions: round.testedSessions || 0,
      requestCount: round.requestCount || 0,
      successfulRequestCount: round.successfulRequestCount || 0,
      errorCode: round.errorCode || null,
    })),
    consecutivePasses: releaseUi && corePassed ? completed : 0,
    officialNativeLane: every("nativeToArc") && every("arcToNative"),
    nativeToArc: every("nativeToArc"),
    arcToNative: every("arcToNative"),
    realSessionIds: every("realSessionIds"),
    finalCanaries: every("finalCanaries"),
    cwdParity: every("cwdParity"),
    settingsParity: every("settingsParity"),
    argvCanariesAbsent: every("argvCanariesAbsent"),
    historyReadback: every("historyReadback"),
    permissionFailClosed: selfTestEvidence.permissionFailClosed,
    errorFailClosed: selfTestEvidence.errorFailClosed,
    boundedOutput: every("boundedOutput") && selfTestEvidence.boundedOutputFailClosed,
    cleanupVerified: rounds.length === expectedRounds && rounds.every((round) => round.cleanupVerified),
    cleanupPassed: rounds.length === expectedRounds && rounds.every((round) => round.cleanupVerified),
    privacyPassed: every("argvCanariesAbsent") && every("boundedOutput"),
    streamingProven: every("streamingSeen"),
    structuredProven: every("structuredSeen"),
    cleanupCount: rounds.reduce((total, round) => total + round.cleanupCount, 0),
    errorCode: rounds.find((round) => round.conversationReady !== true)?.errorCode
      || rounds.find((round) => !round.ready)?.errorCode
      || null,
    evidenceDigest: "",
  };
  result.evidenceDigest = digest({ ...result, evidenceDigest: undefined });
  return result;
}

export function blockedResult(agentId, strict, packaged, code, selfTestEvidence) {
  const result = {
    status: "blocked",
    agent: agentId,
    strict,
    packaged,
    cl06Ready: false,
    releaseUiPassed: false,
    roundsRequired: strict ? strictRoundCount : 1,
    roundsCompleted: 0,
    conversationRoundsCompleted: 0,
    conversationPassed: false,
    roundsAttempted: 0,
    testedSessions: 0,
    requestCount: 0,
    successfulRequestCount: 0,
    roundResults: [],
    consecutivePasses: 0,
    officialNativeLane: false,
    nativeToArc: false,
    arcToNative: false,
    realSessionIds: false,
    finalCanaries: false,
    cwdParity: false,
    settingsParity: false,
    argvCanariesAbsent: false,
    historyReadback: false,
    permissionFailClosed: selfTestEvidence.permissionFailClosed,
    errorFailClosed: selfTestEvidence.errorFailClosed,
    boundedOutput: selfTestEvidence.boundedOutputFailClosed,
    cleanupVerified: false,
    cleanupPassed: false,
    privacyPassed: selfTestEvidence.boundedOutputFailClosed,
    streamingProven: false,
    structuredProven: false,
    cleanupCount: 0,
    errorCode: safeErrorCode(code),
    evidenceDigest: "",
  };
  result.evidenceDigest = digest({ ...result, evidenceDigest: undefined });
  return result;
}
