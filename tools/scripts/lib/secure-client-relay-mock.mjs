import crypto from "node:crypto";
import http from "node:http";

import { loadSecureClientRelayArtifacts } from "./secure-client-relay-artifacts.mjs";

const STORE_SCHEMA_VERSION = "licolite.secure-mesh.store-schema.v2";
const DEVICE_TRUST_PROTOCOL_VERSION = "licolite.secure-mesh.device-trust.v2";
const DELIVERY_PROTOCOL_VERSION = "licolite.secure-mesh.delivery.v1";
const RELAY_ENVELOPE_SCHEMA = "licolite.secure-mesh.relay-envelope.v2";
const MAX_REQUEST_BYTES = 24 * 1024 * 1024;
const ENCRYPTED_HEADER_BYTES = 4096;
const MAX_CIPHERTEXT_BUCKET_BYTES = 16 * 1024 * 1024;
const LARGE_BUCKET_STEP_BYTES = 64 * 1024;
const JSON_SAFE_INTEGER_MAX = Number.MAX_SAFE_INTEGER;
const SESSION_COOKIE_NAME = "lico_console_session";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function exactKeys(value, expected, label) {
  assert(value && typeof value === "object" && !Array.isArray(value), `${label} must be an object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  assert(JSON.stringify(actual) === JSON.stringify(wanted), `${label} fields are not exact`);
}

function exactKeysWithOptional(value, required, optional, label) {
  assert(value && typeof value === "object" && !Array.isArray(value), `${label} must be an object`);
  const keys = Object.keys(value);
  assert(required.every((key) => keys.includes(key)), `${label} is missing a required field`);
  assert(keys.every((key) => required.includes(key) || optional.includes(key)), `${label} has an unknown field`);
}

function canonicalBase64url(value, encodedLength, label) {
  assert(typeof value === "string" && value.length === encodedLength, `${label} length is invalid`);
  assert(/^[A-Za-z0-9_-]+$/u.test(value), `${label} is not canonical base64url`);
  const decoded = Buffer.from(value, "base64url");
  assert(decoded.toString("base64url") === value, `${label} is not canonical base64url`);
  return decoded;
}

function validateScope(body) {
  for (const key of ["tenantId", "accountId"]) {
    assert(typeof body[key] === "string" && body[key].length > 0 && body[key].length <= 255,
      `${key} is invalid`);
  }
  if (body.workspaceId !== undefined) {
    assert(typeof body.workspaceId === "string" && body.workspaceId.length <= 255,
      "workspaceId is invalid");
  }
}

function scopeKey(body) {
  return `${body.tenantId}\u0000${body.accountId}\u0000${body.workspaceId || ""}`;
}

function validatePublicJwk(value, curve) {
  exactKeys(value, ["kty", "crv", "x"], `${curve} public JWK`);
  assert(value.kty === "OKP" && value.crv === curve, `${curve} public JWK profile is invalid`);
  canonicalBase64url(value.x, 43, `${curve} public JWK x`);
}

function validateCiphertextBucket(bucket) {
  assert(Number.isSafeInteger(bucket) && bucket >= 256 && bucket <= MAX_CIPHERTEXT_BUCKET_BYTES,
    "ciphertext bucket is outside bounds");
  if (bucket <= LARGE_BUCKET_STEP_BYTES) {
    assert((bucket & (bucket - 1)) === 0, "ciphertext bucket is not a supported power-of-two bucket");
  } else {
    assert(bucket % LARGE_BUCKET_STEP_BYTES === 0, "ciphertext bucket is not aligned");
  }
}

function validateEnvelope(envelope, outerFields) {
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

function timestamp() {
  return new Date().toISOString();
}

function sha256Hex(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function publicMailbox(scope, mailboxToken, state, endpointId = "mock-endpoint") {
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

function errorBody(protocolVersion, code, message) {
  return {
    ok: false,
    schemaVersion: STORE_SCHEMA_VERSION,
    protocolVersion,
    code,
    error: message
  };
}

function sendJson(response, status, body) {
  const bytes = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": String(bytes.length),
    "cache-control": "no-store"
  });
  response.end(bytes);
}

async function readJson(request) {
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

function authIsValid(request, options) {
  if (!options.requireAuth) return true;
  const cookies = String(request.headers.cookie || "").split(";").map((value) => value.trim());
  return cookies.includes(`${SESSION_COOKIE_NAME}=${options.sessionToken}`) &&
    request.headers["x-lico-csrf"] === options.csrfToken &&
    request.headers["x-lico-safety-confirm"] === "true";
}

function mailboxState(mailboxes, token) {
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

function endpointForMailbox(endpoints, token) {
  for (const endpoint of endpoints.values()) {
    if (endpoint.mailboxToken === token) return endpoint.endpointId;
  }
  return "mock-endpoint";
}

function operationByPath(artifacts) {
  return new Map(Object.entries(artifacts.coreOperations).map(([key, operation]) => [operation.path, key]));
}

function assertMockProfileMatchesCoreContract(artifacts) {
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

function coreErrorStatus(artifacts, operation, code) {
  const status = artifacts.coreOperations?.[operation]?.errors?.[code]?.status;
  assert(Number.isInteger(status), `Secure Client Relay Mock error ${code} is not in the core contract`);
  return status;
}

export async function startSecureClientRelayMock(input = {}) {
  const artifacts = await loadSecureClientRelayArtifacts();
  assertMockProfileMatchesCoreContract(artifacts);
  const options = {
    requireAuth: input.requireAuth !== false,
    sessionToken: String(input.sessionToken || "test-session"),
    csrfToken: String(input.csrfToken || "test-csrf"),
    maxMailboxEntries: Number(input.maxMailboxEntries || 1000),
    maxMailboxBytes: Number(input.maxMailboxBytes || 64 * 1024 * 1024),
    forbiddenPlaintexts: Array.isArray(input.forbiddenPlaintexts)
      ? input.forbiddenPlaintexts.map(String).filter(Boolean)
      : []
  };
  const paths = operationByPath(artifacts);
  const challenges = new Map();
  const endpoints = new Map();
  const mailboxes = new Map();
  const deliveryIds = new Set();
  const observations = [];

  const server = http.createServer(async (request, response) => {
    const operation = paths.get(new URL(request.url, "http://loopback.invalid").pathname);
    if (request.method !== "POST" || !operation) {
      sendJson(response, 404, errorBody(artifacts.protocolVersion, "secure_mesh_route_not_found", "route not found"));
      return;
    }
    if (!authIsValid(request, options)) {
      sendJson(response, 401, errorBody(artifacts.protocolVersion, "secure_mesh_unauthorized", "authentication failed"));
      return;
    }
    try {
      const { bytes, value: body } = await readJson(request);
      for (const forbidden of options.forbiddenPlaintexts) {
        assert(!bytes.includes(Buffer.from(forbidden)), "server-visible request contained forbidden plaintext");
      }
      const observation = {
        operation,
        method: request.method,
        path: paths.get(request.url) ? request.url : new URL(request.url, "http://loopback.invalid").pathname,
        requestTopLevelFields: Object.keys(body).sort(),
        envelopeOuterFields: body?.envelope ? Object.keys(body.envelope).sort() : [],
        wireBytes: bytes.length
      };
      observations.push(observation);

      if (operation === "endpointChallenge") {
        exactKeysWithOptional(body,
          ["tenantId", "accountId", "endpointId", "signingPublicKey"], ["workspaceId"], operation);
        validateScope(body);
        validatePublicJwk(body.signingPublicKey, "Ed25519");
        assert(typeof body.endpointId === "string" && body.endpointId.length > 0, "endpoint id is invalid");
        const challengeId = crypto.randomUUID();
        const issuedAt = timestamp();
        const challenge = `${artifacts.protocolVersion}:${challengeId}:${body.tenantId}:${body.accountId}:${body.endpointId}:${issuedAt}`;
        challenges.set(challengeId, { body: structuredClone(body), challenge });
        sendJson(response, 200, {
          ok: true,
          schemaVersion: STORE_SCHEMA_VERSION,
          protocolVersion: DEVICE_TRUST_PROTOCOL_VERSION,
          challengeId,
          challenge,
          challengeEncoding: "utf-8",
          signatureAlgorithm: "Ed25519",
          expiresAt: new Date(Date.now() + 5 * 60 * 1000).toISOString()
        });
        return;
      }

      if (operation === "endpointRegister") {
        exactKeysWithOptional(body, [
          "tenantId", "accountId", "endpointId", "endpointKind", "identityPublicKey",
          "signingPublicKey", "mailboxToken", "proof"
        ], ["workspaceId", "rotationEpoch"], operation);
        validateScope(body);
        validatePublicJwk(body.identityPublicKey, "X25519");
        validatePublicJwk(body.signingPublicKey, "Ed25519");
        canonicalBase64url(body.mailboxToken, 43, "mailbox token");
        exactKeys(body.proof, ["challengeId", "signature"], "registration proof");
        const issued = challenges.get(body.proof.challengeId);
        assert(issued && issued.body.endpointId === body.endpointId && scopeKey(issued.body) === scopeKey(body),
          "registration challenge binding is invalid");
        const signature = canonicalBase64url(body.proof.signature, 86, "challenge signature");
        const verified = crypto.verify(null, Buffer.from(issued.challenge), {
          key: body.signingPublicKey,
          format: "jwk"
        }, signature);
        assert(verified, "registration challenge signature is invalid");
        challenges.delete(body.proof.challengeId);
        const now = timestamp();
        const endpoint = {
          tenantId: body.tenantId,
          accountId: body.accountId,
          workspaceId: body.workspaceId || "",
          endpointId: body.endpointId,
          endpointKind: body.endpointKind,
          mailboxToken: body.mailboxToken,
          identityPublicKey: body.identityPublicKey,
          signingPublicKey: body.signingPublicKey,
          fingerprint: sha256Hex(JSON.stringify(body.signingPublicKey)),
          rotationEpoch: body.rotationEpoch || 0,
          createdAt: now,
          updatedAt: now,
          revokedAt: ""
        };
        endpoints.set(`${scopeKey(body)}\u0000${body.endpointId}`, endpoint);
        mailboxState(mailboxes, body.mailboxToken);
        sendJson(response, 200, {
          ok: true,
          schemaVersion: STORE_SCHEMA_VERSION,
          protocolVersion: DEVICE_TRUST_PROTOCOL_VERSION,
          endpoint
        });
        return;
      }

      if (operation === "envelopeSend") {
        exactKeysWithOptional(body, ["tenantId", "accountId", "envelope"],
          ["workspaceId", "transport", "opaqueSequenceLabel"], operation);
        validateScope(body);
        validateEnvelope(body.envelope, artifacts.relayEnvelopeOuterFields);
        assert(!deliveryIds.has(body.envelope.deliveryId), "duplicate delivery id");
        const state = mailboxState(mailboxes, body.envelope.mailboxToken);
        const wireBytes = ENCRYPTED_HEADER_BYTES + body.envelope.ciphertextBucket;
        const liveEntries = state.queue.filter((entry) => !entry.acked);
        const queueBytes = liveEntries.reduce((total, entry) => total + entry.wireBytes, 0);
        if (liveEntries.length >= options.maxMailboxEntries || queueBytes + wireBytes > options.maxMailboxBytes) {
          const code = "secure_mesh_mailbox_backpressure";
          sendJson(response, coreErrorStatus(artifacts, operation, code),
            errorBody(artifacts.protocolVersion, code, "mailbox backpressure is active"));
          return;
        }
        deliveryIds.add(body.envelope.deliveryId);
        state.sequence += 1;
        state.updatedAt = timestamp();
        const entry = {
          envelope: structuredClone(body.envelope),
          deliverySequence: state.sequence,
          queuedAt: state.updatedAt,
          transport: body.transport || "cloud_relay",
          opaqueSequenceLabelHash: body.opaqueSequenceLabel ? sha256Hex(body.opaqueSequenceLabel) : "",
          opaqueSequenceLabelPresent: body.opaqueSequenceLabel !== undefined,
          wireBytes,
          deliveryAttempts: 0,
          leaseGeneration: 0,
          leaseId: "",
          leaseExpiresAtMs: 0,
          acked: false
        };
        state.queue.push(entry);
        sendJson(response, 200, {
          ok: true,
          schemaVersion: STORE_SCHEMA_VERSION,
          protocolVersion: DELIVERY_PROTOCOL_VERSION,
          queued: {
            deliverySequence: entry.deliverySequence,
            queuedAt: entry.queuedAt,
            transport: entry.transport,
            envelope: {
              schema: entry.envelope.schema,
              deliveryId: entry.envelope.deliveryId,
              mailboxToken: entry.envelope.mailboxToken,
              ciphertextBucket: entry.envelope.ciphertextBucket
            },
            opaqueSequenceLabelHash: entry.opaqueSequenceLabelHash,
            opaqueSequenceLabelPresent: entry.opaqueSequenceLabelPresent,
            mailbox: publicMailbox(body, entry.envelope.mailboxToken, state,
              endpointForMailbox(endpoints, entry.envelope.mailboxToken)),
            metadataOnly: true
          },
          persisted: true,
          queueMode: "offline_queue"
        });
        return;
      }

      if (operation === "envelopeSync") {
        exactKeysWithOptional(body, ["tenantId", "accountId", "mailboxToken"],
          ["workspaceId", "afterDeliverySequence", "limit", "leaseMs"], operation);
        validateScope(body);
        canonicalBase64url(body.mailboxToken, 43, "mailbox token");
        const after = body.afterDeliverySequence || 0;
        const limit = body.limit || 100;
        const leaseMs = body.leaseMs || 30_000;
        assert(Number.isSafeInteger(after) && after >= 0, "sync cursor is invalid");
        assert(Number.isSafeInteger(limit) && limit >= 1 && limit <= 100, "sync limit is invalid");
        assert(Number.isSafeInteger(leaseMs) && leaseMs >= 5000 && leaseMs <= 600000,
          "lease duration is invalid");
        const state = mailboxState(mailboxes, body.mailboxToken);
        const now = Date.now();
        const candidates = state.queue.filter((entry) =>
          !entry.acked && entry.deliverySequence > after && entry.leaseExpiresAtMs <= now);
        const selected = candidates.slice(0, limit);
        const leasedAt = timestamp();
        const leaseExpiresAt = new Date(Date.now() + leaseMs).toISOString();
        const envelopes = selected.map((entry) => {
          entry.deliveryAttempts += 1;
          entry.leaseGeneration += 1;
          entry.leaseId = `lease-${entry.deliverySequence}-${entry.leaseGeneration}`;
          entry.leaseExpiresAtMs = now + leaseMs;
          return {
            ...structuredClone(entry.envelope),
            deliverySequence: entry.deliverySequence,
            queuedAt: entry.queuedAt,
            transport: entry.transport,
            deliveryAttempts: entry.deliveryAttempts,
            leaseId: entry.leaseId,
            leaseGeneration: entry.leaseGeneration,
            leasedAt,
            leaseExpiresAt,
            opaqueSequenceLabelHash: entry.opaqueSequenceLabelHash,
            opaqueSequenceLabelPresent: entry.opaqueSequenceLabelPresent
          };
        });
        const next = envelopes.at(-1)?.deliverySequence || after;
        sendJson(response, 200, {
          ok: true,
          schemaVersion: STORE_SCHEMA_VERSION,
          protocolVersion: DELIVERY_PROTOCOL_VERSION,
          queueMode: "offline_queue",
          mailbox: publicMailbox(body, body.mailboxToken, state,
            endpointForMailbox(endpoints, body.mailboxToken)),
          cursor: {
            afterDeliverySequence: after,
            nextDeliverySequence: next,
            highWatermark: state.sequence,
            hasMore: candidates.length > selected.length
          },
          gapRanges: [],
          envelopes
        });
        return;
      }

      exactKeysWithOptional(body,
        ["tenantId", "accountId", "mailboxToken", "deliveryId", "leaseId", "leaseGeneration"],
        ["workspaceId"], operation);
      validateScope(body);
      canonicalBase64url(body.mailboxToken, 43, "mailbox token");
      canonicalBase64url(body.deliveryId, 32, "delivery id");
      assert(typeof body.leaseId === "string" && body.leaseId.length > 0, "lease id is invalid");
      assert(Number.isSafeInteger(body.leaseGeneration) && body.leaseGeneration >= 1 &&
        body.leaseGeneration <= JSON_SAFE_INTEGER_MAX, "lease generation is invalid");
      const state = mailboxState(mailboxes, body.mailboxToken);
      const previousReceipt = state.receipts.get(body.deliveryId);
      if (previousReceipt) {
        if (previousReceipt.leaseId !== body.leaseId ||
          previousReceipt.leaseGeneration !== body.leaseGeneration) {
          const code = "secure_mesh_stale_lease";
          sendJson(response, coreErrorStatus(artifacts, operation, code),
            errorBody(artifacts.protocolVersion, code, "lease fence is stale"));
          return;
        }
        sendJson(response, 200, {
          ok: true,
          schemaVersion: STORE_SCHEMA_VERSION,
          protocolVersion: DELIVERY_PROTOCOL_VERSION,
          ack: { ...previousReceipt.ack, idempotent: true },
          receipt: previousReceipt.receipt,
          mailbox: publicMailbox(body, body.mailboxToken, state,
            endpointForMailbox(endpoints, body.mailboxToken))
        });
        return;
      }
      const entry = state.queue.find((candidate) => candidate.envelope.deliveryId === body.deliveryId);
      if (!entry || entry.leaseId !== body.leaseId || entry.leaseGeneration !== body.leaseGeneration ||
        entry.leaseExpiresAtMs <= Date.now()) {
        const code = "secure_mesh_stale_lease";
        sendJson(response, coreErrorStatus(artifacts, operation, code),
          errorBody(artifacts.protocolVersion, code, "lease fence is stale"));
        return;
      }
      entry.acked = true;
      state.receiptCount += 1;
      state.ackedCount += 1;
      state.updatedAt = timestamp();
      const ackedAt = state.updatedAt;
      const receipt = {
        leaseId: body.leaseId,
        leaseGeneration: body.leaseGeneration,
        ack: { deliveryId: body.deliveryId, idempotent: false, ackedAt, purged: true },
        receipt: {
          deliveryId: body.deliveryId,
          deliverySequence: entry.deliverySequence,
          receiptType: "ack",
          acknowledgedAt: ackedAt,
          purged: true
        }
      };
      state.receipts.set(body.deliveryId, receipt);
      sendJson(response, 200, {
        ok: true,
        schemaVersion: STORE_SCHEMA_VERSION,
        protocolVersion: DELIVERY_PROTOCOL_VERSION,
        ack: receipt.ack,
        receipt: receipt.receipt,
        mailbox: publicMailbox(body, body.mailboxToken, state,
          endpointForMailbox(endpoints, body.mailboxToken))
      });
    } catch (error) {
      const duplicate = String(error?.message || "").includes("duplicate delivery id");
      sendJson(response, duplicate ? 409 : 400, errorBody(
        artifacts.protocolVersion,
        duplicate ? "secure_mesh_replay_rejected" : "secure_mesh_relay_request_schema_invalid",
        "request rejected"
      ));
    }
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert(address && typeof address === "object", "Secure Client Relay mock address is unavailable");

  return Object.freeze({
    baseUrl: `http://127.0.0.1:${address.port}`,
    auth: Object.freeze({ sessionToken: options.sessionToken, csrfToken: options.csrfToken }),
    artifacts,
    observations,
    snapshot() {
      return Object.freeze({
        operationCounts: Object.freeze(Object.fromEntries(
          Object.keys(artifacts.coreOperations).map((key) => [key,
            observations.filter((item) => item.operation === key).length])
        )),
        observedPaths: Object.freeze([...new Set(observations.map((item) => item.path))].sort()),
        wireBytes: observations.reduce((total, item) => total + item.wireBytes, 0),
        endpointCount: endpoints.size,
        mailboxCount: mailboxes.size,
        queuedEnvelopeCount: [...mailboxes.values()].reduce((total, state) =>
          total + state.queue.filter((entry) => !entry.acked).length, 0),
        acknowledgedEnvelopeCount: [...mailboxes.values()].reduce((total, state) =>
          total + state.ackedCount, 0)
      });
    },
    async stop() {
      await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    }
  });
}

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
