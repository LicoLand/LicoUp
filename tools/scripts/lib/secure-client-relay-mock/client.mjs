import crypto from "node:crypto";
import http from "node:http";
import {
  ENCRYPTED_HEADER_BYTES,
  RELAY_ENVELOPE_SCHEMA,
  SESSION_COOKIE_NAME,
} from "./constants.mjs";
import { assert, exactKeys, validateCiphertextBucket } from "./helpers.mjs";

export function opaqueRelayEnvelopeFixture({ mailboxToken, ciphertextBucket = 256 } = {}) {
  assert(typeof mailboxToken === "string", "mailbox token is required");
  validateCiphertextBucket(ciphertextBucket);
  return {
    schema: RELAY_ENVELOPE_SCHEMA,
    deliveryId: crypto.randomBytes(24).toString("base64url"),
    mailboxToken,
    encryptedHeader: crypto.randomBytes(ENCRYPTED_HEADER_BYTES).toString("base64url"),
    ciphertextBucket,
    ciphertext: crypto.randomBytes(ciphertextBucket).toString("base64url")
  };
}

export async function secureClientRelayRequest(baseUrl, auth, path, body) {
  const response = await fetch(new URL(path, baseUrl), {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
      cookie: `${SESSION_COOKIE_NAME}=${auth.sessionToken}`,
      "x-lico-csrf": auth.csrfToken,
      "x-lico-safety-confirm": "true"
    },
    body: JSON.stringify(body)
  });
  return { status: response.status, body: await response.json() };
}
