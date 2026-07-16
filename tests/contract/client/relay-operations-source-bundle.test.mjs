import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const facadePath = "crates/lico-client-native/src/domain/mobile_relay/relay_operations.rs";
const moduleRoot = "crates/lico-client-native/src/domain/mobile_relay/relay_operations";
const productionLeaves = Object.freeze([
  "allow_list.rs",
  "command_handlers.rs",
  "command_handlers/check_in.rs",
  "command_handlers/create.rs",
  "command_handlers/poll_complete.rs",
  "command_handlers/result.rs",
  "context.rs",
  "delivery.rs",
  "envelope.rs",
  "mailbox.rs",
  "registration.rs",
  "status.rs",
]);
const testLeaves = Object.freeze([
  "allow_list.rs",
  "command_handlers.rs",
  "context.rs",
  "delivery.rs",
  "envelope.rs",
  "mailbox.rs",
  "registration.rs",
  "status.rs",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${moduleRoot}/${leaf}`),
  ])));
}

test("relay operations uses a thin facade and ordinary owned leaves", async () => {
  const facade = await read(facadePath);
  assert.ok(facade.trimEnd().split(/\r?\n/u).length <= 40);
  assert.deepEqual(
    [...facade.matchAll(/^mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((name) => name !== "tests")
      .sort(),
    [
      "allow_list", "command_handlers", "context", "delivery", "envelope", "mailbox",
      "registration", "status",
    ],
  );
  for (const retiredImplementation of [
    "fn command_create_secure",
    "fn canonical_relay_context",
    "fn canonical_mailbox_token",
    "fn validate_secure_envelope",
    "fn register_local_relay_endpoint",
    "fn e2ee_status",
  ]) {
    assert.equal(facade.includes(retiredImplementation), false);
  }
});

test("command handlers retain ciphertext-only five-operation relay calls", async () => {
  const source = await sources();
  const handlers = [
    "command_handlers/check_in.rs",
    "command_handlers/create.rs",
    "command_handlers/poll_complete.rs",
    "command_handlers/result.rs",
  ].map((leaf) => source[leaf]).join("\n");
  for (const token of [
    "endpoint_challenge",
    "endpoint_register",
    "envelope_send",
    "envelope_sync",
    "envelope_ack",
  ]) {
    const fullSource = `${handlers}\n${source["registration.rs"]}`;
    assert.ok(fullSource.includes(token), token);
  }
  assert.ok(source["command_handlers/create.rs"].includes("secure_envelope_param(params)"));
  assert.ok(source["command_handlers/create.rs"].includes(
    "seal_mobile_relay_payload_with_pairwise_operation"));
  assert.ok(source["command_handlers/result.rs"].includes(
    "open_mobile_relay_payload_with_pairwise_operation"));
  assert.ok(source["command_handlers/result.rs"].includes('"bodyRedacted": true'));
  assert.equal(handlers.includes("execute_command"), false);
  assert.equal(handlers.includes("plaintext"), false);
});

test("canonical context mailbox envelope registration and delivery have distinct owners", async () => {
  const source = await sources();
  const ownership = new Map([
    ["context.rs", "fn canonical_relay_context"],
    ["mailbox.rs", "fn canonical_mailbox_token"],
    ["envelope.rs", "fn validate_secure_envelope"],
    ["registration.rs", "fn register_local_relay_endpoint"],
    ["delivery.rs", "fn relay_envelope_from_delivery"],
    ["status.rs", "fn e2ee_status"],
    ["allow_list.rs", "fn allowed_agent_ids"],
  ]);
  for (const [owner, token] of ownership) {
    assert.ok(source[owner].includes(token));
    for (const [other, otherSource] of Object.entries(source)) {
      if (other !== owner) assert.equal(otherSource.includes(token), false);
    }
  }
});

test("context and registration fail closed around explicit endpoint challenge authority", async () => {
  const source = await sources();
  for (const token of [
    "mobile relay is disabled",
    "secure client relay tenant id is missing",
    "secure client relay account id is missing",
    "secure client relay session token is missing",
    "secure client relay CSRF token is missing",
    "SecureClientRelayTransport::new",
  ]) {
    assert.ok(source["context.rs"].includes(token), token);
  }
  for (const token of [
    "challengeEncoding",
    "signatureAlgorithm",
    "Ed25519",
    "challenge_signature",
    "SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST",
  ]) {
    assert.ok(source["registration.rs"].includes(token), token);
  }
});

test("mailbox envelope and delivery enforce canonical bounded cryptographic structures", async () => {
  const source = await sources();
  for (const token of [
    "SecureMeshDeliverySecret",
    "SecureMeshMailboxSchedule",
    "SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS",
    "checked_mul",
  ]) {
    assert.ok(source["mailbox.rs"].includes(token), token);
  }
  assert.ok(source["envelope.rs"].includes("SecureMeshRelayEnvelope::from_json"));
  assert.ok(source["envelope.rs"].includes("MOBILE_RELAY_COMMAND_TTL_SECONDS"));
  assert.ok(source["envelope.rs"].includes("MOBILE_RELAY_ENVELOPE_CLOCK_SKEW_SECONDS"));
  assert.ok(source["delivery.rs"].includes("SECURE_MESH_RELAY_OUTER_FIELDS"));
  assert.ok(source["delivery.rs"].includes("delivery envelope is incomplete"));
});

test("status and allow list remain authorization-aware and secret-free", async () => {
  const source = await sources();
  for (const token of [
    "should_authorize_secret_read",
    "authorizationRequiredForFullStatus",
    "pairwise_session_verification_requires_authorization",
    "key_transparency_label_refresh_required",
    "redacted_pairing_invite",
  ]) {
    assert.ok(source["status.rs"].includes(token), token);
  }
  assert.ok(source["allow_list.rs"].includes("PACKAGED_RUNTIME_ADAPTER_IDS"));
  assert.ok(source["allow_list.rs"].includes("runtime.message.send"));
  assert.ok(source["allow_list.rs"].includes("BTreeSet"));
  for (const forbiddenSecret of [
    "privateKeyBase64url", "signingKeyBase64url", "pairingSecretBase64url",
  ]) {
    assert.equal(source["status.rs"].includes(forbiddenSecret), false);
  }
});

test("relay operations has no wildcard hidden implementation or direct HTTP egress", async () => {
  const source = await sources();
  const joined = Object.values(source).join("\n");
  for (const forbidden of [
    "use super::*", "use crate::*", "::*;", "#[path", "include!(", "mod tests {",
    "ureq::", "reqwest::", "TcpStream", "Command::new", "upload", "http://", "https://",
  ]) {
    assert.equal(joined.includes(forbidden), false, forbidden);
  }
});

test("relay operations regressions are split into selectable leaves", async () => {
  const entries = await fs.readdir(path.join(repoRoot, moduleRoot, "tests"), {
    withFileTypes: true,
  });
  assert.deepEqual(
    entries
      .filter((entry) => entry.isFile() && entry.name.endsWith(".rs"))
      .map((entry) => entry.name)
      .sort(),
    [...testLeaves].sort(),
  );
  const testFacade = await read(`${moduleRoot}/tests.rs`);
  assert.equal(testFacade.includes("mod tests {"), false);
  assert.equal(testFacade.includes("#[path"), false);
});
