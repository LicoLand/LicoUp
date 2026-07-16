import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
const panelRoot =
  "apps/desktop/lib/src/frontend/features/mobile_relay/ui/mobile_relay_panel";
const productionLeaves = Object.freeze([
  "composition.dart",
  "pairing.dart",
  "qr.dart",
  "scan.dart",
  "trust.dart",
]);

async function read(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function sources() {
  return Object.fromEntries(await Promise.all(productionLeaves.map(async (leaf) => [
    leaf,
    await read(`${panelRoot}/${leaf}`),
  ])));
}

test("mobile relay panel root exports exactly five ordinary libraries", async () => {
  const facade = await read(`${panelRoot}.dart`);
  assert.deepEqual(
    [...facade.matchAll(/^export 'mobile_relay_panel\/([^']+)';$/gmu)]
      .map((match) => match[1])
      .sort(),
    [...productionLeaves].sort(),
  );
  assert.equal(facade.trimEnd().split(/\r?\n/u).length, 5);
  assert.equal(facade.includes("part "), false);
  assert.equal(facade.includes("class "), false);
});

test("panel leaves stay bounded with one-way composition dependencies", async () => {
  const source = await sources();
  const limits = new Map([
    ["composition.dart", 210],
    ["pairing.dart", 300],
    ["qr.dart", 140],
    ["scan.dart", 70],
    ["trust.dart", 220],
  ]);
  for (const [leaf, limit] of limits) {
    assert.ok(source[leaf].trimEnd().split(/\r?\n/u).length <= limit, `${leaf} is oversized`);
    assert.equal(source[leaf].includes("mobile_relay_panel.dart"), false);
    assert.equal(source[leaf].includes("part of"), false);
  }
  for (const dependency of ["pairing.dart", "scan.dart", "trust.dart"]) {
    assert.ok(source["composition.dart"].includes(`mobile_relay_panel/${dependency}`));
  }
  assert.ok(source["pairing.dart"].includes("mobile_relay_panel/qr.dart"));
  for (const independent of ["qr.dart", "scan.dart", "trust.dart"]) {
    assert.equal(source[independent].includes("mobile_relay_panel/composition.dart"), false);
    assert.equal(source[independent].includes("mobile_relay_panel/pairing.dart"), false);
  }
});

test("composition and pairing retain lifecycle and explicit gateway ownership", async () => {
  const source = await sources();
  for (const token of [
    "class MobileRelayPanel",
    "isMobileClientPlatform(context)",
    "MobileRelayScanPairingPrompt",
    "MobileRelayPairingWorkspaceCard",
    "MobileRelayTrustVerificationCard",
    "showMobileRelayPopup",
  ]) {
    assert.ok(source["composition.dart"].includes(token), `missing composition token: ${token}`);
  }
  for (const token of [
    "class MobileRelayPairingWorkspaceCard",
    "mobile-relay-explicit-gateway-field",
    "canonicalMobileRelayGatewayOrigin",
    "configureMobileRelayGateway",
    "copyMobilePairingCode",
    "class MobileRelayPairingInfoRow",
  ]) {
    assert.ok(source["pairing.dart"].includes(token), `missing pairing token: ${token}`);
  }
});

test("QR, scan, and trust remain independently constructable presenters", async () => {
  const source = await sources();
  for (const token of [
    "class MobileRelayPairingQrFrame",
    "gatewayConfigured",
    "QrImageView",
    "pairing-qr-frame",
  ]) {
    assert.ok(source["qr.dart"].includes(token), `missing QR token: ${token}`);
  }
  for (const token of [
    "class MobileRelayScanPairingPrompt",
    "MinimalScanIcon",
    "mobile-relay-scan-pairing-prompt",
  ]) {
    assert.ok(source["scan.dart"].includes(token), `missing scan token: ${token}`);
  }
  for (const token of [
    "class MobileRelayTrustVerificationCard",
    "secure-mesh-60-digit-safety-number",
    "presentation.trustState",
    "presentation.localFingerprint",
    "QrImageView",
  ]) {
    assert.ok(source["trust.dart"].includes(token), `missing trust token: ${token}`);
  }
  for (const independent of ["qr.dart", "scan.dart", "trust.dart"]) {
    assert.equal(source[independent].includes("ClientController"), false);
  }
});

test("every panel responsibility retains a dedicated widget regression", async () => {
  for (const leaf of productionLeaves) {
    await fs.access(path.join(
      repoRoot,
      `apps/desktop/test/mobile_relay_panel/${leaf.replace(".dart", "_test.dart")}`,
    ));
  }
  await fs.access(path.join(
    repoRoot,
    "apps/desktop/test/mobile_relay_panel/panel_test_harness.dart",
  ));
});
