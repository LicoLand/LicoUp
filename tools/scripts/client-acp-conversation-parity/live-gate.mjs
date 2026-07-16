import { readFileSync } from "node:fs";
import {
  agentConfigs,
  dispatchLaneHarnessVersion,
  driversInventoryPath,
  evidenceManifestPath,
  strictRoundCount,
} from "./constants.mjs";
import { readPackagedAgents } from "./packaging.mjs";
import { resolveExecutable } from "./sidecar.mjs";

export const readyCandidateAgentIds = Object.freeze([
  "openclaw",
  "codex",
  "opencode",
  "copilot",
  "kilo-code",
  "cursor",
  "hermes",
  "kimi-code",
  "pi",
]);

export function printLiveGateChecklist() {
  const packaged = readPackagedAgents();
  const inventory = JSON.parse(readFileSync(driversInventoryPath, "utf8"));
  const evidence = JSON.parse(readFileSync(evidenceManifestPath, "utf8"));
  const evidenceAgents = new Set(
    (Array.isArray(evidence?.adapters) ? evidence.adapters : [])
      .map((row) => row?.agentId)
      .filter((value) => typeof value === "string"),
  );
  const gates = readyCandidateAgentIds.map((agentId) => {
    const config = agentConfigs[agentId];
    const driver = inventory.drivers.find((row) => row.agentId === agentId);
    const binary = resolveExecutable("", config);
    const cleanupReady = config.cleanupKind !== "unavailable";
    return {
      agentId,
      packaged: packaged.has(agentId),
      executablePresent: Boolean(binary),
      cleanupKind: config.cleanupKind,
      cleanupReady,
      laneFamily: config.laneFamily,
      officialLane: driver?.capabilityMatrix?.officialLane === true,
      evidenceRowPresent: evidenceAgents.has(agentId),
      // Core A/B never alone promotes ready / P-10 / consecutivePasses.
      remainingLiveGate: [
        !packaged.has(agentId) ? "package_adapter" : null,
        !cleanupReady ? "implement_safe_cleanup" : null,
        !binary ? "install_agent_binary" : null,
        "authorize_side_effects",
        `node tools/scripts/client-acp-conversation-parity.mjs --agent ${agentId} --strict`,
        "npm run client:run:macos  # release .app sidecar for P-10",
        `node tools/scripts/client-acp-conversation-parity.mjs --agent ${agentId} --strict --release-ui`,
        "repeat release-ui paired runs until consecutivePasses=3 (both directions each run)",
        "node tools/scripts/client-agent-conversation-parity-reducer.mjs --write",
      ].filter(Boolean),
      neverAloneEstablishesReady: [
        "npm run client:verify:agent-conversation-parity",
        "fixture/self-test rounds",
        "core-only --strict without --release-ui",
        agentId === "codex" ? "npm run client:verify:codex-conversation:live" : null,
      ].filter(Boolean),
    };
  });
  return {
    status: "live-gate-checklist",
    cl06Ready: false,
    releaseUiPassed: false,
    contractVersion: "CL-06",
    harnessVersion: dispatchLaneHarnessVersion,
    minimumConsecutivePasses: strictRoundCount,
    note: "Core/fixture passes never set ready or sendEnabled; only reducer-backed release-UI evidence can.",
    adapters: gates,
  };
}
