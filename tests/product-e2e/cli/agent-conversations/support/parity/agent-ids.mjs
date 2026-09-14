import {
  verificationEffortForAgent,
  verificationModelForAgent,
} from "../../../../../../tools/scripts/lib/agent-conversation-verification-models.mjs";

export function normalizeAgentId(value) {
  const normalized = String(value).trim().toLowerCase().replaceAll("_", "-");
  const aliases = {
    kilo: "kilo-code",
    kilocode: "kilo-code",
    "github-copilot": "copilot",
    "hermes-agent": "hermes",
    "cursor-agent": "cursor",
    kimicode: "kimi-code",
  };
  return aliases[normalized] || normalized;
}

/** Verification / parity model for an agent. Env override, else TOML config. */
export function parityModelForAgent(agentId) {
  const environmentKey = `LICO_${agentId.toUpperCase().replaceAll("-", "_")}_PARITY_MODEL`;
  if (process.env[environmentKey]) return process.env[environmentKey];
  return verificationModelForAgent(agentId);
}

/**
 * Verification / parity reasoning effort paired with `model`. Env override,
 * else the pairing recorded next to the model authority.
 */
export function parityEffortForAgent(agentId, model) {
  const environmentKey = `LICO_${agentId.toUpperCase().replaceAll("-", "_")}_PARITY_REASONING_EFFORT`;
  if (process.env[environmentKey]) return process.env[environmentKey];
  return verificationEffortForAgent(agentId, model);
}
