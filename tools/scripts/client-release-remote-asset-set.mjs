#!/usr/bin/env node

import { createHash, createPublicKey, verify, X509Certificate } from "node:crypto";
import { lstatSync, readdirSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  sha256File,
  stableReadFile,
} from "./lib/client-release-artifact-digest.mjs";
import { androidApkSigningCertificateKeyId } from "./lib/android-apk-facts.mjs";

const MAX_ASSETS = 16;
const MAX_REMOTE_JSON_BYTES = 128 * 1024;
const MAX_MANIFEST_BYTES = 128 * 1024;
const MAX_CHECKSUM_BYTES = 4 * 1024;
const MAX_SIGNATURE_BYTES = 16 * 1024;
const MAX_PUBLIC_KEY_BYTES = 64 * 1024;
const MANIFEST_NAME = "LicoUp-consumer-verification.json";
const UPDATE_MANIFEST_NAME = "LicoUp-update-manifest.json";
const UPDATE_PUBLIC_KEYS_NAME = "LicoUp-update-public-keys.json";
const UPDATE_MANIFEST_SCHEMA = "v0.0.1:client-update:manifest-1";
const MAX_UPDATE_MANIFEST_BYTES = 1024 * 1024;

const specs = Object.freeze({
  "LicoUp-macos-arm64.dmg": {
    platform: "macos-arm64",
    checksum: "LicoUp-macos-arm64.dmg.sha256",
    files: ["LicoUp-macos-arm64.dmg", "LicoUp-macos-arm64.dmg.sha256"],
  },
  "LicoUp-macos-arm64-update.zip": {
    platform: "macos-arm64-update",
    checksum: "LicoUp-macos-arm64-update.zip.sha256",
    files: [
      "LicoUp-macos-arm64-update.zip",
      "LicoUp-macos-arm64-update.zip.sha256",
    ],
  },
  "LicoUp-linux-arm64.tar.gz": {
    platform: "linux-glibc-arm64",
    checksum: "LicoUp-linux-arm64.tar.gz.sha256",
    signature: "LicoUp-linux-arm64.tar.gz.sig",
    publicKey: "linux-release-verification-key.pem",
    signatureAlgorithm: "Ed25519",
    keyId: "linux-vm-acceptance",
    files: [
      "LicoUp-linux-arm64.tar.gz",
      "LicoUp-linux-arm64.tar.gz.sha256",
      "LicoUp-linux-arm64.tar.gz.sig",
      "linux-release-verification-key.pem",
    ],
  },
  "LicoUp-android-arm64.apk": {
    platform: "android-arm64",
    checksum: "LicoUp-android-arm64.apk.sha256",
    publicKey: "lico-github-artifact.pem",
    signatureAlgorithm: "APK Signature Scheme v2+",
    files: [
      "LicoUp-android-arm64.apk",
      "LicoUp-android-arm64.apk.sha256",
      "lico-github-artifact.pem",
    ],
  },
});

function fail() {
  throw new Error("remote release asset set is not exact");
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    if (!argv[index]?.startsWith("--") || argv[index + 1] === undefined) fail();
    values[argv[index].slice(2)] = argv[index + 1];
  }
  return values;
}

function exactKeys(value, required) {
  return value && typeof value === "object" && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...required].sort());
}

function localFile(root, name) {
  if (path.basename(name) !== name) fail();
  const filePath = path.join(root, name);
  const info = lstatSync(filePath, { throwIfNoEntry: false });
  if (!info?.isFile() || info.isSymbolicLink() || realpathSync(filePath) !== filePath) fail();
  return filePath;
}

function readJson(filePath, maxBytes) {
  const parsed = JSON.parse(stableReadFile(filePath, { maxBytes }).toString("utf8"));
  return parsed;
}

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
  fail();
}

/// Validates the optional signed update manifest + public keys assets. The
/// release may carry them (when update signing keys are configured) or omit
/// them; when present they must verify cryptographically against each other.
function validateUpdateManifest(root, localByName) {
  const manifest = readJson(localFile(root, UPDATE_MANIFEST_NAME), MAX_UPDATE_MANIFEST_BYTES);
  const keysDocument = readJson(localFile(root, UPDATE_PUBLIC_KEYS_NAME), MAX_UPDATE_MANIFEST_BYTES);
  const keys = keysDocument.keys;
  if (!keys || typeof keys !== "object" || Array.isArray(keys) ||
    Object.keys(keys).length === 0) fail();
  const keyEntries = new Map(Object.entries(keys).map(([keyId, entry]) => [
    keyId,
    typeof entry === "string" ? entry : entry?.publicKey,
  ]));
  for (const [keyId, encoded] of keyEntries) {
    if (typeof encoded !== "string" || !/^[A-Za-z0-9+/=]+$/u.test(encoded) ||
      Buffer.from(encoded, "base64").length !== 32) fail();
    if (!/^[A-Za-z0-9_.-]{1,128}$/u.test(keyId)) fail();
  }
  const unsigned = { ...manifest };
  delete unsigned.signatures;
  const payload = Buffer.from(stableStringify(unsigned), "utf8");
  const verified = new Set();
  if (!Array.isArray(manifest.signatures) || manifest.signatures.length < 2) fail();
  for (const entry of manifest.signatures) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry) ||
      !exactKeys(entry, ["keyId", "algorithm", "signature"]) ||
      entry.algorithm !== "Ed25519") fail();
    const encoded = keyEntries.get(entry.keyId);
    if (typeof encoded !== "string") fail();
    const key = createPublicKey({
      key: Buffer.concat([
        Buffer.from("302a300506032b6570032100", "hex"),
        Buffer.from(encoded, "base64"),
      ]),
      format: "der",
      type: "spki",
    });
    if (entry.signature.length === 0 ||
      !verify(null, payload, key, Buffer.from(entry.signature, "base64"))) fail();
    verified.add(entry.keyId);
  }
  const policy = manifest.channelPolicy;
  if (!policy || typeof policy !== "object" || Array.isArray(policy) ||
    !exactKeys(policy, ["offlineRootKeyId", "onlineChannelKeyId", "allowDowngrade"]) ||
    policy.allowDowngrade !== false ||
    !verified.has(policy.offlineRootKeyId) || !verified.has(policy.onlineChannelKeyId) ||
    policy.offlineRootKeyId === policy.onlineChannelKeyId) fail();
  if (manifest.schemaVersion !== UPDATE_MANIFEST_SCHEMA ||
    !exactKeys(manifest, ["schemaVersion", "channel", "channelPolicy", "releases", "signatures"]) ||
    manifest.channel !== "stable" || !Array.isArray(manifest.releases) ||
    manifest.releases.length < 1 || manifest.releases.length > 8) fail();
  const artifactNames = new Set();
  for (const release of manifest.releases) {
    if (!release || typeof release !== "object" || Array.isArray(release) ||
      typeof release.version !== "string" || release.version.length === 0 ||
      typeof release.minimumSupportedVersion !== "string" ||
      !Array.isArray(release.artifacts) || release.artifacts.length === 0) fail();
    for (const artifact of release.artifacts) {
      if (!artifact || typeof artifact !== "object" || Array.isArray(artifact) ||
        typeof artifact.fileName !== "string" || artifact.fileName.length === 0 ||
        !/^sha256:[a-f0-9]{64}$/u.test(artifact.sha256 || "") ||
        !Number.isSafeInteger(artifact.size) || artifact.size <= 0 ||
        !/^https:\/\//u.test(artifact.url || "") ||
        !artifact.url.endsWith(`/${artifact.fileName}`)) fail();
      if (artifactNames.has(artifact.fileName)) fail();
      artifactNames.add(artifact.fileName);
      const local = localByName.get(artifact.fileName);
      if (!local || local.size !== artifact.size ||
        local.digest !== artifact.sha256) fail();
    }
  }
}

function validateManifest(root, localByName) {
  const manifest = readJson(localFile(root, MANIFEST_NAME), MAX_MANIFEST_BYTES);
  if (!exactKeys(manifest, ["schemaVersion", "artifactName", "releaseTag", "artifacts"]) ||
    manifest.schemaVersion !== "licomesh.consumer-verification-manifest.v1" ||
    manifest.artifactName !== "LicoUp" ||
    !/^[A-Za-z0-9][A-Za-z0-9._+-]{0,126}$/u.test(manifest.releaseTag || "") ||
    !Array.isArray(manifest.artifacts) || manifest.artifacts.length < 1 ||
    manifest.artifacts.length > Object.keys(specs).length) fail();
  const expectedNames = new Set([MANIFEST_NAME]);
  const artifactNames = new Set();
  for (const artifact of manifest.artifacts) {
    if (!exactKeys(artifact, ["name", "version", "platform", "byteSize", "sha256", "verification"])) fail();
    const spec = specs[artifact.name];
    if (!spec || artifactNames.has(artifact.name) || artifact.platform !== spec.platform ||
      typeof artifact.version !== "string" || artifact.version.length === 0 ||
      !Number.isSafeInteger(artifact.byteSize) || artifact.byteSize <= 0 ||
      !/^[a-f0-9]{64}$/u.test(artifact.sha256 || "")) fail();
    artifactNames.add(artifact.name);
    for (const name of spec.files) expectedNames.add(name);
    const local = localByName.get(artifact.name);
    if (!local || local.size !== artifact.byteSize || local.digest !== `sha256:${artifact.sha256}`) fail();
    const expectedVerificationKeys = ["checksum", "algorithm"];
    if (spec.signature) expectedVerificationKeys.push("detachedSignature");
    if (spec.publicKey) expectedVerificationKeys.push("publicVerificationKey");
    if (spec.signatureAlgorithm) expectedVerificationKeys.push("signatureAlgorithm");
    if (spec.keyId || spec.platform === "android-arm64") expectedVerificationKeys.push("keyId");
    const verification = artifact.verification;
    if (!exactKeys(verification, expectedVerificationKeys) ||
      verification.checksum !== spec.checksum || verification.algorithm !== "SHA-256" ||
      (spec.signature && verification.detachedSignature !== spec.signature) ||
      (spec.publicKey && verification.publicVerificationKey !== spec.publicKey) ||
      (spec.signatureAlgorithm && verification.signatureAlgorithm !== spec.signatureAlgorithm) ||
      (spec.keyId && verification.keyId !== spec.keyId)) fail();
    const checksum = stableReadFile(localFile(root, spec.checksum), {
      maxBytes: MAX_CHECKSUM_BYTES,
    }).toString("utf8");
    if (checksum !== `${artifact.sha256}  ${artifact.name}\n`) fail();
    if (spec.platform === "linux-glibc-arm64") {
      const key = createPublicKey(stableReadFile(localFile(root, spec.publicKey), {
        maxBytes: MAX_PUBLIC_KEY_BYTES,
      }));
      const signature = Buffer.from(stableReadFile(localFile(root, spec.signature), {
        maxBytes: MAX_SIGNATURE_BYTES,
      }).toString("utf8").trim(), "base64");
      if (key.asymmetricKeyType !== "ed25519" || signature.length !== 64 ||
        !verify(null, Buffer.from(artifact.sha256, "hex"), key, signature)) fail();
    }
    if (spec.platform === "android-arm64") {
      const certificate = new X509Certificate(stableReadFile(
        localFile(root, spec.publicKey),
        { maxBytes: MAX_PUBLIC_KEY_BYTES },
      ));
      const keyId = `sha256:${createHash("sha256").update(certificate.raw).digest("hex")}`;
      if (verification.keyId !== keyId ||
        androidApkSigningCertificateKeyId(localFile(root, artifact.name)) !== keyId) fail();
    }
  }
  const hasUpdateManifest = localByName.has(UPDATE_MANIFEST_NAME);
  const hasUpdateKeys = localByName.has(UPDATE_PUBLIC_KEYS_NAME);
  if (hasUpdateManifest !== hasUpdateKeys) fail();
  if (hasUpdateManifest) {
    validateUpdateManifest(root, localByName);
    expectedNames.add(UPDATE_MANIFEST_NAME);
    expectedNames.add(UPDATE_PUBLIC_KEYS_NAME);
  }
  if (JSON.stringify([...expectedNames].sort()) !==
    JSON.stringify([...localByName.keys()].sort())) fail();
  return manifest;
}

try {
  const args = parseArgs(process.argv.slice(2));
  const root = realpathSync(path.resolve(args.assets || ""));
  const entries = readdirSync(root, { withFileTypes: true });
  if (entries.length < 3 || entries.length > MAX_ASSETS) fail();
  const local = entries.map((entry) => {
    if (!entry.isFile() || entry.isSymbolicLink()) fail();
    const filePath = localFile(root, entry.name);
    return {
      name: entry.name,
      size: statSync(filePath).size,
      digest: sha256File(filePath, { maxBytes: 1024 * 1024 * 1024 }),
    };
  }).sort((left, right) => left.name.localeCompare(right.name));
  const localByName = new Map(local.map((entry) => [entry.name, entry]));
  validateManifest(root, localByName);
  const remote = readJson(path.resolve(args.remote || ""), MAX_REMOTE_JSON_BYTES);
  if (!Array.isArray(remote) || remote.length < 3 || remote.length > MAX_ASSETS) fail();
  const normalizedRemote = remote.map((entry) => {
    if (!exactKeys(entry, ["name", "size", "digest"]) ||
      path.basename(entry.name || "") !== entry.name ||
      !Number.isSafeInteger(entry.size) || entry.size < 0 ||
      !/^sha256:[a-f0-9]{64}$/u.test(entry.digest || "")) fail();
    return { name: entry.name, size: entry.size, digest: entry.digest };
  }).sort((left, right) => left.name.localeCompare(right.name));
  if (new Set(normalizedRemote.map((entry) => entry.name)).size !== normalizedRemote.length ||
    JSON.stringify(local) !== JSON.stringify(normalizedRemote)) fail();
  console.log(JSON.stringify({ ok: true, assetCount: local.length }));
} catch {
  console.error(JSON.stringify({ ok: false, error: "remote_release_asset_set_invalid" }));
  process.exitCode = 1;
}
