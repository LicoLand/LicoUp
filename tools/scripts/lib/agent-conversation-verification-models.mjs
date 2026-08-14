import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const moduleRoot = dirname(fileURLToPath(import.meta.url));
export const verificationModelsPath = join(
  moduleRoot,
  "..",
  "config",
  "agent-conversation-verification-models.toml",
);

export const VERIFICATION_MODELS_SCHEMA =
  "licoup.agent-conversation-verification-models.v1";

/** @type {{ schemaVersion: string, models: Readonly<Record<string, string>> } | null} */
let cached = null;

/**
 * Constrained TOML reader for this config only:
 * top-level `schema_version`, then `[models]` with `key = "value"` rows.
 */
export function parseVerificationModelsToml(source) {
  if (typeof source !== "string" || source.trim().length === 0) {
    throw new Error("verification_models_empty");
  }
  let section = null;
  let schemaVersion = "";
  const models = {};
  for (const rawLine of source.split(/\r?\n/u)) {
    const line = rawLine.replace(/#.*$/u, "").trim();
    if (!line) continue;
    const sectionMatch = line.match(/^\[([^\]]+)\]$/u);
    if (sectionMatch) {
      section = sectionMatch[1].trim();
      if (section !== "models") {
        throw new Error(`verification_models_section_unsupported:${section}`);
      }
      continue;
    }
    const assignment = line.match(
      /^(?:([A-Za-z0-9_-]+)|"([^"]+)")\s*=\s*"((?:\\.|[^"\\])*)"$/u,
    );
    if (!assignment) {
      throw new Error("verification_models_toml_invalid");
    }
    const key = assignment[1] || assignment[2];
    const value = assignment[3].replace(/\\([\\"])/gu, "$1");
    if (!key || value.length === 0) {
      throw new Error("verification_models_entry_invalid");
    }
    if (section === null) {
      if (key !== "schema_version") {
        throw new Error(`verification_models_key_unsupported:${key}`);
      }
      schemaVersion = value;
      continue;
    }
    if (section === "models") {
      if (Object.prototype.hasOwnProperty.call(models, key)) {
        throw new Error(`verification_models_duplicate:${key}`);
      }
      models[key] = value;
    }
  }
  if (schemaVersion !== VERIFICATION_MODELS_SCHEMA) {
    throw new Error("verification_models_schema_invalid");
  }
  if (Object.keys(models).length === 0) {
    throw new Error("verification_models_empty");
  }
  return {
    schemaVersion,
    models: Object.freeze({ ...models }),
  };
}

/** Load once per process; subsequent calls return the frozen cache. */
export function loadVerificationModels(options = {}) {
  if (!options.reload && cached) return cached;
  const text = readFileSync(
    options.path || verificationModelsPath,
    "utf8",
  );
  cached = Object.freeze(parseVerificationModelsToml(text));
  return cached;
}

export function verificationModelForAgent(agentId, options = {}) {
  const id = String(agentId || "").trim();
  if (!id) return "";
  const { models } = loadVerificationModels(options);
  return typeof models[id] === "string" ? models[id] : "";
}

export function verificationModelsMap(options = {}) {
  return loadVerificationModels(options).models;
}
