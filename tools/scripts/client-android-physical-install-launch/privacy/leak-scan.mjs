const slash = String.fromCharCode(47);
const escapedWindowsSeparator = String.fromCharCode(92).repeat(2);
const plaintextCanary = "android-physical-plaintext-canary-";
const encodedPlaintextCanaryPattern = new RegExp(
  [
    Buffer.from(plaintextCanary, "utf8").toString("base64").replace(/=+$/u, ""),
    Buffer.from(plaintextCanary, "utf8").toString("hex"),
    [...plaintextCanary]
      .map((character) =>
        `${escapedWindowsSeparator}u${character.codePointAt(0).toString(16).padStart(4, "0")}`)
      .join(""),
  ].join("|"),
  "iu",
);
const localPathPattern = new RegExp(
  [
    `${slash}Users${slash}`,
    `${slash}private${slash}`,
    `${slash}var${slash}folders${slash}`,
    `[A-Za-z]:${escapedWindowsSeparator}`,
  ].join("|"),
  "u",
);
const androidExternalPathPattern = new RegExp(
  [
    `${slash}sdcard${slash}`,
    `${slash}storage${slash}emulated${slash}`,
    `${slash}data${slash}data${slash}`,
  ].join("|"),
  "u",
);

export function assertNoLeak(value, label) {
  if (containsForbiddenStableIdentityKey(value)) {
    throw new Error(`${label} contains sensitive data: stable_signing_identity`);
  }
  const text = JSON.stringify(value);
  const patterns = [
    ["local_path", localPathPattern],
    ["android_external_path", androidExternalPathPattern],
    ["bearer", /Bearer\s+(?!\[redacted\])\S+/u],
    ["token", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u],
    ["raw_secret_value", /"(?:privateKeyBase64url|signingKeyBase64url|signedPrekeyPrivateKeyBase64url|oneTimePrekeyPrivateKeyBase64url|pairingSecretBase64url|sessionKey|rootKey|chainKey|messageKey|mobileToken|pcToken|pairingCode)"\s*:\s*"[^"]{8,}"/u],
    ["plaintext_canary", /android-physical-plaintext-canary-/u],
    ["lifecycle_service_action_canary", /android-lifecycle-private-/u],
    ["encoded_plaintext_canary", encodedPlaintextCanaryPattern],
    ["device_serial", /"(?:serial|adbSerial)"\s*:/u],
    ["device_model", /"model"\s*:/u]
  ];
  for (const [kind, pattern] of patterns) {
    if (pattern.test(text)) {
      throw new Error(`${label} contains sensitive data: ${kind}`);
    }
  }
}

function containsForbiddenStableIdentityKey(value) {
  if (Array.isArray(value)) {
    return value.some(containsForbiddenStableIdentityKey);
  }
  if (!value || typeof value !== "object") return false;
  return Object.entries(value).some(([key, nested]) => {
    const stableIdentityDigest =
      /(?:(?:signer|certificate|team).*(?:digest|sha(?:256)?|fingerprint)|(?:digest|sha(?:256)?|fingerprint).*(?:signer|certificate|team))/iu;
    return stableIdentityDigest.test(key) ||
      ["signingIdentity", "certificateSubject", "teamIdentifier"].includes(key) ||
      containsForbiddenStableIdentityKey(nested);
  });
}
