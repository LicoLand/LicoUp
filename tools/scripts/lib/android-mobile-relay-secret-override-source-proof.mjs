import { readFileSync } from "node:fs";
import path from "node:path";

const boundaryConfigRef = "tools/scripts/config/secure-mesh-client-boundary.json";
const sourceCheckId = "android-bridge-uses-opaque-mobile-relay-secret-store-handle";
const ruleId = "android-mobile-relay-bridge-does-not-send-raw-e2ee-json";

export function androidRawJsonSecretOverridesSourceProof(repoRoot) {
  const config = readJson(path.join(repoRoot, boundaryConfigRef));
  const sourceCheck = (config.sourceChecks || []).find((check) => check.id === sourceCheckId);
  const rule = (config.rules || []).find((item) => item.id === ruleId);
  const sourceFile = String(sourceCheck?.file || "");
  const source = sourceFile ? readText(path.join(repoRoot, sourceFile)) : "";
  const requiredTokens = stableUnique([
    ...(sourceCheck?.tokens || []),
    ".put(\"rawJsonSecretOverridesUsed\", false)"
  ]);
  const forbiddenTokens = stableUnique([
    ...(rule?.forbiddenTokens || []),
    ...(sourceCheck?.forbiddenTokens || [])
  ]);
  const missingTokens = requiredTokens.filter((token) => !source.includes(token));
  const forbiddenTokensPresent = forbiddenTokens.filter((token) => source.includes(token));
  return {
    configRef: boundaryConfigRef,
    sourceCheckId,
    ruleId,
    sourceFile,
    requiredTokenCount: requiredTokens.length,
    forbiddenTokenCount: forbiddenTokens.length,
    missingTokens,
    forbiddenTokensPresent,
    rawJsonSecretOverridesUsedStaticValue: false,
    staticSourceProofReady:
      missingTokens.length === 0 &&
      forbiddenTokensPresent.length === 0
  };
}

function readJson(file) {
  return JSON.parse(readText(file));
}

function readText(file) {
  return readFileSync(file, "utf8");
}

function stableUnique(values) {
  return Array.from(new Set(values.map((value) => String(value || "")).filter(Boolean))).sort();
}
