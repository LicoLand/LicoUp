import { readFileSync } from "node:fs";
import {
  agentConfigs,
  dispatchLaneHarnessVersion,
  driversInventoryPath,
  evidenceManifestPath,
  sameSessionGateAgentIds,
  strictRoundCount,
} from "./constants.mjs";
import { readPackagedAgents } from "./packaging.mjs";
import { resolveExecutable } from "./sidecar.mjs";

export const readyCandidateAgentIds = Object.freeze(Object.keys(agentConfigs));

// Derived from agentConfigs.sameSessionGate — not an agent-id allowlist.
const sameSessionAgents = new Set(sameSessionGateAgentIds);
const arcLocalServiceAgents = new Set(["codex", "opencode"]);

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
    const sameSession = sameSessionAgents.has(agentId);
    const arcLocal = arcLocalServiceAgents.has(agentId);
    return {
      agentId,
      packaged: packaged.has(agentId),
      executablePresent: Boolean(binary),
      cleanupKind: config.cleanupKind,
      cleanupReady,
      laneFamily: config.laneFamily,
      officialLane: driver?.capabilityMatrix?.officialLane === true,
      evidenceRowPresent: evidenceAgents.has(agentId),
      remainingLiveGate: [
        !packaged.has(agentId) ? "package_adapter" : null,
        !cleanupReady ? "implement_safe_cleanup" : null,
        !binary ? "install_agent_binary" : null,
        "authorize_side_effects",
        arcLocal
          ? `node tools/scripts/client-up-local-service-conversation-gate.mjs --agent ${agentId}`
          : sameSession
            ? `node tools/scripts/client-same-session-conversation-gate.mjs --agent ${agentId}`
            : `node tools/scripts/client-acp-conversation-parity.mjs --agent ${agentId} --strict`,
        arcLocal || sameSession
          ? null
          : "npm run client:run:macos  # release .app sidecar for P-10",
        arcLocal || sameSession
          ? null
          : `node tools/scripts/client-acp-conversation-parity.mjs --agent ${agentId} --strict --release-ui`,
        arcLocal || sameSession
          ? null
          : "repeat release-ui paired runs until consecutivePasses=3 (both directions each run)",
        arcLocal || sameSession
          ? null
          : "node tools/scripts/client-agent-conversation-parity-reducer.mjs --write",
      ].filter(Boolean),
      neverAloneEstablishesReady: [
        "npm run client:verify:agent-conversation-parity",
        "fixture/self-test rounds",
        arcLocal
          ? "native-only same-session gate without Arc resume"
          : sameSession
            ? "core-only --strict without same-session gate write"
            : "core-only --strict without --release-ui",
        agentId === "codex" ? "npm run client:demo:device:macos:codex-parity" : null,
      ].filter(Boolean),
    };
  });
  return {
    status: "live-gate-checklist",
    cl06Ready: false,
    conversationGatePassed: false,
    contractVersion: "CL-06",
    harnessVersion: dispatchLaneHarnessVersion,
    minimumConsecutivePasses: strictRoundCount,
    note: "Core/fixture passes never set ready or sendEnabled. Cursor/Kimi Code promote via same-session gate; Codex/OpenCode promote via Arc↔native local-service gate; others still require reducer-backed release-UI evidence.",
    adapters: gates,
  };
}
