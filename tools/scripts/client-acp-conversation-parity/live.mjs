import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { productContinuityBindingDigest } from "../lib/agent-conversation-release-binding.mjs";
import { acceptanceMode, agentConfigs, strictRoundCount } from "./constants.mjs";
import { AcceptanceError, digest, requireFact } from "./errors.mjs";
import { writeReleaseUiAdapterEvidence } from "./evidence.mjs";
import { readPackagedAgents, validateProductReceipt } from "./packaging.mjs";
import { createPrivateWrapper } from "./process.mjs";
import { preflightCleanup } from "./session-cleanup.mjs";
import { resolveExecutable, resolveSidecar } from "./sidecar.mjs";
import { aggregateResult, blockedResult } from "./results.mjs";
import { runRound } from "./run-round.mjs";

export async function runLive(options, selfTestEvidence) {
  const config = agentConfigs[options.agent];
  requireFact(Boolean(config), "agent_not_acp_packaged");
  const packagedAgents = readPackagedAgents();
  const packaged = packagedAgents.has(config.id);
  if (!packaged) return blockedResult(config.id, options.strict, false, "agent_not_packaged", selfTestEvidence);
  let productReceipt = null;
  if (options.releaseUi) {
    try {
      productReceipt = validateProductReceipt(options.productReceipt, config.id);
    } catch (error) {
      return blockedResult(
        config.id,
        options.strict,
        true,
        error instanceof AcceptanceError ? error.code : "release_ui_product_receipt_invalid",
        selfTestEvidence,
      );
    }
  }
  if (config.cleanupKind === "unavailable") {
    return blockedResult(config.id, options.strict, true, config.cleanupBlocker, selfTestEvidence);
  }
  const binary = resolveExecutable(options.binary, config);
  if (!binary) return blockedResult(config.id, options.strict, true, "agent_executable_unavailable", selfTestEvidence);
  const sidecar = resolveSidecar(options.sidecar, { releaseUi: options.releaseUi });
  if (!sidecar) {
    return blockedResult(
      config.id,
      options.strict,
      true,
      options.releaseUi ? "release_ui_sidecar_unavailable" : "lico_client_executable_unavailable",
      selfTestEvidence,
    );
  }
  const temporaryDirectory = mkdtempSync(join(tmpdir(), "lico-acp-parity-"));
  try {
    const isolatedWorkingDirectory = join(temporaryDirectory, "workspace");
    mkdirSync(isolatedWorkingDirectory, { recursive: true });
    const wrapper = createPrivateWrapper(temporaryDirectory, binary);
    const disposableDataRoot = ["disposable-data-root", "pi-disposable-session-root"].includes(config.cleanupKind)
      ? join(temporaryDirectory, "isolated-agent-data")
      : "";
    const disposableSeedSource = config.cleanupKind === "disposable-data-root"
      ? (process.env[config.disposableEnvironmentKey] || join(homedir(), ".kimi-code"))
      : "";
    const environment = disposableDataRoot
      ? { ...process.env, [config.disposableEnvironmentKey]: disposableDataRoot }
      : process.env;
    wrapper.environment = {
      ...wrapper.environment,
      ...environment,
      LICO_AGENT_CONVERSATION_ACCEPTANCE: acceptanceMode,
    };
    const context = {
      config,
      binary,
      sidecar,
      wrapper,
      cwd: isolatedWorkingDirectory,
      environment,
      temporaryDirectory,
      disposableDataRoot,
      disposableSeedSource,
      disposableProfileSeeded: false,
      cleanedSessions: new Set(),
      timeoutMs: options.timeoutMs,
      maxOutputBytes: options.maxOutputBytes,
      copilotSdkLaunchArgs: null,
    };
    const cleanup = await preflightCleanup(context);
    if (!cleanup.ready) {
      return blockedResult(config.id, options.strict, true, cleanup.code, selfTestEvidence);
    }
    const rounds = [];
    const expectedRounds = options.strict ? strictRoundCount : 1;
    for (let index = 0; index < expectedRounds; index += 1) {
      const round = await runRound(context, index + 1, selfTestEvidence);
      rounds.push(round);
      if (!round.ready) break;
    }
    let aggregate = aggregateResult(config.id, options.strict, true, rounds, selfTestEvidence, {
      releaseUi: false,
    });
    if (options.releaseUi === true && aggregate.status === "core-passed") {
      aggregate = {
        ...aggregate,
        status: "release-ui-passed",
        releaseUiPassed: true,
        consecutivePasses: strictRoundCount,
        productReceiptJoined: true,
        productArtifactDigest: productReceipt.artifactDigest,
        productContinuityBindingDigest: productReceipt.continuityBindingDigest,
      };
      aggregate.evidenceDigest = digest({ ...aggregate, evidenceDigest: undefined });
    }
    let evidenceWrite = null;
    if (options.releaseUi === true) {
      evidenceWrite = writeReleaseUiAdapterEvidence(aggregate, context);
    }
    return { ...aggregate, evidenceWrite };
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}
