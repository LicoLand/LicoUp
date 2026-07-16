import { createHash } from "node:crypto";
import http from "node:http";
import {
  STORE_SCHEMA_VERSION,
  DEVICE_TRUST_PROTOCOL_VERSION,
  DELIVERY_PROTOCOL_VERSION,
  RELAY_ENVELOPE_SCHEMA,
  MAX_REQUEST_BYTES,
  ENCRYPTED_HEADER_BYTES,
  MAX_CIPHERTEXT_BUCKET_BYTES,
  LARGE_BUCKET_STEP_BYTES,
  SESSION_COOKIE_NAME,
} from "./constants.mjs";

export function assert(condition, message) {
  if (!condition) throw new Error(message);
}

export function exactKeys(value, expected, label) {
  assert(value && typeof value === "object" && !Array.isArray(value), `${label} must be an object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  assert(JSON.stringify(actual) === JSON.stringify(wanted), `${label} fields are not exact`);
}

export function exactKeysWithOptional(value, required, optional, label) {
  assert(value && typeof value === "object" && !Array.isArray(value), `${label} must be an object`);
  const keys = Object.keys(value);
  assert(required.every((key) => keys.includes(key)), `${label} is missing a required field`);
  assert(keys.every((key) => required.includes(key) || optional.includes(key)), `${label} has an unknown field`);
}

export function canonicalBase64url(value, encodedLength, label) {
  assert(typeof value === "string" && value.length === encodedLength, `${label} length is invalid`);
  assert(/^[A-Za-z0-9_-]+$/u.test(value), `${label} is not canonical base64url`);
  const decoded = Buffer.from(value, "base64url");
  assert(decoded.toString("base64url") === value, `${label} is not canonical base64url`);
  return decoded;
}

export function validateScope(body) {
  for (const key of ["tenantId", "accountId"]) {
    assert(typeof body[key] === "string" && body[key].length > 0 && body[key].length <= 255,
      `${key} is invalid`);
  }
  if (body.workspaceId !== undefined) {
    assert(typeof body.workspaceId === "string" && body.workspaceId.length <= 255,
      "workspaceId is invalid");
  }
}

export function scopeKey(body) {
  return `${body.tenantId}\u0000${body.accountId}\u0000${body.workspaceId || ""}`;
}

export function validatePublicJwk(value, curve) {
  exactKeys(value, ["kty", "crv", "x"], `${curve} public JWK`);
  assert(value.kty === "OKP" && value.crv === curve, `${curve} public JWK profile is invalid`);
  canonicalBase64url(value.x, 43, `${curve} public JWK x`);
}

export function validateCiphertextBucket(bucket) {
  assert(Number.isSafeInteger(bucket) && bucket >= 256 && bucket <= MAX_CIPHERTEXT_BUCKET_BYTES,
    "ciphertext bucket is outside bounds");
  if (bucket <= LARGE_BUCKET_STEP_BYTES) {
    assert((bucket & (bucket - 1)) === 0, "ciphertext bucket is not a supported power-of-two bucket");
  } else {
    assert(bucket % LARGE_BUCKET_STEP_BYTES === 0, "ciphertext bucket is not aligned");
  }
}

export function validateEnvelope(envelope, outerFields) {
  exactKeys(envelope, outerFields, "relay envelope");
  assert(envelope.schema === RELAY_ENVELOPE_SCHEMA, "relay envelope schema is unsupported");
  canonicalBase64url(envelope.deliveryId, 32, "delivery id");
  canonicalBase64url(envelope.mailboxToken, 43, "mailbox token");
  const header = canonicalBase64url(envelope.encryptedHeader, 5462, "encrypted header");
  assert(header.length === ENCRYPTED_HEADER_BYTES, "encrypted header decoded length is invalid");
  validateCiphertextBucket(envelope.ciphertextBucket);
  const ciphertext = Buffer.from(String(envelope.ciphertext || ""), "base64url");
  assert(ciphertext.length === envelope.ciphertextBucket && ciphertext.toString("base64url") === envelope.ciphertext,
    "ciphertext is not canonical or does not match its bucket");
}

export function timestamp() {
  return new Date().toISOString();
}

export function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function publicMailbox(scope, mailboxToken, state, endpointId = "mock-endpoint") {
  const live = state.queue.filter((entry) => !entry.acked);
  return {
    tenantId: scope.tenantId,
    accountId: scope.accountId,
    workspaceId: scope.workspaceId || "",
    endpointId,
    mailboxToken,
    queueBytes: live.reduce((total, entry) => total + entry.wireBytes, 0),
    queuedCount: live.length,
    oldestQueuedAt: live[0]?.queuedAt || "",
    deliverySequence: state.sequence,
    receiptCount: state.receiptCount,
    ackedCount: state.ackedCount,
    updatedAt: state.updatedAt
  };
}

export function errorBody(protocolVersion, code, message) {
  return {
    ok: false,
    schemaVersion: STORE_SCHEMA_VERSION,
    protocolVersion,
    code,
    error: message
  };
}

export function sendJson(response, status, body) {
  const bytes = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": String(bytes.length),
    "cache-control": "no-store"
  });
  response.end(bytes);
}

export async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    assert(size <= MAX_REQUEST_BYTES, "request body exceeds the resource limit");
    chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks);
  assert(bytes.length > 0, "request body is required");
  return { bytes, value: JSON.parse(bytes.toString("utf8")) };
}

export function authIsValid(request, options) {
  if (!options.requireAuth) return true;
  const cookies = String(request.headers.cookie || "").split(";").map((value) => value.trim());
  return cookies.includes(`${SESSION_COOKIE_NAME}=${options.sessionToken}`) &&
    request.headers["x-lico-csrf"] === options.csrfToken &&
    request.headers["x-lico-safety-confirm"] === "true";
}

export function mailboxState(mailboxes, token) {
  let state = mailboxes.get(token);
  if (!state) {
    state = {
      sequence: 0,
      queue: [],
      receipts: new Map(),
      receiptCount: 0,
      ackedCount: 0,
      updatedAt: timestamp()
    };
    mailboxes.set(token, state);
  }
  return state;
}

export function endpointForMailbox(endpoints, token) {
  for (const endpoint of endpoints.values()) {
    if (endpoint.mailboxToken === token) return endpoint.endpointId;
  }
  return "mock-endpoint";
}

export function operationByPath(artifacts) {
  return new Map(Object.entries(artifacts.coreOperations).map(([key, operation]) => [operation.path, key]));
}

export function assertMockProfileMatchesCoreContract(artifacts) {
  const contract = artifacts.coreContract;
  assert(contract.protocolVersions.responseSchema === STORE_SCHEMA_VERSION,
    "Secure Client Relay Mock response schema drifted from the core contract");
  assert(contract.protocolVersions.deviceTrust === DEVICE_TRUST_PROTOCOL_VERSION,
    "Secure Client Relay Mock device-trust protocol drifted from the core contract");
  assert(contract.protocolVersions.delivery === DELIVERY_PROTOCOL_VERSION,
    "Secure Client Relay Mock delivery protocol drifted from the core contract");
  assert(contract.envelope.schema === RELAY_ENVELOPE_SCHEMA,
    "Secure Client Relay Mock envelope schema drifted from the core contract");
  assert(contract.envelope.limits.encryptedHeaderBytes === ENCRYPTED_HEADER_BYTES &&
    contract.envelope.limits.maxCiphertextBucketBytes === MAX_CIPHERTEXT_BUCKET_BYTES &&
    contract.envelope.limits.largeBucketStepBytes === LARGE_BUCKET_STEP_BYTES,
  "Secure Client Relay Mock envelope limits drifted from the core contract");
  assert(contract.limits.syncPage.minimum === 1 && contract.limits.syncPage.maximum === 100 &&
    contract.limits.leaseMs.minimum === 5_000 && contract.limits.leaseMs.maximum === 600_000,
  "Secure Client Relay Mock lease or page limits drifted from the core contract");
}

export function coreErrorStatus(artifacts, operation, code) {
  const status = artifacts.coreOperations?.[operation]?.errors?.[code]?.status;
  assert(Number.isInteger(status), `Secure Client Relay Mock error ${code} is not in the core contract`);
  return status;
}
