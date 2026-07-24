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

const specs = Object.freeze({
  "LicoUp-macos-arm64.zip": {
    platform: "macos-arm64",
    checksum: "LicoUp-macos-arm64.zip.sha256",
    files: ["LicoUp-macos-arm64.zip", "LicoUp-macos-arm64.zip.sha256"],
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
