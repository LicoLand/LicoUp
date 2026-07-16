import { stableReadFile } from "../lib/client-release-artifact-digest.mjs";
import { configRef, digestPattern, maxJsonBytes } from "./constants.mjs";
import { ReceiptValidationError } from "./errors.mjs";

export function requireValue(condition, code) {
  if (!condition) throw new ReceiptValidationError(code);
}

export function text(value) {
  return String(value || "").trim();
}

export function readJson(filePath) {
  return JSON.parse(stableReadFile(filePath, { maxBytes: maxJsonBytes }).toString("utf8"));
}

export function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function validatePolicyBindings(bindings) {
  const expected = [
    ["receipt-config", configRef],
    ["client-version", "tools/client-version.json"],
  ];
  requireValue(Array.isArray(bindings) && bindings.length === expected.length,
    "receipt_policy_bindings_missing");
  for (let index = 0; index < expected.length; index += 1) {
    requireValue(bindings[index]?.id === expected[index][0] &&
      bindings[index]?.ref === expected[index][1] &&
      digestPattern.test(text(bindings[index]?.digest)),
    "receipt_policy_binding_invalid");
  }
  return bindings;
}
