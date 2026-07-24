#!/usr/bin/env node

import { createHash, createPublicKey, verify, X509Certificate } from "node:crypto";
import { existsSync, lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
} from "./lib/client-source-state-digest.mjs";
import { atomicWriteReportJson } from "./lib/safe-report-io.mjs";
import { sha256File } from "./lib/client-release-artifact-digest.mjs";
import {
  androidApkSignerIdentityKeyId,
  inspectAndroidApkFacts,
} from "./lib/android-apk-facts.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const buildRoot = path.join(repoRoot, "build");
const digestPattern = /^[a-f0-9]{64}$/u;
const specs = {
  "macos-arm64": {
    artifact: "build/apps/desktop/distribution/macos/LicoUp-macos-arm64.zip",
    checksum: "build/apps/desktop/distribution/macos/LicoUp-macos-arm64.zip.sha256",
    manifest: "build/apps/desktop/distribution/macos/manifest.json",
    platform: "macos",
    architecture: "arm64",
  },
  "android-arm64": {
    artifact: "build/apps/desktop/android/release/app-release.apk",
    publishedArtifact: "build/apps/desktop/android/release/LicoUp-android-arm64.apk",
    checksum: "build/apps/desktop/android/release/LicoUp-android-arm64.apk.sha256",
    manifest: "build/apps/desktop/android/release/build-manifest.json",
    publicKey: "build/apps/desktop/android/release/lico-github-artifact.pem",
    platform: "android",
    architecture: "arm64-v8a",
  },
  "linux-glibc-arm64": {
    artifact: "build/apps/desktop/distribution/linux-arm64/LicoUp-linux-arm64.tar.gz",
    checksum: "build/apps/desktop/distribution/linux-arm64/LicoUp-linux-arm64.tar.gz.sha256",
    signature: "build/apps/desktop/distribution/linux-arm64/LicoUp-linux-arm64.tar.gz.sig",
    publicKey: "build/apps/desktop/distribution/linux-arm64/linux-release-verification-key.pem",
    manifest: "build/apps/desktop/distribution/linux-arm64/manifest.json",
    platform: "linux",
    architecture: "arm64",
  },
};

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function regularPath(ref, maxBytes = 1024 * 1024 * 1024) {
  const resolved = path.resolve(repoRoot, ref);
  if (!resolved.startsWith(`${buildRoot}${path.sep}`) || !existsSync(resolved)) {
    throw new Error("release artifact missing");
  }
  const linkStats = lstatSync(resolved);
  const canonical = realpathSync(resolved);
  const stats = statSync(canonical);
  if (linkStats.isSymbolicLink() || canonical !== resolved || !stats.isFile() ||
    stats.size <= 0 || stats.size > maxBytes) {
    throw new Error("release artifact bounds invalid");
  }
  return canonical;
}

function readRegular(ref, maxBytes = 16 * 1024 * 1024) {
  return readFileSync(regularPath(ref, maxBytes));
}

function json(ref) {
  return JSON.parse(readRegular(ref, 16 * 1024 * 1024).toString("utf8"));
}

function selectedTargetIds() {
  const ids = String(process.env.LICO_CLIENT_RELEASE_TARGETS || "")
    .split(",").map((value) => value.trim()).filter(Boolean);
  if (ids.length === 0 || ids.length !== new Set(ids).size || ids.some((id) => !specs[id])) {
    throw new Error("release target selection invalid");
  }
  return Object.keys(specs).filter((id) => ids.includes(id));
}

function verifyChecksum(spec, artifactDigest) {
  const artifactName = path.basename(spec.publishedArtifact || spec.artifact);
  const expected = `${artifactDigest}  ${artifactName}\n`;
  return readRegular(spec.checksum, 4096).toString("utf8") === expected;
}

function verifyLinuxSignature(spec, manifest, digest) {
  const keyBytes = readRegular(spec.publicKey, 64 * 1024);
  const key = createPublicKey(keyBytes);
  const spki = key.export({ type: "spki", format: "der" });
  const signatureText = readRegular(spec.signature, 4096).toString("utf8").trim();
  const signature = Buffer.from(signatureText, "base64");
  return key.asymmetricKeyType === "ed25519" && signature.length === 64 &&
    manifest.signature?.algorithm === "Ed25519" &&
    manifest.signature?.payload === "archive-sha256-digest" &&
    manifest.signature?.keyId === "linux-vm-acceptance" &&
    manifest.signature?.file === path.basename(spec.signature) &&
    manifest.signature?.publicKeySpkiBase64 === spki.toString("base64") &&
    manifest.signature?.publicKeyFingerprint === `sha256:${sha256(spki)}` &&
    verify(null, Buffer.from(digest, "hex"), key, signature);
}

function validateTarget(targetId, clientVersion, sourceStateDigest) {
  const spec = specs[targetId];
  const artifactPath = regularPath(spec.artifact);
  const artifactDigest = sha256File(artifactPath, { maxBytes: 1024 * 1024 * 1024 })
    .slice("sha256:".length);
  const artifactSize = statSync(artifactPath).size;
  const manifest = json(spec.manifest);
  const commonReady = manifest.productVersion === clientVersion.productVersion &&
    manifest.buildNumber === clientVersion.buildNumber &&
    manifest.sourceStateDigest === sourceStateDigest;
  let buildReady = false;
  let publicVerificationReady = verifyChecksum(spec, artifactDigest);
  if (targetId === "macos-arm64") {
    buildReady = manifest.targetId === targetId && manifest.platform === spec.platform &&
      manifest.architecture === spec.architecture && manifest.sha256 === artifactDigest &&
      manifest.archive === path.basename(spec.artifact) && manifest.artifactReady === true;
  } else if (targetId === "android-arm64") {
    const publishedPath = regularPath(spec.publishedArtifact);
    const publishedDigest = sha256File(publishedPath, { maxBytes: 1024 * 1024 * 1024 })
      .slice("sha256:".length);
    const certificate = readRegular(spec.publicKey, 64 * 1024).toString("utf8");
    const publishedFacts = inspectAndroidApkFacts(
      repoRoot,
      path.join(repoRoot, spec.publishedArtifact),
      { requireApprovedToolchain: true },
    );
    const signerKeyId = androidApkSignerIdentityKeyId(publishedFacts);
    const certificateKeyId = `sha256:${sha256(new X509Certificate(certificate).raw)}`;
    buildReady = artifactDigest === publishedDigest &&
      manifest.targetId === targetId && manifest.mode === "release" &&
      manifest.productVersion === clientVersion.productVersion &&
      manifest.buildNumber === clientVersion.buildNumber &&
      manifest.artifact?.digest === `sha256:${artifactDigest}` &&
      manifest.reproducibility?.buildCount === 2 &&
      manifest.reproducibility?.cleanBuilds === true &&
      manifest.reproducibility?.sameSourceState === true &&
      manifest.reproducibility?.sameFinalArtifactDigest === true &&
      manifest.reproducibility?.reproducibleUnsignedPayload === true &&
      manifest.reproducibility?.stableSigningBlockSize === true &&
      manifest.reproducibility?.binaryFactsEqual === true &&
      manifest.reproducibility?.ready === true &&
      manifest.signerIdentityVerified === true && manifest.signingPolicySatisfied === true &&
      manifest.publicVerificationKeyId === signerKeyId &&
      certificateKeyId === signerKeyId &&
      publishedFacts.artifactDigest === `sha256:${artifactDigest}` &&
      publishedFacts.packageName === "land.lico.licoup" &&
      publishedFacts.versionName === clientVersion.productVersion &&
      publishedFacts.versionCode === String(clientVersion.buildNumber) &&
      publishedFacts.debuggable === false &&
      Array.isArray(manifest.abis) &&
      JSON.stringify(manifest.abis) === JSON.stringify([spec.architecture]) &&
      certificate.includes("-----BEGIN CERTIFICATE-----") &&
      certificate.includes("-----END CERTIFICATE-----");
    publicVerificationReady = publicVerificationReady && buildReady;
  } else {
    buildReady = manifest.targetId === targetId && manifest.platform === spec.platform &&
      manifest.architecture === spec.architecture && manifest.sha256 === artifactDigest &&
      manifest.archive === path.basename(spec.artifact) && manifest.artifactReady === true;
    publicVerificationReady = publicVerificationReady &&
      verifyLinuxSignature(spec, manifest, artifactDigest);
  }
  const blockers = [];
  if (!commonReady) blockers.push("artifact_source_or_version_binding_not_ready");
  if (!buildReady) blockers.push("artifact_build_contract_not_ready");
  if (!publicVerificationReady) blockers.push("consumer_verification_metadata_not_ready");
  return {
    targetId,
    ready: blockers.length === 0,
    artifact: path.basename(spec.publishedArtifact || spec.artifact),
    sha256: artifactDigest,
    byteSize: artifactSize,
    blockers,
  };
}

function main() {
  const targetCatalog = JSON.parse(
    readFileSync(path.join(repoRoot, "tools/client-release-targets.json"), "utf8"),
  );
  const selected = selectedTargetIds();
  const authorized = targetCatalog.targets
    .filter((target) => target.releaseSupported === true).map((target) => target.id);
  if (selected.some((id) => !authorized.includes(id))) throw new Error("unsupported release target");
  const clientVersion = JSON.parse(readFileSync(path.join(repoRoot, "tools/client-version.json"), "utf8"));
  const sourceStateDigest = clientSourceStateDigest(repoRoot, CANONICAL_CLIENT_SOURCE_ROOTS);
  const targets = selected.map((id) => validateTarget(id, clientVersion, sourceStateDigest));
  const blockers = targets.flatMap((target) => target.blockers.map((item) => `${target.targetId}:${item}`));
  const report = {
    schemaVersion: "licomesh.client-github-release-acceptance.v1",
    generatedAt: new Date().toISOString(),
    productVersion: clientVersion.productVersion,
    sourceStateDigest,
    selectedTargetIds: selected,
    githubReleaseReady: blockers.length === 0,
    targets,
    blockers,
    productLineSecurity: {
      blocking: false,
      gate: "npm run client:verify:product-line-security",
      status: "separate-evidence-domain",
    },
  };
  atomicWriteReportJson(buildRoot, "reports/client-github-release-acceptance.json", report);
  console.log(JSON.stringify({ ok: report.githubReleaseReady, selectedTargetIds: selected, blockerCount: blockers.length }));
  if (!report.githubReleaseReady) process.exitCode = 1;
}

try {
  main();
} catch {
  console.error(JSON.stringify({ ok: false, error: "client_github_release_acceptance_failed" }));
  process.exitCode = 1;
}
