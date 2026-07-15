#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  SECURE_CLIENT_RELAY_CORE_CONFORMANCE_PATH,
  SECURE_CLIENT_RELAY_CORE_CONTRACT_PATH,
  loadDigestBoundJsonInput,
  loadSecureClientRelayArtifacts,
  validateSecureClientRelayArtifacts
} from "./lib/secure-client-relay-artifacts.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const artifacts = await loadSecureClientRelayArtifacts();

assert.equal(Object.keys(artifacts.coreOperations).length, 5);
assert.ok(Object.values(artifacts.coreOperations).every((operation) => operation.method === "POST"));
assert.equal(artifacts.relayEnvelopeOuterFields.length, 6);
assert.equal(new Set(artifacts.relayEnvelopeOuterFields).size, 6);

const [contract, conformance] = await Promise.all([
  fs.readFile(path.join(repoRoot, SECURE_CLIENT_RELAY_CORE_CONTRACT_PATH), "utf8").then(JSON.parse),
  fs.readFile(path.join(repoRoot, SECURE_CLIENT_RELAY_CORE_CONFORMANCE_PATH), "utf8").then(JSON.parse)
]);

const tamperedContract = structuredClone(contract);
tamperedContract.contract.coreOperations.endpointChallenge.method = "GET";
assert.throws(
  () => validateSecureClientRelayArtifacts(tamperedContract, conformance),
  /digest|POST/u
);

const tamperedConformance = structuredClone(conformance);
tamperedConformance.conformance.scenarios[0].steps[0].expected.status = 201;
assert.throws(
  () => validateSecureClientRelayArtifacts(contract, tamperedConformance),
  /digest/u
);
await assert.rejects(
  () => loadDigestBoundJsonInput(),
  /path must be provided explicitly/u
);
await assert.rejects(
  () => loadDigestBoundJsonInput({ filePath: "ignored", expectedDigest: "not-a-digest" }),
  /digest must be an explicit sha256 value/u
);

console.log(JSON.stringify({
  ok: true,
  coreOperationCount: Object.keys(artifacts.coreOperations).length,
  allCoreOperationsUsePost: true,
  outerEnvelopeFieldCount: artifacts.relayEnvelopeOuterFields.length,
  contractDigestBound: true,
  conformanceDigestBound: true,
  explicitExternalInputDigestRequired: true
}, null, 2));
