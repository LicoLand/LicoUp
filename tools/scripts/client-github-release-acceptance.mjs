#!/usr/bin/env node

import { createHash, X509Certificate } from "node:crypto";
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
import {
  loadClientReleaseTargetCatalog,
  selectClientReleaseTargets,
} from "./lib/client-release-targets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const buildRoot = path.join(repoRoot, "build");
const digestPattern = /^[a-f0-9]{64}$/u;
const specs = {
  "macos-direct-arm64": {
    artifact: "build/apps/desktop/distribution/macos/LicoUp-macos-arm64.dmg",
    checksum: "build/apps/desktop/distribution/macos/LicoUp-macos-arm64.dmg.sha256",
    manifest: "build/apps/desktop/distribution/macos/manifest.json",
    platform: "macos",
    architecture: "arm64",
  },
  "android-direct-arm64-v8a": {
    artifact: "build/apps/desktop/android/release/app-release.apk",
    publishedArtifact: "build/apps/desktop/android/release/LicoUp-android-arm64.apk",
    checksum: "build/apps/desktop/android/release/LicoUp-android-arm64.apk.sha256",
    manifest: "build/apps/desktop/android/release/build-manifest.json",
    publicKey: "build/apps/desktop/android/release/lico-github-artifact.pem",
    platform: "android",
    architecture: "arm64-v8a",
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
  if (ids.length === 0 || ids.length !== new Set(ids).size) {
    throw new Error("release target selection invalid");
  }
  return selectClientReleaseTargets(loadClientReleaseTargetCatalog(), ids, {
    requireReleaseSupported: true,
  });
}

function verifyChecksum(spec, artifactDigest) {
  const artifactName = path.basename(spec.publishedArtifact || spec.artifact);
  const expected = `${artifactDigest}  ${artifactName}\n`;
  return readRegular(spec.checksum, 4096).toString("utf8") === expected;
}

function validateTarget(target, clientVersion, sourceStateDigest) {
  const spec = specs[target.id];
  if (!spec) throw new Error("release target validator missing");
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
  if (target.platform === "macos") {
    buildReady = manifest.targetId === target.runtimeTargetId && manifest.platform === spec.platform &&
      manifest.architecture === spec.architecture && manifest.sha256 === artifactDigest &&
      manifest.archive === path.basename(spec.artifact) && manifest.artifactReady === true;
  } else if (target.platform === "android") {
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
      manifest.targetId === target.runtimeTargetId && manifest.mode === "release" &&
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
  }
  const blockers = [];
  if (!commonReady) blockers.push("artifact_source_or_version_binding_not_ready");
  if (!buildReady) blockers.push("artifact_build_contract_not_ready");
  if (!publicVerificationReady) blockers.push("consumer_verification_metadata_not_ready");
  return {
    targetId: target.id,
    ready: blockers.length === 0,
    artifact: path.basename(spec.publishedArtifact || spec.artifact),
    sha256: artifactDigest,
    byteSize: artifactSize,
    blockers,
  };
}

function main() {
  const selected = selectedTargetIds();
  const clientVersion = JSON.parse(readFileSync(path.join(repoRoot, "tools/client-version.json"), "utf8"));
  const sourceStateDigest = clientSourceStateDigest(repoRoot, CANONICAL_CLIENT_SOURCE_ROOTS);
  const targets = selected.map((target) => validateTarget(target, clientVersion, sourceStateDigest));
  const blockers = targets.flatMap((target) => target.blockers.map((item) => `${target.targetId}:${item}`));
  const report = {
    schemaVersion: "licomesh.client-github-release-acceptance.v1",
    generatedAt: new Date().toISOString(),
    productVersion: clientVersion.productVersion,
    sourceStateDigest,
    selectedTargetIds: selected.map((target) => target.id),
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
  console.log(JSON.stringify({ ok: report.githubReleaseReady, selectedTargetIds: report.selectedTargetIds, blockerCount: blockers.length }));
  if (!report.githubReleaseReady) process.exitCode = 1;
}

try {
  main();
} catch {
  console.error(JSON.stringify({ ok: false, error: "client_github_release_acceptance_failed" }));
  process.exitCode = 1;
}
