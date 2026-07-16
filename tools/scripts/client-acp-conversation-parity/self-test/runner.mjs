import { chmodSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { printLiveGateChecklist, readyCandidateAgentIds } from "../live-gate.mjs";
import { agentConfigs, dispatchLaneHarnessVersion, driversInventoryPath, strictRoundCount } from "../constants.mjs";
import { AcceptanceError, digest } from "../errors.mjs";
import { createSanitizedSelfTestEvidenceReceipt } from "../evidence.mjs";
import { nativeReadback, nativeTurn } from "../native/acp-turn.mjs";
import { nativePiReadback, nativePiTurn } from "../native/pi.mjs";
import { validateProductReceipt } from "../packaging.mjs";
import { createPrivateWrapper, seedDisposableProfile } from "../process.mjs";
import { canaryPrompt, failedParityFactCode, makeCanary, roundFactsReady } from "../round-facts.mjs";
import { aggregateResult, blockedResult } from "../results.mjs";
import { runRound } from "../run-round.mjs";
import { fakeRuntimeSource } from "./fake-runtime.mjs";
import { cleanupSession, preflightCleanup } from "../session-cleanup.mjs";
import { listSessions } from "../session-query.mjs";
import { probeDispatchLaneFamilies } from "../sidecar.mjs";

export async function exerciseFailClosed(context, prompt, expectedCode) {
  let sessionId = "";
  let code = "";
  try {
    const result = await nativeTurn(context, "", prompt);
    sessionId = result.sessionId;
  } catch (error) {
    code = error instanceof AcceptanceError ? error.code : "unexpected_failure";
  }
  let records = await listSessions(context);
  if (!sessionId) {
    for (const [id, record] of records) {
      if (record.includes(prompt)) sessionId = id;
    }
  }
  const cleanup = sessionId
    ? await cleanupSession(context, sessionId, context.temporaryDirectory)
    : false;
  records = await listSessions(context);
  return code === expectedCode && cleanup && !records.has(sessionId);
}

export async function runSelfTest() {
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "lico-acp-parity-selftest-"));
  const fakeBinary = join(temporaryDirectory, "fake-runtime");
  const statePath = join(temporaryDirectory, "state.json");
  try {
    const isolatedWorkingDirectory = join(temporaryDirectory, "workspace");
    mkdirSync(isolatedWorkingDirectory, { recursive: true });
    writeFileSync(fakeBinary, fakeRuntimeSource, { mode: 0o700 });
    chmodSync(fakeBinary, 0o700);
    writeFileSync(statePath, JSON.stringify({ counter: 0, sessions: {} }));
    const fixtureProductReceiptPath = join(temporaryDirectory, "fixture-product-receipt.json");
    writeFileSync(fixtureProductReceiptPath, JSON.stringify({
      schemaVersion: "fixture",
      status: "passed",
      receiptKind: "fixture",
      fixtureBackend: true,
    }), { mode: 0o600 });
    let productFixtureReceiptRejected = false;
    try {
      validateProductReceipt(fixtureProductReceiptPath, "codex");
    } catch (error) {
      productFixtureReceiptRejected = error instanceof AcceptanceError;
    }
    const seedSource = join(temporaryDirectory, "disposable-seed-source");
    const seedTarget = join(temporaryDirectory, "disposable-seed-target");
    mkdirSync(join(seedSource, "credentials"), { recursive: true, mode: 0o700 });
    mkdirSync(join(seedSource, "sessions"), { recursive: true, mode: 0o700 });
    writeFileSync(join(seedSource, "config.toml"), "[self_test]\n", { mode: 0o600 });
    writeFileSync(join(seedSource, "credentials", "account"), "self-test", { mode: 0o600 });
    writeFileSync(join(seedSource, "sessions", "must-not-copy"), "private", { mode: 0o600 });
    const disposableProfileSeedSafe = seedDisposableProfile({
      temporaryDirectory,
      disposableDataRoot: seedTarget,
      disposableSeedSource: seedSource,
    })
      && existsSync(join(seedTarget, "config.toml"))
      && existsSync(join(seedTarget, "credentials", "account"))
      && !existsSync(join(seedTarget, "sessions"));
    rmSync(seedTarget, { recursive: true, force: true });
    const environment = { ...process.env, LICO_FAKE_ACP_STATE: statePath };
    const wrapper = createPrivateWrapper(temporaryDirectory, fakeBinary);
    wrapper.environment = { ...wrapper.environment, ...environment };
    const context = {
      config: agentConfigs.opencode,
      binary: fakeBinary,
      sidecar: fakeBinary,
      wrapper,
      cwd: isolatedWorkingDirectory,
      environment,
      temporaryDirectory,
      timeoutMs: 10_000,
      maxOutputBytes: 32 * 1024,
      copilotSdkLaunchArgs: null,
    };
    const evidenceSeed = {
      permissionFailClosed: true,
      errorFailClosed: true,
      boundedOutputFailClosed: true,
    };
    const rounds = [];
    for (let index = 0; index < strictRoundCount; index += 1) {
      rounds.push(await runRound(context, index + 1, evidenceSeed));
    }
    const strictReducer = aggregateResult("opencode", true, true, rounds, evidenceSeed);
    const permissionFailClosed = await exerciseFailClosed(
      context,
      "SELFTEST_PERMISSION",
      "acp_permission_required",
    );
    const boundedOutputFailClosed = await exerciseFailClosed(
      { ...context, maxOutputBytes: 8 * 1024 },
      "SELFTEST_OVERFLOW",
      "acp_stdout_limit",
    );
    const failedFacts = { ...rounds[0].facts, nativeToArc: false };
    const errorFailClosed = !roundFactsReady(failedFacts);
    const factFailureCode = failedParityFactCode(failedFacts) === "parity_native_to_arc_failed";
    const cleanupBlocked = blockedResult(
      "openclaw",
      false,
      true,
      "session_cleanup_interface_unavailable",
      evidenceSeed,
    ).status === "blocked";
    const copilotState = JSON.parse(readFileSync(statePath, "utf8"));
    copilotState.sessions["fake-copilot-cleanup"] = { cwd: isolatedWorkingDirectory, messages: [] };
    writeFileSync(statePath, JSON.stringify(copilotState));
    const copilotContext = {
      ...context,
      config: agentConfigs.copilot,
      copilotSdkLaunchArgs: null,
    };
    const copilotPreflight = await preflightCleanup(copilotContext);
    const copilotCleanupRpc = copilotPreflight.ready
      && await cleanupSession(copilotContext, "fake-copilot-cleanup", temporaryDirectory);
    const openclawState = JSON.parse(readFileSync(statePath, "utf8"));
    openclawState.sessions["fake-openclaw-cleanup"] = {
      cwd: isolatedWorkingDirectory,
      messages: [],
    };
    writeFileSync(statePath, JSON.stringify(openclawState));
    const openclawContext = {
      ...context,
      config: agentConfigs.openclaw,
    };
    const openclawPreflight = await preflightCleanup(openclawContext);
    const openclawCleanupRpc = openclawPreflight.ready
      && await cleanupSession(
        openclawContext,
        "fake-openclaw-cleanup",
        temporaryDirectory,
      );
    const kiloState = JSON.parse(readFileSync(statePath, "utf8"));
    kiloState.sessions["fake-kilo-cleanup"] = {
      cwd: isolatedWorkingDirectory,
      messages: [{ role: "user", text: "kilo" }],
    };
    writeFileSync(statePath, JSON.stringify(kiloState));
    const kiloContext = {
      ...context,
      config: agentConfigs["kilo-code"],
    };
    const kiloPreflight = await preflightCleanup(kiloContext);
    const kiloCleanupCli = kiloPreflight.ready
      && await cleanupSession(kiloContext, "fake-kilo-cleanup", temporaryDirectory);
    const hermesState = JSON.parse(readFileSync(statePath, "utf8"));
    hermesState.sessions["fake-session-hermes"] = {
      cwd: isolatedWorkingDirectory,
      messages: [{ role: "user", text: "hermes" }],
    };
    writeFileSync(statePath, JSON.stringify(hermesState));
    const hermesContext = {
      ...context,
      config: agentConfigs.hermes,
    };
    const hermesPreflight = await preflightCleanup(hermesContext);
    const hermesListed = hermesPreflight.ready ? await listSessions(hermesContext) : new Map();
    const hermesStamp = [...hermesListed.keys()][0] || "";
    const hermesCleanupCli = hermesPreflight.ready
      && hermesStamp.length > 0
      && await cleanupSession(hermesContext, hermesStamp, temporaryDirectory);
    const kimiDisposableRoot = join(temporaryDirectory, "kimi-isolated");
    const kimiContext = {
      ...context,
      config: agentConfigs["kimi-code"],
      disposableDataRoot: kimiDisposableRoot,
      disposableSeedSource: seedSource,
      cleanedSessions: new Set(),
      observedSessions: new Set(["fake-kimi-session"]),
    };
    const kimiPreflight = await preflightCleanup(kimiContext);
    const kimiCleanup = kimiPreflight.ready
      && await cleanupSession(kimiContext, "fake-kimi-session", temporaryDirectory);
    const piDisposableRoot = join(temporaryDirectory, "pi-isolated-sessions");
    const piEnvironment = {
      ...environment,
      PI_CODING_AGENT_SESSION_DIR: piDisposableRoot,
    };
    const piWrapper = createPrivateWrapper(temporaryDirectory, fakeBinary);
    piWrapper.environment = { ...piWrapper.environment, ...piEnvironment };
    const piContext = {
      ...context,
      config: agentConfigs.pi,
      wrapper: piWrapper,
      environment: piEnvironment,
      disposableDataRoot: piDisposableRoot,
      disposableSeedSource: "",
      cleanedSessions: new Set(),
      observedSessions: new Set(),
    };
    const piPreflight = await preflightCleanup(piContext);
    let piRpcExactResume = false;
    let piCleanup = false;
    if (piPreflight.ready) {
      try {
        const first = await nativePiTurn(
          piContext,
          "",
          canaryPrompt(makeCanary(), "47"),
        );
        const resumed = await nativePiTurn(
          piContext,
          first.sessionId,
          canaryPrompt(makeCanary(), "53"),
        );
        const readback = await nativePiReadback(piContext, first.sessionId);
        piRpcExactResume = resumed.sessionId === first.sessionId
          && first.output === "47"
          && resumed.output === "53"
          && readback.text.includes("47")
          && readback.text.includes("53");
        piCleanup = await cleanupSession(piContext, first.sessionId, temporaryDirectory)
          && (await listSessions(piContext)).size === 0;
        // The fixture keeps its synthetic protocol state in the shared fake
        // runtime ledger in addition to the disposable Pi session files. Real
        // Pi has no such ledger; remove only fixture-tagged rows here.
        const piFixtureState = JSON.parse(readFileSync(statePath, "utf8"));
        for (const sessionId of Object.keys(piFixtureState.sessions)) {
          if (sessionId.startsWith("fake-pi-")) delete piFixtureState.sessions[sessionId];
        }
        writeFileSync(statePath, JSON.stringify(piFixtureState));
      } catch {
        piRpcExactResume = false;
        piCleanup = false;
      }
    }
    const codexContext = {
      ...context,
      config: agentConfigs.codex,
      cleanedSessions: new Set(),
      observedSessions: new Set(),
    };
    const codexPreflight = await preflightCleanup(codexContext);
    let codexRoundReady = false;
    let codexCleanupRpc = false;
    if (codexPreflight.ready) {
      const codexRound = await runRound(codexContext, 1, evidenceSeed);
      codexRoundReady = codexRound.ready === true
        && codexRound.facts?.nativeToArc === true
        && codexRound.facts?.arcToNative === true
        && codexRound.cleanupVerified === true;
      codexCleanupRpc = codexRound.cleanupVerified === true;
    }
    const coreOnlyAggregate = aggregateResult(
      "opencode",
      true,
      true,
      rounds,
      evidenceSeed,
      { releaseUi: false },
    );
    const releaseUiAggregate = aggregateResult(
      "opencode",
      true,
      true,
      rounds,
      evidenceSeed,
      { releaseUi: true },
    );
    const consecutivePassesFailClosed = coreOnlyAggregate.consecutivePasses === 0
      && coreOnlyAggregate.releaseUiPassed === false
      && coreOnlyAggregate.status === "core-passed"
      && releaseUiAggregate.consecutivePasses === strictRoundCount
      && releaseUiAggregate.releaseUiPassed === true
      && releaseUiAggregate.status === "release-ui-passed"
      && releaseUiAggregate.cl06Ready === false;
    const cursorDriver = JSON.parse(readFileSync(driversInventoryPath, "utf8"))
      .drivers
      .find((row) => row.agentId === "cursor");
    const cursorInventoryAligned = cursorDriver?.blockerCodes?.includes("safe_cleanup_unavailable") === true
      && cursorDriver?.capabilityMatrix?.exactResume === true
      && cursorDriver?.capabilityMatrix?.officialLane === true
      && cursorDriver?.driverMode === "blocked"
      && agentConfigs.cursor.cleanupKind === "unavailable"
      && agentConfigs.cursor.cleanupBlocker === "safe_cleanup_unavailable";
    const cursorContext = {
      ...context,
      config: agentConfigs.cursor,
      cleanedSessions: new Set(),
      observedSessions: new Set(),
    };
    let cursorSessionLoadOk = false;
    try {
      const cursorOpened = await nativeTurn(
        cursorContext,
        "",
        canaryPrompt(makeCanary(), "41"),
      );
      const cursorResumed = await nativeTurn(
        cursorContext,
        cursorOpened.sessionId,
        canaryPrompt(makeCanary(), "43"),
      );
      const cursorRead = await nativeReadback(cursorContext, cursorOpened.sessionId);
      cursorSessionLoadOk = cursorOpened.sessionId.length > 0
        && cursorResumed.sessionId === cursorOpened.sessionId
        && cursorRead.text.includes("41")
        && cursorRead.text.includes("43");
      // Self-test owns the temporary fake-runtime state file, so reclaim its
      // synthetic Cursor rows directly. This is not a production cleanup path
      // and never touches Cursor's real storage.
      const cursorFixtureState = JSON.parse(readFileSync(statePath, "utf8"));
      for (const sessionId of cursorContext.observedSessions || []) {
        delete cursorFixtureState.sessions[sessionId];
      }
      writeFileSync(statePath, JSON.stringify(cursorFixtureState));
    } catch {
      cursorSessionLoadOk = false;
    }
    const liveGate = printLiveGateChecklist();
    const cursorLiveGate = liveGate.adapters?.find((row) => row.agentId === "cursor");
    const liveGateReadyCandidates = Array.isArray(liveGate.adapters)
      && liveGate.adapters.length === readyCandidateAgentIds.length
      && liveGate.adapters.every((row) => row.remainingLiveGate.includes("authorize_side_effects"))
      && cursorLiveGate?.cleanupReady === false
      && cursorLiveGate?.remainingLiveGate?.includes("implement_safe_cleanup") === true
      && liveGate.cl06Ready === false;
    const remaining = await listSessions(context);
    const dispatchLaneProbe = probeDispatchLaneFamilies(fakeBinary);
    let evidenceWrite = null;
    if (dispatchLaneProbe.ok) {
      evidenceWrite = createSanitizedSelfTestEvidenceReceipt(dispatchLaneProbe);
    }
    const result = {
      status: strictReducer.status === "core-passed"
        && permissionFailClosed
        && boundedOutputFailClosed
        && errorFailClosed
        && factFailureCode
        && cleanupBlocked
        && copilotCleanupRpc
        && openclawCleanupRpc
        && kiloCleanupCli
        && hermesCleanupCli
        && kimiCleanup
        && piRpcExactResume
        && piCleanup
        && codexRoundReady
        && codexCleanupRpc
        && consecutivePassesFailClosed
        && cursorInventoryAligned
        && cursorSessionLoadOk
        && liveGateReadyCandidates
        && productFixtureReceiptRejected
        && disposableProfileSeedSafe
        && remaining.size === 0
        && dispatchLaneProbe.ok
        ? "passed"
        : "failed",
      cl06Ready: false,
      releaseUiPassed: false,
      strictRounds: strictReducer.roundsCompleted,
      nativeToArc: strictReducer.nativeToArc,
      arcToNative: strictReducer.arcToNative,
      realSessionIds: strictReducer.realSessionIds,
      finalCanaries: strictReducer.finalCanaries,
      cwdParity: strictReducer.cwdParity,
      settingsParity: strictReducer.settingsParity,
      argvCanariesAbsent: strictReducer.argvCanariesAbsent,
      historyReadback: strictReducer.historyReadback,
      permissionFailClosed,
      errorFailClosed,
      factFailureCode,
      boundedOutputFailClosed,
      cleanupBlocked,
      copilotCleanupRpc,
      openclawCleanupRpc,
      kiloCleanupCli,
      hermesCleanupCli,
      kimiCleanup,
      piRpcExactResume,
      piCleanup,
      codexRoundReady,
      codexCleanupRpc,
      consecutivePassesFailClosed,
      cursorInventoryAligned,
      cursorSessionLoadOk,
      liveGateReadyCandidates,
      productFixtureReceiptRejected,
      disposableProfileSeedSafe,
      dispatchLaneContract: dispatchLaneProbe.ok,
      laneFamiliesCovered: dispatchLaneProbe.laneFamiliesCovered,
      harnessVersion: dispatchLaneHarnessVersion,
      evidenceWrite,
      cleanupVerified: strictReducer.cleanupVerified && remaining.size === 0,
      cleanupCount: strictReducer.cleanupCount + 9,
      errorCode: null,
      evidenceDigest: "",
    };
    if (result.status !== "passed") result.errorCode = "self_test_failed";
    result.evidenceDigest = digest({ ...result, evidenceDigest: undefined });
    return result;
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}
