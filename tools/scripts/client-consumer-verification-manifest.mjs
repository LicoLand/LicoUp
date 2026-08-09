#!/usr/bin/env node

import { createHash, createPublicKey, verify, X509Certificate } from "node:crypto";
import { lstatSync, readdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { sha256File } from "./lib/client-release-artifact-digest.mjs";
import { stableReadFile } from "./lib/client-release-artifact-digest.mjs";
import { androidApkSigningCertificateKeyId } from "./lib/android-apk-facts.mjs";

const MAX_CHECKSUM_BYTES = 4 * 1024;
const MAX_SIGNATURE_BYTES = 16 * 1024;
const MAX_PUBLIC_KEY_BYTES = 64 * 1024;

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const productVersion = JSON.parse(
  readFileSync(path.join(repoRoot, "tools/client-version.json"), "utf8"),
).productVersion;
if (typeof productVersion !== "string" || productVersion.length === 0) {
  fail("client product version is missing");
}
const targetSpecs = {
  "macos-arm64": {
    platform: "macos-arm64",
    artifact: "LicoUp-macos-arm64.zip",
    files: ["LicoUp-macos-arm64.zip", "LicoUp-macos-arm64.zip.sha256", "install-macos.sh"],
    checksum: "LicoUp-macos-arm64.zip.sha256",
  },
  "linux-glibc-arm64": {
    platform: "linux-glibc-arm64",
    artifact: "LicoUp-linux-arm64.tar.gz",
    files: [
      "LicoUp-linux-arm64.tar.gz",
      "LicoUp-linux-arm64.tar.gz.sha256",
      "LicoUp-linux-arm64.tar.gz.sig",
      "linux-release-verification-key.pem",
    ],
    checksum: "LicoUp-linux-arm64.tar.gz.sha256",
    signature: "LicoUp-linux-arm64.tar.gz.sig",
    verificationKey: "linux-release-verification-key.pem",
    verificationAlgorithm: "Ed25519",
    keyId: "linux-vm-acceptance",
  },
  "android-arm64": {
    platform: "android-arm64",
    artifact: "LicoUp-android-arm64.apk",
    files: [
      "LicoUp-android-arm64.apk",
      "LicoUp-android-arm64.apk.sha256",
      "lico-github-artifact.pem",
    ],
    checksum: "LicoUp-android-arm64.apk.sha256",
    verificationKey: "lico-github-artifact.pem",
    verificationAlgorithm: "APK Signature Scheme v2+",
  },
};

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined) fail("invalid arguments");
    result[name.slice(2)] = value;
  }
  return result;
}

function sha256(filePath) {
  return sha256File(filePath, { maxBytes: 1024 * 1024 * 1024 })
    .slice("sha256:".length);
}

function containedFile(root, name) {
  if (path.basename(name) !== name || name.includes("..")) fail("invalid asset name");
  const resolved = path.resolve(root, name);
  if (path.dirname(resolved) !== root || lstatSync(resolved).isSymbolicLink() ||
    realpathSync(resolved) !== resolved || !statSync(resolved).isFile()) {
    fail(`missing regular release asset: ${name}`);
  }
  return resolved;
}

const args = parseArgs(process.argv.slice(2));
const assetsRoot = realpathSync(path.resolve(repoRoot, args.assets || ""));
const requestedOutputPath = path.resolve(repoRoot, args.output || "");
if (realpathSync(path.dirname(requestedOutputPath)) !== assetsRoot ||
  path.basename(requestedOutputPath) !== "LicoUp-consumer-verification.json") {
  fail("manifest must be written beside release assets");
}
const outputPath = path.join(assetsRoot, path.basename(requestedOutputPath));
if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,126}$/u.test(args.tag || "")) fail("invalid release tag");

const selectedIds = String(args.targets || "").split(",").map((entry) => {
  const [id, selected, ...rest] = entry.split("=");
  if (rest.length || !targetSpecs[id] || !["true", "false"].includes(selected)) {
    fail("invalid target selection");
  }
  return selected === "true" ? id : "";
}).filter(Boolean);
if (selectedIds.length === 0 || new Set(selectedIds).size !== selectedIds.length) {
  fail("target selection must be non-empty and unique");
}

const expectedFiles = selectedIds.flatMap((id) => targetSpecs[id].files).sort();
const actualEntries = readdirSync(assetsRoot, { withFileTypes: true });
const actualFiles = actualEntries.map((entry) => entry.name).sort();
if (actualEntries.some((entry) => !entry.isFile() || entry.isSymbolicLink()) ||
  JSON.stringify(actualFiles) !== JSON.stringify(expectedFiles)) {
  fail("release asset set does not exactly match selected targets");
}

const artifacts = selectedIds.sort().map((id) => {
  const spec = targetSpecs[id];
  const artifactPath = containedFile(assetsRoot, spec.artifact);
  const digest = sha256(artifactPath);
  const checksumPath = containedFile(assetsRoot, spec.checksum);
  const checksum = stableReadFile(checksumPath, {
    maxBytes: MAX_CHECKSUM_BYTES,
  }).toString("utf8");
  if (checksum !== `${digest}  ${spec.artifact}\n`) fail(`checksum mismatch: ${spec.artifact}`);
  const verification = {
    checksum: spec.checksum,
    algorithm: "SHA-256",
  };
  if (spec.signature) verification.detachedSignature = spec.signature;
  if (spec.verificationKey) verification.publicVerificationKey = spec.verificationKey;
  if (spec.verificationAlgorithm) verification.signatureAlgorithm = spec.verificationAlgorithm;
  if (spec.keyId) verification.keyId = spec.keyId;
  if (id === "linux-glibc-arm64") {
    const key = createPublicKey(stableReadFile(
      containedFile(assetsRoot, spec.verificationKey),
      { maxBytes: MAX_PUBLIC_KEY_BYTES },
    ));
    const signature = Buffer.from(
      stableReadFile(containedFile(assetsRoot, spec.signature), {
        maxBytes: MAX_SIGNATURE_BYTES,
      }).toString("utf8").trim(),
      "base64",
    );
    if (key.asymmetricKeyType !== "ed25519" || signature.length !== 64 ||
      !verify(null, Buffer.from(digest, "hex"), key, signature)) {
      fail("Linux detached signature verification failed");
    }
  }
  if (id === "android-arm64") {
    const certificate = new X509Certificate(stableReadFile(
      containedFile(assetsRoot, spec.verificationKey),
      { maxBytes: MAX_PUBLIC_KEY_BYTES },
    ));
    verification.keyId = `sha256:${createHash("sha256").update(certificate.raw).digest("hex")}`;
    if (androidApkSigningCertificateKeyId(artifactPath) !== verification.keyId) {
      fail("Android APK signer does not match its public verification certificate");
    }
  }
  return {
    name: spec.artifact,
    version: productVersion,
    platform: spec.platform,
    byteSize: statSync(artifactPath).size,
    sha256: digest,
    verification,
  };
});

const manifest = {
  schemaVersion: "licomesh.consumer-verification-manifest.v1",
  artifactName: "LicoUp",
  releaseTag: args.tag,
  artifacts,
};
writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`, {
  encoding: "utf8",
  mode: 0o644,
  flag: "wx",
});
console.log(JSON.stringify({ ok: true, artifactCount: artifacts.length }));
