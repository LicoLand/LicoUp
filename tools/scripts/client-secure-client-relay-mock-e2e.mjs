#!/usr/bin/env node
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { sanitizeError } from "./lib/sanitize-error.mjs";
import { optionalReleaseInvocationBinding } from "./lib/release-closure-challenge.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";
import { loadSecureClientContract } from "./lib/secure-client-contract.mjs";
import { createSecureClientMeshE2eeRefReportScope } from "./lib/secure-client-mesh-e2ee-ref-report.mjs";
import {
  opaqueRelayEnvelopeFixture,
  secureClientRelayRequest,
  startSecureClientRelayMock
} from "./lib/secure-client-relay-mock.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const reportRef = "build/reports/secure-client-relay-mock-e2e.json";
const verifier = "tools/scripts/client-secure-client-relay-mock-e2e.mjs";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function run() {
  const plaintextCanary = `client-only-plaintext-${crypto.randomUUID()}`;
  const mock = await startSecureClientRelayMock({
    forbiddenPlaintexts: [plaintextCanary],
    maxMailboxEntries: 2
  });
  try {
    const scope = { tenantId: "tenant-test-fixture", accountId: "account-test-fixture" };
    const endpointId = "mobile:fixture";
    const mailboxToken = crypto.randomBytes(32).toString("base64url");
    const signing = crypto.generateKeyPairSync("ed25519");
    const identity = crypto.generateKeyPairSync("x25519");
    const signingPublicKey = signing.publicKey.export({ format: "jwk" });
    const identityPublicKey = identity.publicKey.export({ format: "jwk" });
    const operations = mock.artifacts.coreOperations;

    const challenge = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.endpointChallenge.path,
      { ...scope, endpointId, signingPublicKey }
    );
    assert(challenge.status === 200 && challenge.body.ok === true, "endpoint challenge failed");
    const signature = crypto.sign(null, Buffer.from(challenge.body.challenge), signing.privateKey)
      .toString("base64url");
    const registration = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.endpointRegister.path,
      {
        ...scope,
        endpointId,
        endpointKind: "mobile",
        identityPublicKey,
        signingPublicKey,
        mailboxToken,
        proof: { challengeId: challenge.body.challengeId, signature }
      }
    );
    assert(registration.status === 200 && registration.body.endpoint.mailboxToken === mailboxToken,
      "endpoint registration failed");

    const envelope = opaqueRelayEnvelopeFixture({ mailboxToken });
    const sent = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeSend.path,
      { ...scope, envelope, transport: "loopback_local" }
    );
    assert(sent.status === 200 && sent.body.queued.envelope.deliveryId === envelope.deliveryId,
      "opaque envelope send failed");

    const replay = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeSend.path,
      { ...scope, envelope, transport: "loopback_local" }
    );
    assert(replay.status === 409 && replay.body.code === "secure_mesh_replay_rejected",
      "duplicate delivery was not rejected");

    const unknownField = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeSend.path,
      {
        ...scope,
        envelope: {
          ...opaqueRelayEnvelopeFixture({ mailboxToken }),
          plaintext: "forbidden-field-fixture"
        }
      }
    );
    assert(unknownField.status === 400 &&
      unknownField.body.code === "secure_mesh_relay_request_schema_invalid",
      "unknown outer envelope field was not rejected");

    const invalidMailboxToken = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeSync.path,
      { ...scope, mailboxToken: "not-a-canonical-mailbox-token" }
    );
    assert(invalidMailboxToken.status === 400 &&
      invalidMailboxToken.body.code === "secure_mesh_relay_request_schema_invalid",
    "invalid mailbox token was not rejected by the sync schema boundary");

    const pemSigningKey = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.endpointChallenge.path,
      { ...scope, endpointId: `${endpointId}:pem-negative`, signingPublicKey: "-----BEGIN PUBLIC KEY-----" }
    );
    assert(pemSigningKey.status === 400 &&
      pemSigningKey.body.code === "secure_mesh_relay_request_schema_invalid",
    "PEM signing key bypassed the exact public-JWK boundary");

    const synced = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeSync.path,
      { ...scope, mailboxToken, afterDeliverySequence: 0, limit: 10, leaseMs: 5000 }
    );
    assert(synced.status === 200 && synced.body.envelopes.length === 1,
      "opaque envelope sync failed");
    const leased = synced.body.envelopes[0];
    assert(JSON.stringify(leased).includes(plaintextCanary) === false,
      "leased envelope exposed client plaintext");
    const activeLeaseSync = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeSync.path,
      { ...scope, mailboxToken, afterDeliverySequence: 0, limit: 10, leaseMs: 5000 }
    );
    assert(activeLeaseSync.status === 200 && activeLeaseSync.body.envelopes.length === 0,
      "active lease was delivered twice before expiry");

    const staleAck = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeAck.path,
      {
        ...scope,
        mailboxToken,
        deliveryId: leased.deliveryId,
        leaseId: `${leased.leaseId}-stale`,
        leaseGeneration: leased.leaseGeneration
      }
    );
    assert(staleAck.status === 409 && staleAck.body.code === "secure_mesh_stale_lease",
      "stale lease was not rejected");

    const missingLeaseFence = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeAck.path,
      {
        ...scope,
        mailboxToken,
        deliveryId: leased.deliveryId
      }
    );
    assert(missingLeaseFence.status === 400 &&
      missingLeaseFence.body.code === "secure_mesh_relay_request_schema_invalid",
    "acknowledgement without the complete lease fence was not rejected");

    const ackBody = {
      ...scope,
      mailboxToken,
      deliveryId: leased.deliveryId,
      leaseId: leased.leaseId,
      leaseGeneration: leased.leaseGeneration
    };
    const acknowledged = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeAck.path,
      ackBody
    );
    assert(acknowledged.status === 200 && acknowledged.body.ack.idempotent === false,
      "leased envelope acknowledgement failed");
    const idempotentAck = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeAck.path,
      ackBody
    );
    assert(idempotentAck.status === 200 && idempotentAck.body.ack.idempotent === true,
      "acknowledgement retry was not idempotent");
    const wrongFenceRetry = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeAck.path,
      { ...ackBody, leaseId: `${ackBody.leaseId}-different` }
    );
    assert(wrongFenceRetry.status === 409 &&
      wrongFenceRetry.body.code === "secure_mesh_stale_lease",
    "idempotent acknowledgement accepted a different lease fence");

    for (let index = 0; index < 2; index += 1) {
      const queued = await secureClientRelayRequest(
        mock.baseUrl,
        mock.auth,
        operations.envelopeSend.path,
        { ...scope, envelope: opaqueRelayEnvelopeFixture({ mailboxToken }) }
      );
      assert(queued.status === 200, "mailbox setup for backpressure failed");
    }
    const backpressure = await secureClientRelayRequest(
      mock.baseUrl,
      mock.auth,
      operations.envelopeSend.path,
      { ...scope, envelope: opaqueRelayEnvelopeFixture({ mailboxToken }) }
    );
    assert(backpressure.status === 429 &&
      backpressure.body.code === "secure_mesh_mailbox_backpressure",
    "mailbox backpressure did not use the core error catalog");

    const snapshot = mock.snapshot();
    const expectedPaths = Object.values(operations).map((operation) => operation.path).sort();
    assert(JSON.stringify(snapshot.observedPaths) === JSON.stringify(expectedPaths),
      "mock did not observe exactly the five core-contract operation paths");
    const canonicalEnvelopeObservation = mock.observations.find((item) =>
      item.operation === "envelopeSend" &&
      JSON.stringify(item.envelopeOuterFields) ===
        JSON.stringify([...mock.artifacts.relayEnvelopeOuterFields].sort()));
    assert(canonicalEnvelopeObservation, "mock did not observe the canonical relay envelope shape");
    const conformanceNegativeCaseIds = new Set(
      mock.artifacts.conformance.fixtureProjection.negativeCases.map((item) => item.id)
    );
    assert(JSON.stringify([...conformanceNegativeCaseIds].sort()) === JSON.stringify([
      "mailboxToken",
      "missingLeaseFence",
      "pemSigningKey",
      "replay",
      "staleLease",
      "unknownEnvelopeField"
    ]), "mock conformance negative-case corpus is not exact");

    return {
      ok: true,
      schemaVersion: "licomesh.secure-client-relay.mock-e2e-report.v1",
      protocolVersion: mock.artifacts.protocolVersion,
      coreContractDigest: mock.artifacts.coreContractDigest,
      coreConformanceDigest: mock.artifacts.coreConformanceDigest,
      operationCount: Object.keys(operations).length,
      outerEnvelopeFieldCount: mock.artifacts.relayEnvelopeOuterFields.length,
      exactFiveOperationsObserved: snapshot.observedPaths.length === 5,
      exactSixOuterFieldsObserved: true,
      exactConformanceCorpusVerified: true,
      replayRejected: true,
      staleLeaseRejected: true,
      activeLeaseSuppressed: true,
      ackIdempotencyVerified: true,
      duplicateAckFenceBound: true,
      mailboxBackpressureCatalogBound: true,
      plaintextAbsentFromServerVisibleWire: true,
      wireBytesMeasured: snapshot.wireBytes > 0,
      acknowledgedEnvelopeCount: snapshot.acknowledgedEnvelopeCount
    };
  } finally {
    await mock.stop();
  }
}

try {
  const mock = await run();
  const checkedAt = new Date().toISOString();
  const contract = await loadSecureClientContract();
  const {
    SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
    SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS,
    SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH
  } = contract;
  const blocker = SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.find((item) =>
    item === "opaque relay protocol mock"
  );
  if (!blocker) {
    throw new Error("Client-pinned Secure Client Mesh contract does not define opaque relay protocol mock blocker");
  }
  const scopeEvidence = await createSecureClientMeshE2eeRefReportScope({
    contract,
    reportRef,
    blocker,
    checkedAt
  });
  const report = {
    schemaVersion: "licomesh.secure-client-relay.client-acceptance-report.v1",
    evidenceRefSchemaVersion: SECURE_CLIENT_MESH_E2EE_EVIDENCE_REF_REPORT_SCHEMA_VERSION,
    verifier,
    generatedBy: verifier,
    generatedAt: checkedAt,
    checkedAt,
    ...optionalReleaseInvocationBinding(),
    sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
    blocker,
    diagnosticStatus: mock.ok === true ? "passed" : "incomplete",
    productionReady: mock.ok === true,
    releaseReady: mock.ok === true,
    evidenceKind: "redacted-client-owned-opaque-relay-protocol-mock-evidence",
    ok: mock.ok === true,
    redacted: true,
    rawPrivateMaterialIncluded: false,
    rawPlaintextIncluded: false,
    rawPublicWireBytesIncluded: false,
    reportLeakScan: true,
    ...scopeEvidence,
    contractBinding: {
      sourceOfTruth: SECURE_CLIENT_MESH_PRODUCTION_SOURCE_OF_TRUTH,
      canonicalBlocker: blocker,
      canonicalBlockerCount: SECURE_CLIENT_MESH_PRODUCTION_BLOCKERS.length
    },
    mock,
    summary: {
      ok: mock.ok === true,
      remainingGates: [],
      protocolVersion: mock.protocolVersion,
      coreContractDigest: mock.coreContractDigest,
      coreConformanceDigest: mock.coreConformanceDigest,
      exactFiveOperationsObserved: mock.exactFiveOperationsObserved,
      exactSixOuterFieldsObserved: mock.exactSixOuterFieldsObserved,
      exactConformanceCorpusVerified: mock.exactConformanceCorpusVerified,
      replayRejected: mock.replayRejected,
      staleLeaseRejected: mock.staleLeaseRejected,
      activeLeaseSuppressed: mock.activeLeaseSuppressed,
      ackIdempotencyVerified: mock.ackIdempotencyVerified,
      duplicateAckFenceBound: mock.duplicateAckFenceBound,
      mailboxBackpressureCatalogBound: mock.mailboxBackpressureCatalogBound,
      plaintextAbsentFromServerVisibleWire: mock.plaintextAbsentFromServerVisibleWire,
      wireBytesMeasured: mock.wireBytesMeasured
    }
  };
  atomicWriteReportJson(repoRoot, reportRef, report);
  console.log(JSON.stringify(mock, null, 2));
} catch (error) {
  console.error(JSON.stringify({ ok: false, error: sanitizeError(error) }, null, 2));
  process.exitCode = 1;
}
