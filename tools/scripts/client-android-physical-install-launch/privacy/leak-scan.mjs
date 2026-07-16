export function assertNoLeak(value, label) {
  if (containsForbiddenStableIdentityKey(value)) {
    throw new Error(`${label} contains sensitive data: stable_signing_identity`);
  }
  const text = JSON.stringify(value);
  const patterns = [
    ["local_path", /\/Users\/|\/private\/|\/var\/folders\/|[A-Za-z]:\\/u],
    ["android_external_path", /\/sdcard\/|\/storage\/emulated\/|\/data\/data\//u],
    ["bearer", /Bearer\s+(?!\[redacted\])\S+/u],
    ["token", /\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9._-]{8,}\b/u],
    ["raw_secret_value", /"(?:privateKeyBase64url|signingKeyBase64url|signedPrekeyPrivateKeyBase64url|oneTimePrekeyPrivateKeyBase64url|pairingSecretBase64url|sessionKey|rootKey|chainKey|messageKey|mobileToken|pcToken|pairingCode)"\s*:\s*"[^"]{8,}"/u],
    ["plaintext_canary", /android-physical-plaintext-canary-/u],
    ["lifecycle_service_action_canary", /android-lifecycle-private-/u],
    ["encoded_plaintext_canary", /(?:YW5kcm9pZC1waHlzaWNhbC1wbGFpbnRleHQtY2FuYXJ5|616e64726f69642d706879736963616c2d706c61696e746578742d63616e617279|\\u0061\\u006e\\u0064\\u0072\\u006f\\u0069\\u0064\\u002d\\u0070\\u0068\\u0079\\u0073\\u0069\\u0063\\u0061\\u006c\\u002d\\u0070\\u006c\\u0061\\u0069\\u006e\\u0074\\u0065\\u0078\\u0074\\u002d\\u0063\\u0061\\u006e\\u0061\\u0072\\u0079)/iu],
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
