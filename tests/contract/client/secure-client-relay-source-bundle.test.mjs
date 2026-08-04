import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const relayRoot = "crates/licoup-native/src/platform/secure_client_relay";
const productionLeaves = Object.freeze([
  "contract.rs",
  "http_io.rs",
  "redaction.rs",
  "request.rs",
  "response_binding.rs",
  "response_codec.rs",
  "response_schema.rs",
  "status_projection.rs",
  "transport.rs",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${relayRoot}/${leaf}`),
  ])));
}

test("Secure Client Relay has one exact module root and no retired implementation", async () => {
  const facade = await read(`${relayRoot}/mod.rs`);
  assert.deepEqual(
    [...facade.matchAll(/^mod ([a-z_]+);$/gmu)]
      .map((match) => match[1])
      .filter((moduleName) => moduleName !== "tests")
      .map((moduleName) => `${moduleName}.rs`)
      .sort(),
    [...productionLeaves].sort(),
  );
  for (const retired of [
    "crates/licoup-native/src/platform/secure_client_relay_transport.rs",
    "crates/licoup-native/src/platform/secure_client_relay_response.rs",
  ]) {
    await assert.rejects(fs.access(path.join(repoRoot, retired)));
  }
  const platform = await read("crates/licoup-native/src/platform/mod.rs");
  assert.ok(platform.includes("pub mod secure_client_relay;"));
  assert.equal(platform.includes("secure_client_relay_transport"), false);
  assert.equal(platform.includes("secure_client_relay_response"), false);
});

test("contract is the only relay type, limit, operation, and error authority", async () => {
  const source = await sources();
  const contract = source["contract.rs"];
  for (const token of [
    "SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST",
    "SECURE_CLIENT_RELAY_CORE_CONFORMANCE_DIGEST",
    "enum SecureClientRelayOperation",
    "struct SecureClientRelayAuth",
    "struct SecureClientRelayScope",
    "struct SecureClientRelayPublicJwk",
    "struct SecureClientRelayEndpointRegistration",
    "struct SecureClientRelayHttpError",
    "MAX_HTTP_RESPONSE_BYTES",
    "HTTP_TIMEOUT_SECONDS",
  ]) {
    assert.ok(contract.includes(token), `missing contract authority: ${token}`);
  }
  assert.ok(contract.includes('"client_local_runtime"'));
  const nonContract = productionLeaves
    .filter((leaf) => leaf !== "contract.rs")
    .map((leaf) => source[leaf])
    .join("\n");
  for (const duplicate of [
    "pub enum SecureClientRelayOperation",
    "pub struct SecureClientRelayScope",
    "const MAX_HTTP_RESPONSE_BYTES:",
  ]) {
    assert.equal(nonContract.includes(duplicate), false, `duplicate authority: ${duplicate}`);
  }
});

test("request and transport expose only the closed five-operation ciphertext surface", async () => {
  const source = await sources();
  const request = source["request.rs"];
  const transport = source["transport.rs"];
  for (const operation of [
    "endpoint_challenge",
    "endpoint_register",
    "envelope_send",
    "envelope_sync",
    "envelope_ack",
  ]) {
    assert.ok(request.includes(`fn ${operation}`));
    assert.ok(transport.includes(`fn ${operation}`));
  }
  assert.ok(request.includes("envelope.to_json()"));
  assert.ok(request.includes("envelope.validate()?"));
  assert.equal(request.includes("pairingId"), false);
  assert.equal(request.includes("commandId"), false);
  assert.equal(request.includes("plaintext"), false);
});

test("network capability is isolated, TLS-gated, bounded, and detail-redacted", async () => {
  const source = await sources();
  const ureqOwners = productionLeaves.filter((leaf) => source[leaf].includes("ureq::"));
  assert.deepEqual(ureqOwners, ["http_io.rs"]);
  const http = source["http_io.rs"];
  for (const token of [
    "is_https_or_loopback_http_url(&base_url)",
    "Duration::from_secs(HTTP_TIMEOUT_SECONDS)",
    'set("x-lico-safety-confirm", "true")',
    "MAX_RETRY_AFTER_SECONDS",
    "response.into_reader()",
  ]) {
    assert.ok(http.includes(token), `missing HTTP boundary: ${token}`);
  }
  const codec = source["response_codec.rs"];
  assert.ok(codec.includes("MAX_HTTP_RESPONSE_BYTES"));
  assert.ok(codec.includes("MAX_HTTP_ERROR_RESPONSE_BYTES"));
  assert.ok(codec.includes("take((maximum_bytes + 1) as u64)"));
  assert.ok(codec.includes('eq_ignore_ascii_case("application/json")'));
  assert.equal(codec.includes("ureq::"), false);
  assert.ok(source["redaction.rs"].includes("SecureClientRelayAuth([redacted])"));
  assert.equal(source["status_projection.rs"].includes('field(object, "error")'), false);
});

test("response shape, caller binding, and regressions remain separate leaves", async () => {
  const source = await sources();
  assert.ok(source["response_schema.rs"].includes("fn validate_success_response"));
  assert.ok(source["response_schema.rs"].includes("fn validate_error_response"));
  assert.ok(source["response_binding.rs"].includes("fn validate_send_response_binding"));
  assert.equal(source["response_schema.rs"].includes("ureq::"), false);
  assert.equal(source["response_binding.rs"].includes("ureq::"), false);
  for (const leaf of productionLeaves) {
    assert.equal(source[leaf].includes("use super::*"), false, `${leaf} has wildcard coupling`);
  }
  const testsFacade = await read(`${relayRoot}/tests/mod.rs`);
  assert.deepEqual(
    [...testsFacade.matchAll(/^mod ([a-z_]+);$/gmu)].map((match) => match[1]).sort(),
    ["contract", "http", "response", "support"],
  );
});
