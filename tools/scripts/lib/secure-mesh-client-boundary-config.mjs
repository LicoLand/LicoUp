import fs from "node:fs/promises";
import { normalizeSourceCheckFiles } from "./source-check-bundle.mjs";

const configUrl = new URL("../config/secure-mesh-client-boundary.json", import.meta.url);
const configRef = "tools/scripts/config/secure-mesh-client-boundary.json";
const schemaVersion = "licolite.secure-mesh.client-boundary-config.v1";
const leakPatterns = Object.freeze([
  ["local_path", /\/Users\/|\/private\/|\/var\/folders\/|[A-Za-z]:\\/u],
  ["bearer", /Bearer\s+(?!\[redacted\])\S+/u],
  ["token", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u],
  ["pem_material", /-----BEGIN|-----END/u],
  ["raw_secret_value", /"(?:privateKey|sessionKey|rootKey|chainKey|messageKey|rawSecret|secretMaterial)"\s*:\s*"(?!redacted|\[redacted\])[^"]{8,}"/u]
]);
let cachedConfig;

function asRecord(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function assertNoLeak(value, label) {
  const text = JSON.stringify(value);
  for (const [kind, pattern] of leakPatterns) {
    if (pattern.test(text)) {
      throw new Error(`${label} contains sensitive data: ${kind}`);
    }
  }
}

function normalizeCheckId(value, label) {
  const id = String(value || "").trim();
  if (!/^[a-z0-9][a-z0-9_-]{2,120}$/u.test(id)) {
    throw new Error(`Invalid Secure Mesh client boundary ${label}: ${id || "<empty>"}`);
  }
  return id;
}

function normalizeSafeRootRef(value, label) {
  const ref = String(value || "").trim().replaceAll("\\", "/");
  if (!ref ||
    ref.startsWith("/") ||
    ref.startsWith("file:") ||
    /^https?:\/\//iu.test(ref) ||
    ref.split("/").includes("..") ||
    !/^(?:apps|crates|tools)\/[A-Za-z0-9._/@+-]+(?:\/[A-Za-z0-9._/@+-]+)*$/u.test(ref)) {
    throw new Error(`Invalid Secure Mesh client boundary ${label}: ${ref || "<empty>"}`);
  }
  return ref;
}

function normalizeSafeSourceRef(value, label) {
  const ref = normalizeSafeRootRef(value, label);
  if (!/\.(?:dart|rs|swift|kt|mjs|json|md|toml|yaml|yml|plist|xml|entitlements)$/u.test(ref)) {
    throw new Error(`Invalid Secure Mesh client boundary ${label}: ${ref}`);
  }
  return ref;
}

function normalizeExtensionList(value, label) {
  const items = Array.isArray(value) ? value.map((item) => String(item || "").trim()) : [];
  const extensions = items.filter(Boolean);
  if (extensions.length === 0) {
    throw new Error(`Secure Mesh client boundary config must define ${label}`);
  }
  for (const extension of extensions) {
    if (!/^\.[a-z0-9]+$/u.test(extension)) {
      throw new Error(`Invalid Secure Mesh client boundary ${label}: ${extension}`);
    }
  }
  if (new Set(extensions).size !== extensions.length) {
    throw new Error(`Secure Mesh client boundary ${label} must be unique`);
  }
  return extensions;
}

function normalizeTokenList(value, label) {
  const tokens = Array.isArray(value) ? value.map((item) => String(item || "").trim()) : [];
  const normalized = tokens.filter(Boolean);
  if (normalized.length === 0) {
    throw new Error(`Secure Mesh client boundary config must define ${label}`);
  }
  for (const token of normalized) {
    if (/[\r\n]/u.test(token) || token.length > 240) {
      throw new Error(`Invalid Secure Mesh client boundary ${label}`);
    }
    assertNoLeak(token, `secure mesh client boundary ${label}`);
  }
  if (new Set(normalized).size !== normalized.length) {
    throw new Error(`Secure Mesh client boundary ${label} must be unique`);
  }
  return normalized;
}

function normalizeOptionalTokenList(value, label) {
  const tokens = Array.isArray(value) ? value.map((item) => String(item || "").trim()) : [];
  const normalized = tokens.filter(Boolean);
  for (const token of normalized) {
    if (/[\r\n]/u.test(token) || token.length > 240) {
      throw new Error(`Invalid Secure Mesh client boundary ${label}`);
    }
    assertNoLeak(token, `secure mesh client boundary ${label}`);
  }
  if (new Set(normalized).size !== normalized.length) {
    throw new Error(`Secure Mesh client boundary ${label} must be unique`);
  }
  return normalized;
}

function normalizeAllowedMatches(value, ruleId, forbiddenTokens) {
  const matches = Array.isArray(value) ? value : [];
  const forbiddenTokenSet = new Set(forbiddenTokens);
  return matches.map((item, index) => {
    const match = asRecord(item);
    const file = normalizeSafeSourceRef(match.file, `rule ${ruleId} allowed match ${index + 1} file`);
    const tokens = normalizeTokenList(match.tokens, `rule ${ruleId} allowed match ${index + 1} tokens`);
    for (const token of tokens) {
      if (!forbiddenTokenSet.has(token)) {
        throw new Error(`Secure Mesh client boundary allowed token is not forbidden by rule ${ruleId}: ${token}`);
      }
    }
    const reason = String(match.reason || "").trim();
    if (!reason || /[\r\n]/u.test(reason) || reason.length > 300) {
      throw new Error(`Secure Mesh client boundary rule ${ruleId} allowed match must explain the exception`);
    }
    assertNoLeak(reason, `secure mesh client boundary rule ${ruleId} allowed match reason`);
    return { file, tokens, reason };
  });
}

function normalizeRules(value) {
  const rules = Array.isArray(value) ? value : [];
  if (rules.length === 0) {
    throw new Error("Secure Mesh client boundary config must define rules");
  }
  const normalized = rules.map((item, index) => {
    const rule = asRecord(item);
    const id = normalizeCheckId(rule.id, `rule ${index + 1} id`);
    const description = String(rule.description || "").trim();
    if (!description || /[\r\n]/u.test(description) || description.length > 400) {
      throw new Error(`Secure Mesh client boundary rule ${id} must define a short description`);
    }
    assertNoLeak(description, `secure mesh client boundary rule ${id} description`);
    const roots = normalizeTokenList(rule.roots, `rule ${id} roots`)
      .map((root, rootIndex) => normalizeSafeRootRef(root, `rule ${id} root ${rootIndex + 1}`));
    const includeExtensions = normalizeExtensionList(rule.includeExtensions, `rule ${id} include extensions`);
    const forbiddenTokens = normalizeTokenList(rule.forbiddenTokens, `rule ${id} forbidden tokens`);
    return {
      id,
      description,
      roots,
      includeExtensions,
      forbiddenTokens,
      allowedMatches: normalizeAllowedMatches(rule.allowedMatches, id, forbiddenTokens)
    };
  });
  const ids = normalized.map((rule) => rule.id);
  if (new Set(ids).size !== ids.length) {
    throw new Error("Secure Mesh client boundary config rules must have unique ids");
  }
  return normalized;
}

function normalizeSourceChecks(value) {
  const checks = Array.isArray(value) ? value : [];
  if (checks.length === 0) {
    throw new Error("Secure Mesh client boundary config must define source checks");
  }
  const normalized = checks.map((item, index) => {
    const check = asRecord(item);
    const files = normalizeSourceCheckFiles(
      check,
      normalizeSafeSourceRef,
      `Secure Mesh client boundary source check ${index + 1}`,
    );
    const tokens = normalizeOptionalTokenList(check.tokens, `source check ${index + 1} tokens`);
    const forbiddenTokens = normalizeOptionalTokenList(
      check.forbiddenTokens,
      `source check ${index + 1} forbidden tokens`
    );
    if (tokens.length === 0 && forbiddenTokens.length === 0) {
      throw new Error(`Secure Mesh client boundary source check ${index + 1} must define tokens or forbidden tokens`);
    }
    return {
      id: normalizeCheckId(check.id, `source check ${index + 1} id`),
      file: files[0],
      files,
      tokens,
      forbiddenTokens
    };
  });
  const ids = normalized.map((check) => check.id);
  if (new Set(ids).size !== ids.length) {
    throw new Error("Secure Mesh client boundary config source checks must have unique ids");
  }
  return normalized;
}

async function loadRawConfig() {
  if (cachedConfig) {
    return cachedConfig;
  }
  const payload = JSON.parse(await fs.readFile(configUrl, "utf8"));
  if (payload?.schemaVersion !== schemaVersion) {
    throw new Error("Secure Mesh client boundary config schema version mismatch");
  }
  assertNoLeak(payload, "secure mesh client boundary config");
  cachedConfig = {
    configRef,
    schemaVersion,
    rules: normalizeRules(payload.rules),
    sourceChecks: normalizeSourceChecks(payload.sourceChecks)
  };
  return cachedConfig;
}

export async function loadSecureMeshClientBoundaryConfig() {
  return loadRawConfig();
}
