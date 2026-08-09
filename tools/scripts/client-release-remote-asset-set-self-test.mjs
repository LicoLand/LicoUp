#!/usr/bin/env node

import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const verifier = path.join(repoRoot, "tools/scripts/client-release-remote-asset-set.mjs");
const root = mkdtempSync(path.join(tmpdir(), "lico-remote-assets-"));
const UPDATE_MANIFEST_SCHEMA = "v0.0.1:client-update:manifest-1";

function stableStringify(value) {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return Number.isInteger(value) ? String(value) : JSON.stringify(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (typeof value === "object") {
    const keys = Object.keys(value).sort();
    return `{${keys
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`;
  }
  throw new Error("unsupported value");
}

function signedUpdateManifest(artifactName, artifactBytes) {
  const offline = generateKeyPairSync("ed25519");
  const online = generateKeyPairSync("ed25519");
  const rawPublic = (keyObject) =>
    Buffer.from(keyObject.export({ type: "spki", format: "der" })).subarray(-32).toString("base64");
  const offlineId = "offline-root-self-test";
  const onlineId = "online-channel-self-test";
  const keys = {
    [offlineId]: { publicKey: rawPublic(offline.publicKey) },
    [onlineId]: { publicKey: rawPublic(online.publicKey) },
  };
  const document = {
    schemaVersion: UPDATE_MANIFEST_SCHEMA,
    channel: "stable",
    channelPolicy: {
      offlineRootKeyId: offlineId,
      onlineChannelKeyId: onlineId,
      allowDowngrade: false,
    },
    releases: [{
      version: "0.0.1-test",
      minimumSupportedVersion: "0.0.0",
      classification: "optional",
      releaseNotesUrl: "https://github.com/LicoLand/LicoUp/releases/tag/v0.0.1-test",
      migrationNotes: [],
      artifacts: [{
        targetId: "macos-arm64",
        platform: "macos",
        osFamily: "macos",
        arch: "arm64",
        installerStrategy: "app-bundle-replacement",
        url: `https://github.com/LicoLand/LicoUp/releases/download/v0.0.1-test/${artifactName}`,
        fileName: artifactName,
        size: artifactBytes.length,
        sha256: `sha256:${createHash("sha256").update(artifactBytes).digest("hex")}`,
        applicationName: "LicoUp.app",
        bundleId: "land.lico.licoup",
      }],
    }],
  };
  const unsigned = { ...document };
  delete unsigned.signatures;
  const payload = Buffer.from(stableStringify(unsigned), "utf8");
  const manifest = {
    ...document,
    signatures: [
      { keyId: offlineId, algorithm: "Ed25519",
        signature: sign(null, payload, offline.privateKey).toString("base64") },
      { keyId: onlineId, algorithm: "Ed25519",
        signature: sign(null, payload, online.privateKey).toString("base64") },
    ],
  };
  return {
    manifestBytes: Buffer.from(`${JSON.stringify(manifest)}\n`, "utf8"),
    keysBytes: Buffer.from(`${JSON.stringify({ keys })}\n`, "utf8"),
  };
}

try {
  const artifactName = "LicoUp-macos-arm64.dmg";
  const artifactBytes = Buffer.from("canonical-artifact", "utf8");
  const artifactSha256 = createHash("sha256").update(artifactBytes).digest("hex");
  const checksumName = `${artifactName}.sha256`;
  const checksumBytes = Buffer.from(`${artifactSha256}  ${artifactName}\n`, "utf8");
  const updateArtifactName = "LicoUp-macos-arm64-update.zip";
  const updateArtifactBytes = Buffer.from("canonical-update-artifact", "utf8");
  const updateArtifactSha256 = createHash("sha256").update(updateArtifactBytes).digest("hex");
  const updateChecksumName = `${updateArtifactName}.sha256`;
  const updateChecksumBytes = Buffer.from(
    `${updateArtifactSha256}  ${updateArtifactName}\n`, "utf8");
  const name = "LicoUp-consumer-verification.json";
  const bytes = Buffer.from(`${JSON.stringify({
    schemaVersion: "licomesh.consumer-verification-manifest.v1",
    artifactName: "LicoUp",
    releaseTag: "v0.0.1-test",
    artifacts: [{
      name: artifactName,
      version: "0.0.1-test",
      platform: "macos-arm64",
      byteSize: artifactBytes.length,
      sha256: artifactSha256,
      verification: { checksum: checksumName, algorithm: "SHA-256" },
    }, {
      name: updateArtifactName,
      version: "0.0.1-test",
      platform: "macos-arm64-update",
      byteSize: updateArtifactBytes.length,
      sha256: updateArtifactSha256,
      verification: { checksum: updateChecksumName, algorithm: "SHA-256" },
    }],
  })}\n`, "utf8");
  writeFileSync(path.join(root, artifactName), artifactBytes);
  writeFileSync(path.join(root, checksumName), checksumBytes);
  writeFileSync(path.join(root, updateArtifactName), updateArtifactBytes);
  writeFileSync(path.join(root, updateChecksumName), updateChecksumBytes);
  writeFileSync(path.join(root, name), bytes);
  const updateManifest = signedUpdateManifest(updateArtifactName, updateArtifactBytes);
  writeFileSync(path.join(root, "LicoUp-update-manifest.json"), updateManifest.manifestBytes);
  writeFileSync(path.join(root, "LicoUp-update-public-keys.json"), updateManifest.keysBytes);
  const localAssets = [
    { name: artifactName, bytes: artifactBytes },
    { name: checksumName, bytes: checksumBytes },
    { name: updateArtifactName, bytes: updateArtifactBytes },
    { name: updateChecksumName, bytes: updateChecksumBytes },
    { name, bytes: bytes },
    { name: "LicoUp-update-manifest.json", bytes: updateManifest.manifestBytes },
    { name: "LicoUp-update-public-keys.json", bytes: updateManifest.keysBytes },
  ].map((entry) => ({
    name: entry.name,
    size: entry.bytes.length,
    digest: `sha256:${createHash("sha256").update(entry.bytes).digest("hex")}`,
  }));
  const remote = path.join(root, "..", `${path.basename(root)}-remote.json`);
  writeFileSync(remote, `${JSON.stringify(localAssets)}\n`);
  const valid = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (valid.status !== 0) throw new Error("exact remote asset set was rejected");
  writeFileSync(path.join(root, artifactName), Buffer.from("changed-artifact", "utf8"));
  const staleManifest = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (staleManifest.status === 0) throw new Error("stale consumer manifest was accepted");
  writeFileSync(path.join(root, artifactName), artifactBytes);
  writeFileSync(
    path.join(root, "LicoUp-update-manifest.json"),
    `${JSON.stringify({
      ...JSON.parse(updateManifest.manifestBytes.toString("utf8")),
      releases: [{ ...JSON.parse(updateManifest.manifestBytes.toString("utf8")).releases[0],
        version: "9.9.9-tampered" }],
    })}\n`,
  );
  const tamperedUpdate = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (tamperedUpdate.status === 0) throw new Error("tampered update manifest was accepted");
  writeFileSync(path.join(root, "LicoUp-update-manifest.json"), updateManifest.manifestBytes);
  rmSync(path.join(root, "LicoUp-update-public-keys.json"));
  const orphanedManifest = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (orphanedManifest.status === 0) throw new Error("orphaned update manifest was accepted");
  writeFileSync(path.join(root, "LicoUp-update-public-keys.json"), updateManifest.keysBytes);
  writeFileSync(path.join(root, artifactName), artifactBytes);
  writeFileSync(remote, `${JSON.stringify([
    ...localAssets,
    { name: "unexpected", size: 1, digest: `sha256:${"0".repeat(64)}` },
  ])}\n`);
  const extra = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (extra.status === 0) throw new Error("extra remote asset was accepted");
  writeFileSync(remote, "x".repeat(128 * 1024 + 1));
  const oversized = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (oversized.status === 0) throw new Error("oversized remote metadata was accepted");
  console.log(JSON.stringify({
    ok: true,
    namesSizesAndDigestsBound: true,
    manifestSemanticsBound: true,
    extrasRejected: true,
    oversizedMetadataRejected: true,
  }));
  rmSync(remote, { force: true });
} finally {
  rmSync(root, { recursive: true, force: true });
}
