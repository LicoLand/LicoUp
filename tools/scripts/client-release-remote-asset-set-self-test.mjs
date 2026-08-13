#!/usr/bin/env node

import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const verifier = path.join(repoRoot, "tools/scripts/client-release-remote-asset-set.mjs");
const root = mkdtempSync(path.join(tmpdir(), "lico-remote-assets-"));
const targetId = "android-direct-arm64-v8a";
const artifactName = "LicoUp-android-arm64.apk";
const checksumName = `${artifactName}.sha256`;
const buildManifestName = "LicoUp-android-arm64.build.json";
const packageManifestName = `LicoUp-${targetId}.package.json`;
const consumerManifestName = "LicoUp-consumer-verification.json";
const updateManifestName = "LicoUp-update-manifest.json";
const updateKeysName = "LicoUp-update-public-keys.json";
const updateManifestSchema = "v0.0.1:client-update:manifest-1";
const productVersion = "0.0.1-test";
const sourceStateDigest = `sha256:${"a".repeat(64)}`;
const targetCatalogDigest = `sha256:${createHash("sha256").update(readFileSync(
  path.join(repoRoot, "tools/client-release-targets.json"),
)).digest("hex")}`;

function uint32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value);
  return buffer;
}

function uint64(value) {
  const buffer = Buffer.alloc(8);
  buffer.writeBigUInt64LE(BigInt(value));
  return buffer;
}

function lengthPrefixed32(value) {
  return Buffer.concat([uint32(value.length), value]);
}

function signedApkFixture() {
  const name = Buffer.from("AndroidManifest.xml", "utf8");
  const content = Buffer.from("canonical-android-manifest-fixture", "utf8");
  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);
  local.writeUInt32LE(content.length, 18);
  local.writeUInt32LE(content.length, 22);
  local.writeUInt16LE(name.length, 26);
  const localRecord = Buffer.concat([local, name, content]);

  const certificate = Buffer.from("canonical-self-test-certificate", "utf8");
  const signedData = Buffer.concat([
    lengthPrefixed32(Buffer.alloc(0)),
    lengthPrefixed32(lengthPrefixed32(certificate)),
  ]);
  const signer = lengthPrefixed32(signedData);
  const signerValue = lengthPrefixed32(lengthPrefixed32(signer));
  const pairValue = Buffer.concat([uint32(0x7109871a), signerValue]);
  const pair = Buffer.concat([uint64(pairValue.length), pairValue]);
  const blockSizeWithoutHeader = pair.length + 24;
  const signingBlock = Buffer.concat([
    uint64(blockSizeWithoutHeader),
    pair,
    uint64(blockSizeWithoutHeader),
    Buffer.from("APK Sig Block 42", "ascii"),
  ]);

  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0);
  central.writeUInt16LE(0x0314, 4);
  central.writeUInt16LE(20, 6);
  central.writeUInt32LE(content.length, 20);
  central.writeUInt32LE(content.length, 24);
  central.writeUInt16LE(name.length, 28);
  central.writeUInt32LE((0o100644 << 16) >>> 0, 38);
  const centralDirectory = Buffer.concat([central, name]);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(1, 8);
  end.writeUInt16LE(1, 10);
  end.writeUInt32LE(centralDirectory.length, 12);
  end.writeUInt32LE(localRecord.length + signingBlock.length, 16);
  return {
    bytes: Buffer.concat([localRecord, signingBlock, centralDirectory, end]),
    keyId: `sha256:${createHash("sha256").update(certificate).digest("hex")}`,
  };
}

function stableStringify(value) {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return Number.isInteger(value) ? String(value) : JSON.stringify(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (typeof value === "object") {
    const keys = Object.keys(value).sort();
    return `{${keys.map((key) =>
      `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
  }
  throw new Error("unsupported value");
}

function signedUpdateManifest(bytes) {
  const offline = generateKeyPairSync("ed25519");
  const online = generateKeyPairSync("ed25519");
  const rawPublic = (keyObject) => Buffer.from(
    keyObject.export({ type: "spki", format: "der" }),
  ).subarray(-32).toString("base64");
  const offlineId = "offline-root-self-test";
  const onlineId = "online-channel-self-test";
  const keys = {
    [offlineId]: { publicKey: rawPublic(offline.publicKey) },
    [onlineId]: { publicKey: rawPublic(online.publicKey) },
  };
  const document = {
    schemaVersion: updateManifestSchema,
    channel: "stable",
    channelPolicy: {
      offlineRootKeyId: offlineId,
      onlineChannelKeyId: onlineId,
      allowDowngrade: false,
    },
    releases: [{
      version: productVersion,
      minimumSupportedVersion: "0.0.0",
      classification: "optional",
      releaseNotesUrl: "https://github.com/LicoLand/LicoUp/releases/tag/v0.0.1-test",
      migrationNotes: [],
      artifacts: [{
        targetId: "android-arm64",
        platform: "android",
        osFamily: "android",
        arch: "arm64-v8a",
        installerStrategy: "manual-download",
        url: `https://github.com/LicoLand/LicoUp/releases/download/v0.0.1-test/${artifactName}`,
        fileName: artifactName,
        size: bytes.length,
        sha256: `sha256:${createHash("sha256").update(bytes).digest("hex")}`,
        applicationName: "LicoUp",
        bundleId: "land.lico.licoup",
      }],
    }],
  };
  const payload = Buffer.from(stableStringify(document), "utf8");
  return {
    manifestBytes: Buffer.from(`${JSON.stringify({
      ...document,
      signatures: [
        { keyId: offlineId, algorithm: "Ed25519",
          signature: sign(null, payload, offline.privateKey).toString("base64") },
        { keyId: onlineId, algorithm: "Ed25519",
          signature: sign(null, payload, online.privateKey).toString("base64") },
      ],
    })}\n`, "utf8"),
    keysBytes: Buffer.from(`${JSON.stringify({ keys })}\n`, "utf8"),
  };
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function invoke(remote) {
  return spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
}

try {
  const apk = signedApkFixture();
  const artifactSha256 = digest(apk.bytes);
  const checksumBytes = Buffer.from(`${artifactSha256}  ${artifactName}\n`, "utf8");
  const buildManifestBytes = Buffer.from(`${JSON.stringify({
    schemaVersion: "licomesh.client-release-build-manifest.v1",
    targetId,
    runtimeTargetId: "android-arm64",
    platform: "android",
    distributionFamily: "android",
    baseline: "android-api-21",
    channel: "direct",
    packageFormat: "apk",
    architecture: "arm64-v8a",
    updateAuthority: "manual-download",
    buildHost: "darwin-arm64",
    productVersion,
    buildNumber: 1,
    sourceStateDigest,
    targetCatalogDigest,
    artifact: { role: "installer", file: artifactName,
      sha256: `sha256:${artifactSha256}` },
    artifactDigest: `sha256:${artifactSha256}`,
    packageDigest: `sha256:${artifactSha256}`,
  })}\n`, "utf8");
  const packageArtifacts = [
    { role: "installer", file: artifactName, bytes: apk.bytes },
    { role: "checksum", for: "installer", file: checksumName, bytes: checksumBytes },
    { role: "build-manifest", file: buildManifestName, bytes: buildManifestBytes },
  ];
  const packageManifestBytes = Buffer.from(`${JSON.stringify({
    schemaVersion: "licomesh.client-release-package-manifest.v1",
    targetId,
    runtimeTargetId: "android-arm64",
    platform: "android",
    distributionFamily: "android",
    baseline: "android-api-21",
    channel: "direct",
    packageFormat: "apk",
    architecture: "arm64-v8a",
    productVersion,
    buildNumber: 1,
    updateAuthority: "manual-download",
    buildHost: "darwin-arm64",
    sourceStateDigest,
    targetCatalogDigest,
    updateProtocol: "manual-download",
    artifacts: packageArtifacts.map(({ bytes, ...artifact }) => ({
      ...artifact,
      byteSize: bytes.length,
      sha256: `sha256:${digest(bytes)}`,
    })),
  })}\n`, "utf8");
  const consumerManifestBytes = Buffer.from(`${JSON.stringify({
    schemaVersion: "licomesh.consumer-verification-manifest.v3",
    artifactName: "LicoUp",
    releaseTag: "v0.0.1-test",
    targets: [targetId],
    packages: [{
      targetId,
      manifest: packageManifestName,
      byteSize: packageManifestBytes.length,
      sha256: digest(packageManifestBytes),
    }],
    artifacts: [{
      name: artifactName,
      version: productVersion,
      targetId,
      role: "installer",
      platform: "android",
      channel: "direct",
      packageFormat: "apk",
      architecture: "arm64-v8a",
      byteSize: apk.bytes.length,
      sha256: artifactSha256,
      verification: {
        checksum: checksumName,
        algorithm: "SHA-256",
        signatureAlgorithm: "APK Signature Scheme v2+",
        keyId: apk.keyId,
      },
    }],
  })}\n`, "utf8");
  const update = signedUpdateManifest(apk.bytes);
  const assets = [
    { name: artifactName, bytes: apk.bytes },
    { name: checksumName, bytes: checksumBytes },
    { name: buildManifestName, bytes: buildManifestBytes },
    { name: packageManifestName, bytes: packageManifestBytes },
    { name: consumerManifestName, bytes: consumerManifestBytes },
    { name: updateManifestName, bytes: update.manifestBytes },
    { name: updateKeysName, bytes: update.keysBytes },
  ];
  for (const asset of assets) writeFileSync(path.join(root, asset.name), asset.bytes);
  const localAssets = assets.map((asset) => ({
    name: asset.name,
    size: asset.bytes.length,
    digest: `sha256:${digest(asset.bytes)}`,
  }));
  const remote = path.join(root, "..", `${path.basename(root)}-remote.json`);
  writeFileSync(remote, `${JSON.stringify(localAssets)}\n`);
  if (invoke(remote).status !== 0) throw new Error("exact remote asset set was rejected");

  writeFileSync(path.join(root, artifactName), Buffer.from("changed-artifact", "utf8"));
  if (invoke(remote).status === 0) throw new Error("stale consumer manifest was accepted");
  writeFileSync(path.join(root, artifactName), apk.bytes);

  const updateDocument = JSON.parse(update.manifestBytes.toString("utf8"));
  writeFileSync(path.join(root, updateManifestName), `${JSON.stringify({
    ...updateDocument,
    releases: [{ ...updateDocument.releases[0], version: "9.9.9-tampered" }],
  })}\n`);
  if (invoke(remote).status === 0) throw new Error("tampered update manifest was accepted");
  writeFileSync(path.join(root, updateManifestName), update.manifestBytes);

  rmSync(path.join(root, updateKeysName));
  if (invoke(remote).status === 0) throw new Error("orphaned update manifest was accepted");
  writeFileSync(path.join(root, updateKeysName), update.keysBytes);

  writeFileSync(remote, `${JSON.stringify([
    ...localAssets,
    { name: "unexpected", size: 1, digest: `sha256:${"0".repeat(64)}` },
  ])}\n`);
  if (invoke(remote).status === 0) throw new Error("extra remote asset was accepted");
  writeFileSync(remote, "x".repeat(128 * 1024 + 1));
  if (invoke(remote).status === 0) throw new Error("oversized remote metadata was accepted");

  console.log(JSON.stringify({
    ok: true,
    releaseSupportedFixture: targetId,
    namesSizesAndDigestsBound: true,
    manifestSemanticsBound: true,
    extrasRejected: true,
    oversizedMetadataRejected: true,
  }));
  rmSync(remote, { force: true });
} finally {
  rmSync(root, { recursive: true, force: true });
}
