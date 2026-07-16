import crypto from "node:crypto";
import http from "node:http";

import { loadSecureClientRelayArtifacts } from "../secure-client-relay-artifacts.mjs";

import {
  DELIVERY_PROTOCOL_VERSION,
  DEVICE_TRUST_PROTOCOL_VERSION,
  ENCRYPTED_HEADER_BYTES,
  JSON_SAFE_INTEGER_MAX,
  LARGE_BUCKET_STEP_BYTES,
  MAX_CIPHERTEXT_BUCKET_BYTES,
  MAX_REQUEST_BYTES,
  RELAY_ENVELOPE_SCHEMA,
  SESSION_COOKIE_NAME,
  STORE_SCHEMA_VERSION,
} from "./constants.mjs";

import {
  assert,
  assertMockProfileMatchesCoreContract,
  authIsValid,
  canonicalBase64url,
  coreErrorStatus,
  endpointForMailbox,
  errorBody,
  exactKeys,
  exactKeysWithOptional,
  mailboxState,
  operationByPath,
  publicMailbox,
  readJson,
  scopeKey,
  sendJson,
  sha256Hex,
  timestamp,
  validateEnvelope,
  validatePublicJwk,
  validateScope,
} from "./helpers.mjs";

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
