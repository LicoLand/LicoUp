import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

export const SECURE_CLIENT_RELAY_CORE_CONTRACT_PATH =
  "crates/lico-client-native/resources/secure-client-relay-core-contract.json";
export const SECURE_CLIENT_RELAY_CORE_CONFORMANCE_PATH =
  "crates/lico-client-native/resources/secure-client-relay-core-conformance.json";
export const SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST =
  "sha256:133d084f0cfeb464a03f217ae2d24ff23758a7c10537027c80932bd930d2dab3";
export const SECURE_CLIENT_RELAY_CORE_CONFORMANCE_DIGEST =
  "sha256:d942d81fc07023c9c83903efed9d82f2f5b21fad9ad17f31b90fd77896019764";

const CORE_CONTRACT_SCHEMA_VERSION =
  "licolite.secure-client-relay.core-contract-artifact.v1";
const CORE_CONFORMANCE_SCHEMA_VERSION =
  "licolite.secure-client-relay.core-conformance-artifact.v1";
const CANONICALIZATION = "json-recursive-lexicographic-keys.v1";
const DIGEST_PATTERN = /^sha256:[a-f0-9]{64}$/u;
const MAX_EXTERNAL_JSON_BYTES = 4 * 1024 * 1024;
const MAX_FREEZE_NODES = 100_000;
const CORE_OPERATION_KEYS = Object.freeze([
  "endpointChallenge",
  "endpointRegister",
  "envelopeAck",
  "envelopeSend",
  "envelopeSync"
]);
const RELAY_ENVELOPE_OUTER_FIELDS = Object.freeze([
  "schema",
  "deliveryId",
  "mailboxToken",
  "encryptedHeader",
  "ciphertextBucket",
  "ciphertext"
]);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function exactKeys(value, expected, label) {
  assert(isRecord(value), `${label} must be an object`);
  const actual = Object.keys(value).sort();
  const canonicalExpected = [...expected].sort();
  assert(JSON.stringify(actual) === JSON.stringify(canonicalExpected), `${label} fields are not exact`);
}

function canonicalJsonValue(value) {
  if (Array.isArray(value)) return value.map(canonicalJsonValue);
  if (isRecord(value)) {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonicalJsonValue(value[key])])
    );
  }
  return value;
}

function digestCanonicalJson(value) {
  return `sha256:${createHash("sha256")
    .update(JSON.stringify(canonicalJsonValue(value)))
    .digest("hex")}`;
}

function digestArtifactWithoutDeclaredDigest(value) {
  const input = structuredClone(value);
  delete input.canonicalDigest;
  return digestCanonicalJson(input);
}

function deepFreeze(value) {
  const pending = [value];
  let visited = 0;
  while (pending.length > 0) {
    const current = pending.pop();
    if (!current || typeof current !== "object" || Object.isFrozen(current)) continue;
    visited += 1;
    assert(visited <= MAX_FREEZE_NODES, "Secure Client Relay artifact object graph is too large");
    for (const nested of Object.values(current)) {
      if (nested && typeof nested === "object" && !Object.isFrozen(nested)) pending.push(nested);
    }
    Object.freeze(current);
  }
  return value;
}

function validateClosedSchema(schema, label) {
  assert(isRecord(schema) && schema.type === "object" && schema.additionalProperties === false,
    `${label} must be a closed object schema`);
  assert(isRecord(schema.properties) && Array.isArray(schema.required),
    `${label} fields are incomplete`);
}

function validateCoreOperation(key, operation, paths) {
  assert(isRecord(operation), `Secure Client Relay operation ${key} must be an object`);
  assert(operation.method === "POST", `Secure Client Relay operation ${key} must use POST`);
  assert(/^\/api\/secure-mesh\/v1\/[a-z-]+\/[a-z-]+$/u.test(operation.path),
    `Secure Client Relay operation ${key} path is invalid`);
  assert(!paths.has(operation.path), `Secure Client Relay operation path is duplicated: ${key}`);
  paths.add(operation.path);
  validateClosedSchema(operation.requestSchema, `Secure Client Relay operation ${key} request schema`);
  assert(isRecord(operation.success) && operation.success.status === 200,
    `Secure Client Relay operation ${key} success contract is invalid`);
  validateClosedSchema(
    operation.success.responseSchema,
    `Secure Client Relay operation ${key} success schema`
  );
  assert(isRecord(operation.errors) && Object.keys(operation.errors).length > 0,
    `Secure Client Relay operation ${key} errors are missing`);
  for (const [code, error] of Object.entries(operation.errors)) {
    assert(/^secure_mesh_[a-z0-9_]+$/u.test(code),
      `Secure Client Relay operation ${key} error code is invalid`);
    assert(Number.isInteger(error?.status) && error.status >= 400 && error.status <= 599,
      `Secure Client Relay operation ${key} error status is invalid`);
    exactKeys(
      error?.retry,
      ["retryAfterHeader", "retryable", "strategy"],
      `Secure Client Relay operation ${key} retry contract`
    );
    validateClosedSchema(
      error.responseSchema,
      `Secure Client Relay operation ${key} error schema`
    );
  }
}

function validateCoreContract(artifact) {
  exactKeys(artifact, [
    "canonicalDigest",
    "canonicalSource",
    "canonicalization",
    "contract",
    "protocolVersion",
    "schemaVersion"
  ], "Secure Client Relay core contract artifact");
  assert(artifact.schemaVersion === CORE_CONTRACT_SCHEMA_VERSION,
    "Secure Client Relay core contract schema mismatch");
  assert(artifact.canonicalization === CANONICALIZATION,
    "Secure Client Relay core contract canonicalization mismatch");
  assert(artifact.canonicalDigest === SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST,
    "Secure Client Relay core contract digest is not pinned");
  assert(digestArtifactWithoutDeclaredDigest(artifact) === artifact.canonicalDigest,
    "Secure Client Relay core contract content digest mismatch");

  const contract = artifact.contract;
  exactKeys(contract, [
    "authenticationPrerequisite",
    "coreOperations",
    "endpointKinds",
    "endpointProofProfile",
    "envelope",
    "httpHeaders",
    "limits",
    "mailboxTokenLifecycle",
    "protocolVersions",
    "transports"
  ], "Secure Client Relay core contract");
  exactKeys(contract.coreOperations, CORE_OPERATION_KEYS, "Secure Client Relay core operations");
  const paths = new Set();
  for (const key of CORE_OPERATION_KEYS) validateCoreOperation(key, contract.coreOperations[key], paths);

  const fields = contract.envelope?.fields;
  assert(JSON.stringify(fields) === JSON.stringify(RELAY_ENVELOPE_OUTER_FIELDS),
    "Secure Client Relay outer envelope fields are not exact");
  validateClosedSchema(contract.envelope?.jsonSchema, "Secure Client Relay envelope schema");
  exactKeys(contract.limits, [
    "endpointChallengeTtlMs",
    "leaseMs",
    "opaqueSequenceLabelBytes",
    "syncPage"
  ], "Secure Client Relay core limits");
  assert(contract.limits.syncPage.minimum === 1 && contract.limits.syncPage.maximum === 100,
    "Secure Client Relay sync-page limits are invalid");
  assert(contract.limits.leaseMs.minimum === 5_000 && contract.limits.leaseMs.maximum === 600_000,
    "Secure Client Relay lease limits are invalid");
  exactKeys(contract.protocolVersions, [
    "delivery",
    "deviceTrust",
    "endpointRegister",
    "relay",
    "responseSchema"
  ], "Secure Client Relay core protocol versions");
}

function validateCoreConformance(contractArtifact, conformanceArtifact) {
  exactKeys(conformanceArtifact, [
    "canonicalDigest",
    "canonicalSource",
    "canonicalization",
    "conformance",
    "contractDigest",
    "protocolVersion",
    "schemaVersion"
  ], "Secure Client Relay core conformance artifact");
  assert(conformanceArtifact.schemaVersion === CORE_CONFORMANCE_SCHEMA_VERSION,
    "Secure Client Relay core conformance schema mismatch");
  assert(conformanceArtifact.canonicalization === CANONICALIZATION,
    "Secure Client Relay core conformance canonicalization mismatch");
  assert(conformanceArtifact.protocolVersion === contractArtifact.protocolVersion,
    "Secure Client Relay core conformance protocol mismatch");
  assert(conformanceArtifact.contractDigest === contractArtifact.canonicalDigest,
    "Secure Client Relay core conformance is not bound to the core contract");
  assert(conformanceArtifact.canonicalDigest === SECURE_CLIENT_RELAY_CORE_CONFORMANCE_DIGEST,
    "Secure Client Relay core conformance digest is not pinned");
  assert(digestArtifactWithoutDeclaredDigest(conformanceArtifact) === conformanceArtifact.canonicalDigest,
    "Secure Client Relay core conformance content digest mismatch");
  exactKeys(conformanceArtifact.conformance, ["fixtureProjection", "scenarios"],
    "Secure Client Relay core conformance");

  const scenarios = conformanceArtifact.conformance.scenarios;
  assert(Array.isArray(scenarios) && scenarios.length > 0,
    "Secure Client Relay core conformance scenarios are missing");
  const scenarioOperationKeys = [...new Set(scenarios.flatMap((scenario) =>
    (Array.isArray(scenario?.steps) ? scenario.steps : []).map((step) => String(step?.operation || ""))
  ).filter(Boolean))].sort();
  assert(JSON.stringify(scenarioOperationKeys) === JSON.stringify([...CORE_OPERATION_KEYS].sort()),
    "Secure Client Relay core conformance operations are not exact");
  const corpusOperationKeys = conformanceArtifact.conformance.fixtureProjection?.validOperationKeys;
  assert(JSON.stringify(corpusOperationKeys) === JSON.stringify([...CORE_OPERATION_KEYS].sort()),
    "Secure Client Relay core Mock corpus operations are not exact");
}

export function validateSecureClientRelayArtifacts(contractArtifact, conformanceArtifact) {
  validateCoreContract(contractArtifact);
  validateCoreConformance(contractArtifact, conformanceArtifact);
  return deepFreeze({
    schemaVersion: contractArtifact.schemaVersion,
    protocolVersion: contractArtifact.protocolVersion,
    canonicalization: contractArtifact.canonicalization,
    coreContractDigest: contractArtifact.canonicalDigest,
    coreConformanceDigest: conformanceArtifact.canonicalDigest,
    coreContract: structuredClone(contractArtifact.contract),
    coreOperations: structuredClone(contractArtifact.contract.coreOperations),
    relayEnvelopeOuterFields: [...contractArtifact.contract.envelope.fields],
    conformance: structuredClone(conformanceArtifact.conformance)
  });
}

export async function loadSecureClientRelayArtifacts() {
  const [contractText, conformanceText] = await Promise.all([
    fs.readFile(path.join(repoRoot, SECURE_CLIENT_RELAY_CORE_CONTRACT_PATH), "utf8"),
    fs.readFile(path.join(repoRoot, SECURE_CLIENT_RELAY_CORE_CONFORMANCE_PATH), "utf8")
  ]);
  return validateSecureClientRelayArtifacts(JSON.parse(contractText), JSON.parse(conformanceText));
}

export async function loadDigestBoundJsonInput({ filePath, expectedDigest, label = "external report" } = {}) {
  const explicitPath = String(filePath || "").trim();
  const digest = String(expectedDigest || "").trim();
  assert(explicitPath, `${label} path must be provided explicitly`);
  assert(DIGEST_PATTERN.test(digest), `${label} digest must be an explicit sha256 value`);
  let handle;
  let bytes;
  try {
    handle = await fs.open(path.resolve(explicitPath), "r");
    const stat = await handle.stat();
    assert(stat.isFile() && stat.size <= MAX_EXTERNAL_JSON_BYTES, `${label} exceeds the bounded JSON input size`);
    bytes = await handle.readFile();
  } catch {
    throw new Error(`${label} could not be read`);
  } finally {
    await handle?.close().catch(() => {});
  }
  const actualDigest = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
  assert(actualDigest === digest, `${label} digest mismatch`);
  let value;
  try {
    value = JSON.parse(bytes.toString("utf8"));
  } catch {
    throw new Error(`${label} must contain valid JSON`);
  }
  return deepFreeze({
    digest: actualDigest,
    value
  });
}
