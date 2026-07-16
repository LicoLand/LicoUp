import { requireValue, isPlainObject } from "./util.mjs";

const forbiddenOutputKeys = new Set([
  "path",
  "absolutePath",
  "localPath",
  "deviceId",
  "deviceSerial",
  "deviceModel",
  "signingIdentity",
  "certificateSubject",
  "keyMaterial",
  "stdout",
  "stderr",
  "rawLog",
]);
const forbiddenOutputValues = [
  /\/(?:Users|home|private|tmp|var\/folders)\//u,
  /^[A-Za-z]:\\/u,
  /-----BEGIN|-----END/u,
  /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u,
];

export function assertReceiptPrivacy(value) {
  if (Array.isArray(value)) {
    for (const item of value) assertReceiptPrivacy(item);
    return true;
  }
  if (isPlainObject(value)) {
    for (const [key, nested] of Object.entries(value)) {
      requireValue(!isForbiddenOutputKey(key), "receipt_privacy_forbidden_field");
      assertReceiptPrivacy(nested);
    }
    return true;
  }
  if (typeof value === "string") {
    requireValue(forbiddenOutputValues.every((pattern) => !pattern.test(value)),
      "receipt_privacy_forbidden_value");
  }
  return true;
}

function isForbiddenOutputKey(key) {
  return forbiddenOutputKeys.has(key) ||
    /(?:(?:signer|certificate|team).*(?:digest|sha(?:256)?|fingerprint)|(?:digest|sha(?:256)?|fingerprint).*(?:signer|certificate|team))/iu.test(key);
}
