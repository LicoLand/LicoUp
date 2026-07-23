import { agentConfigs } from "./constants.mjs";

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

export function parityModelForAgent(agentId) {
  const environmentKey = `LICO_${agentId.toUpperCase().replaceAll("-", "_")}_PARITY_MODEL`;
  if (process.env[environmentKey]) return process.env[environmentKey];
  const configured = agentConfigs[agentId]?.parityModel;
  if (typeof configured === "string") return configured;
  if (agentId === "codex") return "";
  if (agentId === "kilo-code") return "Kilo Auto Free";
  return "";
}
