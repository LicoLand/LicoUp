import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  BETA_STAGE_ORDER,
  deriveManagedReleaseConfig,
  extractProvisioningProfilePayload,
  MacosReleaseToolError,
  parseCodeSigningIdentities,
  redactMacosReleaseToolFailure,
  validateManagedReleaseConfig,
} from "../../../tools/scripts/client-macos-release-tool.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const toolSource = readFileSync(
  path.join(repoRoot, "tools/scripts/client-macos-release-tool.mjs"),
  "utf8",
);
const distributionSource = readFileSync(
  path.join(repoRoot, "apps/desktop/scripts/build-macos-distribution.mjs"),
  "utf8",
);

function fixture() {
  return {
    profile: {
      ProvisionsAllDevices: true,
      TeamIdentifier: ["TEAM123456"],
      ExpirationDate: "2099-01-01T00:00:00Z",
      Entitlements: {
        "com.apple.application-identifier": "TEAM123456.land.lico.licoup",
      },
    },
    certificates: [{
      developerIdApplication: true,
      teamIdentifier: "TEAM123456",
      sha1: "A".repeat(40),
      sha256: `sha256:${"b".repeat(64)}`,
    }],
    identities: [{
      sha1: "A".repeat(40),
      name: "Developer ID Application: Fixture (TEAM123456)",
    }],
    profileDigest: `sha256:${"c".repeat(64)}`,
  };
}

test("setup preserves certificates while removing non-JSON profile payloads", () => {
  const payload = extractProvisioningProfilePayload(`<?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>TeamIdentifier</key><array><string>TEAM123456</string></array>
      <key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>
      <key>DeveloperCertificates</key><array>
        <data>QUJD</data>
        <data>REVG\nR0g=</data>
      </array>
      <key>DER-Encoded-Profile</key><data>SU5URVJOQUw=</data>
    </dict></plist>`);
  assert.deepEqual(payload.developerCertificates, ["QUJD", "REVGR0g="]);
  assert.equal(payload.sanitizedXml.includes("DeveloperCertificates"), false);
  assert.equal(payload.sanitizedXml.includes("DER-Encoded-Profile"), false);
  assert.equal(/<data(?:\s|>)/u.test(payload.sanitizedXml), false);
  assert.equal(payload.sanitizedXml.includes("<date>"), false);
  assert.ok(payload.sanitizedXml.includes("<string>2099-01-01T00:00:00Z</string>"));
});

test("setup resolves one profile-bound Developer ID identity", () => {
  const source = `
    1) ${"A".repeat(40)} "Developer ID Application: Fixture (TEAM123456)"
    2) ${"D".repeat(40)} "Apple Development: Fixture (TEAM123456)"
       2 valid identities found
  `;
  const identities = parseCodeSigningIdentities(source);
  assert.equal(identities.length, 2);
  const config = deriveManagedReleaseConfig({ ...fixture(), identities });
  assert.deepEqual(validateManagedReleaseConfig(config), config);
  assert.equal(config.notaryKeychainProfile, "licoup-macos-release");
  assert.equal(config.signingIdentity, "A".repeat(40));
  assert.equal(Object.hasOwn(config, "profilePath"), false);
  assert.equal(Object.hasOwn(config, "notaryKeyPath"), false);
  assert.equal(Object.hasOwn(config, "issuer"), false);
  assert.equal(Object.hasOwn(config, "keyId"), false);
});

test("setup rejects ambiguous, expired, mismatched, and non-Developer-ID inputs", () => {
  const base = fixture();
  for (const candidate of [
    { ...base, identities: [...base.identities, { ...base.identities[0] }] },
    { ...base, profile: { ...base.profile, ExpirationDate: "2000-01-01T00:00:00Z" } },
    { ...base, profile: { ...base.profile, TeamIdentifier: ["OTHER12345"] } },
    { ...base, certificates: [{ ...base.certificates[0], developerIdApplication: false }] },
  ]) {
    assert.throws(
      () => deriveManagedReleaseConfig(candidate),
      (error) => error instanceof MacosReleaseToolError &&
        /^macos_release_setup_/u.test(error.code),
    );
  }
});

test("daily beta is a strict local build-install-launch receipt pipeline", () => {
  assert.deepEqual(BETA_STAGE_ORDER, [
    "workspace",
    "source-gate",
    "release-policy",
    "distribution-preflight",
    "package",
    "artifact-install",
    "launch",
    "receipt",
  ]);
  for (const token of [
    '"tools/scripts/client-gate.mjs", "run", "source"',
    '"tools/scripts/client-gate.mjs", "run", "release-policy"',
    '"apps/desktop/scripts/build-macos-distribution.mjs", "--platform-channel"',
    '"tools/scripts/client-macos-release-artifact-preflight.mjs"',
    'publicationRequested: false',
    'remoteMutation: false',
  ]) {
    assert.ok(toolSource.includes(token), token);
  }
  for (const forbidden of [
    "gh release",
    "git push",
    "LICO_MACOS_NOTARY_KEY_PATH",
    "LICO_MACOS_NOTARY_KEY_ID",
    "LICO_MACOS_NOTARY_ISSUER_ID",
  ]) {
    assert.equal(toolSource.includes(forbidden), false, forbidden);
    assert.equal(distributionSource.includes(forbidden), false, forbidden);
  }
});

test("notarization is Keychain-backed and failures expose only stable codes", () => {
  assert.ok(toolSource.includes('"notarytool", "store-credentials"'));
  assert.ok(distributionSource.includes('"--keychain-profile", notaryKeychainProfile'));
  const privateMarker = "credential-marker-with-private-data";
  const redacted = redactMacosReleaseToolFailure(new Error(privateMarker));
  assert.deepEqual(redacted, {
    ok: false,
    code: "macos_release_tool_failed",
    privateDataIncluded: false,
  });
  assert.equal(JSON.stringify(redacted).includes(privateMarker), false);
});
