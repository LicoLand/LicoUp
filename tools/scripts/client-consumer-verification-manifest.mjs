#!/usr/bin/env node

import { lstatSync, readdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { CLIENT_RELEASE_TARGETS } from "./client-gate-policy.mjs";
import { androidApkSigningCertificateKeyId } from "./lib/android-apk-facts.mjs";
import { sha256File, stableReadFile } from "./lib/client-release-artifact-digest.mjs";
import {
  loadClientReleaseTargetCatalog,
  selectClientReleaseTargets,
} from "./lib/client-release-targets.mjs";

const MAX_CHECKSUM_BYTES = 4 * 1024;
const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const productVersion = JSON.parse(readFileSync(
  path.join(repoRoot, "tools/client-version.json"), "utf8",
)).productVersion;

function fail(message) { throw new Error(message); }

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined ||
      result[name.slice(2)] !== undefined) fail("invalid arguments");
    result[name.slice(2)] = value;
  }
  return result;
}

function selectedTargets(value) {
  const ids = String(value || "").split(",");
  if (ids.length === 0 || ids.some((id) => !id || id !== id.trim()) ||
    new Set(ids).size !== ids.length) fail("invalid target selection");
  const targets = selectClientReleaseTargets(loadClientReleaseTargetCatalog(), ids, {
    requireReleaseSupported: false,
  });
  if (targets.some((target) => !CLIENT_RELEASE_TARGETS[target.id])) {
    fail("target selection is not publishable");
  }
  return targets;
}

function containedFile(root, name) {
  if (path.basename(name) !== name || name.includes("..")) fail("invalid asset name");
  const resolved = path.resolve(root, name);
  const info = lstatSync(resolved, { throwIfNoEntry: false });
  if (path.dirname(resolved) !== root || !info?.isFile() || info.isSymbolicLink() ||
    realpathSync(resolved) !== resolved) fail(`missing regular release asset: ${name}`);
  return resolved;
}

function checksumFor(target, role) {
  const checksum = target.artifacts.find((artifact) =>
    artifact.role === "checksum" && artifact.for === role);
  if (!checksum) fail(`target ${target.id} is missing checksum for ${role}`);
  return checksum;
}

function artifactRecord(root, target, artifact) {
  const artifactPath = containedFile(root, artifact.file);
  const digest = sha256File(artifactPath).slice("sha256:".length);
  const checksum = checksumFor(target, artifact.role);
  const checksumPath = containedFile(root, checksum.file);
  if (stableReadFile(checksumPath, { maxBytes: MAX_CHECKSUM_BYTES }).toString("utf8") !==
    `${digest}  ${artifact.file}\n`) {
    fail(`checksum mismatch: ${artifact.file}`);
  }
  const verification = { checksum: checksum.file, algorithm: "SHA-256" };
  if (target.platform === "android" && artifact.role === "installer") {
    verification.signatureAlgorithm = "APK Signature Scheme v2+";
    verification.keyId = androidApkSigningCertificateKeyId(artifactPath);
  }
  return {
    name: artifact.file,
    version: productVersion,
    targetId: target.id,
    role: artifact.role,
    platform: target.platform,
    channel: target.channel,
    packageFormat: target.packageFormat,
    architecture: target.arch,
    byteSize: statSync(artifactPath).size,
    sha256: digest,
    verification,
  };
}

function main() {
  if (typeof productVersion !== "string" || productVersion.length === 0) {
    fail("client product version is missing");
  }
  const args = parseArgs(process.argv.slice(2));
  const assetsRoot = realpathSync(path.resolve(repoRoot, args.assets || ""));
  const requestedOutputPath = path.resolve(repoRoot, args.output || "");
  if (realpathSync(path.dirname(requestedOutputPath)) !== assetsRoot ||
    path.basename(requestedOutputPath) !== "LicoUp-consumer-verification.json") {
    fail("manifest must be written beside release assets");
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,126}$/u.test(args.tag || "")) {
    fail("invalid release tag");
  }
  const targets = selectedTargets(args.targets);
  const expectedFiles = targets.flatMap((target) =>
    CLIENT_RELEASE_TARGETS[target.id].files).sort();
  const actualEntries = readdirSync(assetsRoot, { withFileTypes: true });
  if (actualEntries.some((entry) => !entry.isFile() || entry.isSymbolicLink()) ||
    JSON.stringify(actualEntries.map((entry) => entry.name).sort()) !==
      JSON.stringify(expectedFiles)) {
    fail("release asset set does not exactly match selected targets");
  }
  const artifacts = targets.flatMap((target) => target.artifacts
    .filter((artifact) => ["installer", "update", "submission"].includes(artifact.role))
    .map((artifact) => artifactRecord(assetsRoot, target, artifact)));
  const packages = targets.map((target) => {
    const manifest = `LicoUp-${target.id}.package.json`;
    const manifestPath = containedFile(assetsRoot, manifest);
    return {
      targetId: target.id,
      manifest,
      byteSize: statSync(manifestPath).size,
      sha256: sha256File(manifestPath).slice("sha256:".length),
    };
  });
  const manifest = {
    schemaVersion: "licomesh.consumer-verification-manifest.v3",
    artifactName: "LicoUp",
    releaseTag: args.tag,
    targets: targets.map((target) => target.id),
    packages,
    artifacts,
  };
  writeFileSync(path.join(assetsRoot, "LicoUp-consumer-verification.json"),
    `${JSON.stringify(manifest, null, 2)}\n`, {
      encoding: "utf8", mode: 0o644, flag: "wx",
    });
  process.stdout.write(`${JSON.stringify({ ok: true,
    targetCount: targets.length, artifactCount: artifacts.length })}\n`);
}

main();
