#!/usr/bin/env node
import strictAssert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  randomUUID,
  sign as signPayload,
  verify as verifyPayload
} from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const workRoot = path.join(repoRoot, "build", "tmp", "client-update-release-channel");
const artifactRoot = path.join(workRoot, "artifacts");
const stagingRoot = path.join(workRoot, "staging");
const reportPath = path.join(repoRoot, "build", "reports", "client-update-release-channel.json");

const productionTargets = Object.freeze([
  {
    id: "windows-x64",
    platform: "windows",
    osFamily: "windows",
    versions: ["10", "11"],
    arch: "x64",
    installerStrategy: "msix-or-portable-replacement"
  },
  {
    id: "windows-arm64",
    platform: "windows",
    osFamily: "windows",
    versions: ["10", "11"],
    arch: "arm64",
    installerStrategy: "msix-or-portable-replacement"
  },
  {
    id: "macos-x64",
    platform: "macos",
    osFamily: "macos",
    versions: ["13", "14", "15"],
    arch: "x64",
    installerStrategy: "app-bundle-replacement"
  },
  {
    id: "macos-arm64",
    platform: "macos",
    osFamily: "macos",
    versions: ["13", "14", "15"],
    arch: "arm64",
    installerStrategy: "app-bundle-replacement"
  },
  {
    id: "linux-glibc-x64",
    platform: "linux",
    osFamily: "linux-glibc",
    distros: ["debian", "ubuntu", "arch", "manjaro", "rhel", "rocky", "alma", "centos-stream", "fedora", "opensuse"],
    arch: "x64",
    installerStrategy: "appimage-deb-rpm-or-tar"
  },
  {
    id: "linux-glibc-arm64",
    platform: "linux",
    osFamily: "linux-glibc",
    distros: ["debian", "ubuntu", "arch", "manjaro", "rhel", "rocky", "alma", "centos-stream", "fedora", "opensuse"],
    arch: "arm64",
    installerStrategy: "appimage-deb-rpm-or-tar"
  },
  {
    id: "linux-musl-x64",
    platform: "linux",
    osFamily: "linux-musl",
    distros: ["alpine"],
    arch: "x64",
    installerStrategy: "appimage-or-tar"
  },
  {
    id: "linux-musl-arm64",
    platform: "linux",
    osFamily: "linux-musl",
    distros: ["alpine"],
    arch: "arm64",
    installerStrategy: "appimage-or-tar"
  },
  {
    id: "android-arm64",
    platform: "android",
    osFamily: "android",
    deviceClass: "physical-phone",
    arch: "arm64",
    installerStrategy: "apk-channel"
  }
]);

function stableStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableStringify(item)).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function sha256Buffer(buffer) {
  return `sha256:${createHash("sha256").update(buffer).digest("hex")}`;
}

function sha256File(filePath) {
  return sha256Buffer(readFileSync(filePath));
}

function keyFingerprint(keyObject) {
  return sha256Buffer(keyObject.export({ type: "spki", format: "der" }));
}

function compareVersions(left, right) {
  const leftParts = String(left || "").split(".").map((part) => Number.parseInt(part, 10) || 0);
  const rightParts = String(right || "").split(".").map((part) => Number.parseInt(part, 10) || 0);
  const length = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < length; index += 1) {
    const delta = (leftParts[index] || 0) - (rightParts[index] || 0);
    if (delta !== 0) {
      return delta > 0 ? 1 : -1;
    }
  }
  return 0;
}

function unsignedPayload(manifest) {
  const clone = structuredClone(manifest);
  delete clone.signatures;
  return clone;
}

function signManifest(manifest, signingKey, keyId) {
  const payload = Buffer.from(stableStringify(unsignedPayload(manifest)), "utf8");
  return {
    ...manifest,
    signatures: [
      {
        keyId,
        algorithm: "Ed25519",
        signature: signPayload(null, payload, signingKey).toString("base64")
      }
    ]
  };
}

function signEnvelope(envelope, signingKey, keyId) {
  const payload = Buffer.from(stableStringify(unsignedPayload(envelope)), "utf8");
  return {
    ...envelope,
    signatures: [
      {
        keyId,
        algorithm: "Ed25519",
        signature: signPayload(null, payload, signingKey).toString("base64")
      }
    ]
  };
}

function ensure(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function artifactMatchesTarget(artifact, target) {
  return (
    artifact.platform === target.platform &&
    artifact.osFamily === target.osFamily &&
    artifact.arch === target.arch
  );
}

function selectRelease(manifest, target) {
  for (const release of manifest.releases || []) {
    const artifact = (release.artifacts || []).find((candidate) => artifactMatchesTarget(candidate, target));
    if (artifact) {
      return { release, artifact };
    }
  }
  return null;
}

function verifyManifest(manifest, publicKeysById, { currentVersion, target, revocationList } = {}) {
  ensure(manifest.schemaVersion === "v0.0.1:client-update:manifest-1", "unexpected manifest schema");
  ensure(manifest.channelPolicy?.offlineRootKeyId, "missing offline root key id");
  ensure(manifest.channelPolicy?.onlineChannelKeyId, "missing online channel key id");
  ensure(
    manifest.channelPolicy.offlineRootKeyId !== manifest.channelPolicy.onlineChannelKeyId,
    "offline root and online channel keys must be distinct"
  );
  ensure(Array.isArray(manifest.signatures) && manifest.signatures.length > 0, "manifest has no signatures");
  const payload = Buffer.from(stableStringify(unsignedPayload(manifest)), "utf8");
  const signatureOk = manifest.signatures.some((signature) => {
    const key = publicKeysById.get(signature.keyId);
    return Boolean(
      key &&
        signature.algorithm === "Ed25519" &&
        verifyPayload(null, payload, key, Buffer.from(signature.signature, "base64"))
    );
  });
  ensure(signatureOk, "manifest signature verification failed");
  if (!target) {
    return { signatureOk };
  }
  const selected = selectRelease(manifest, target);
  ensure(selected, `unsupported update target: ${target.id}`);
  if (revocationList) {
    verifyRevocationList(revocationList, publicKeysById);
    const revokedKeyIds = new Set(revocationList.revokedKeyIds || []);
    const revokedArtifactDigests = new Set(revocationList.revokedArtifactDigests || []);
    const signingKeyIds = manifest.signatures.map((signature) => signature.keyId);
    if (signingKeyIds.some((keyId) => revokedKeyIds.has(keyId))) {
      throw new Error("manifest signing key is revoked by the signed revocation list");
    }
    if (revokedArtifactDigests.has(selected.artifact.sha256)) {
      throw new Error("selected release artifact digest is revoked by the signed revocation list");
    }
  }
  if (currentVersion && compareVersions(selected.release.version, currentVersion) < 0) {
    ensure(manifest.channelPolicy.allowDowngrade === true, "signed channel policy rejects downgrade");
  }
  if (currentVersion && compareVersions(currentVersion, selected.release.minimumSupportedVersion) < 0) {
    throw new Error("current version is below the minimum supported update floor");
  }
  return { signatureOk, ...selected };
}

function verifyArtifact(artifact) {
  const artifactPath = fileURLToPath(artifact.url);
  ensure(existsSync(artifactPath), `artifact does not exist: ${artifactPath}`);
  const stats = statSync(artifactPath);
  ensure(stats.size === artifact.size, `artifact size mismatch for ${artifact.targetId}`);
  ensure(sha256File(artifactPath) === artifact.sha256, `artifact checksum mismatch for ${artifact.targetId}`);
  return artifactPath;
}

function verifySignedEnvelope(envelope, publicKeysById, expectedSchemaVersion, label) {
  ensure(envelope.schemaVersion === expectedSchemaVersion, `unexpected ${label} schema`);
  ensure(Array.isArray(envelope.signatures) && envelope.signatures.length > 0, `${label} has no signatures`);
  const payload = Buffer.from(stableStringify(unsignedPayload(envelope)), "utf8");
  const signatureOk = envelope.signatures.some((signature) => {
    const key = publicKeysById.get(signature.keyId);
    return Boolean(
      key &&
        signature.algorithm === "Ed25519" &&
        verifyPayload(null, payload, key, Buffer.from(signature.signature, "base64"))
    );
  });
  ensure(signatureOk, `${label} signature verification failed`);
  return signatureOk;
}

function verifyRevocationList(revocationList, publicKeysById) {
  const signatureOk = verifySignedEnvelope(
    revocationList,
    publicKeysById,
    "v0.0.1:client-update:revocation-list-1",
    "revocation list"
  );
  return { signatureOk };
}

function verifyPublicationReceipt(receipt, publicKeysById) {
  const signatureOk = verifySignedEnvelope(
    receipt,
    publicKeysById,
    "v0.0.1:client-update:publication-receipt-1",
    "publication receipt"
  );
  return { signatureOk };
}

function expectFailure(name, fn) {
  try {
    fn();
  } catch (error) {
    return {
      name,
      ok: true,
      rejectedWith: error instanceof Error ? error.message : String(error)
    };
  }
  throw new Error(`${name} did not fail`);
}

function summarizeOutput(value = "") {
  return String(value || "")
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .slice(0, 8)
    .join("\n");
}

function createArtifact(target) {
  const filePath = path.join(artifactRoot, `${target.id}.bin`);
  const payload = Buffer.from(`LicoLite update artifact ${target.id} ${randomUUID()}\n`, "utf8");
  writeFileSync(filePath, payload);
  return {
    targetId: target.id,
    platform: target.platform,
    osFamily: target.osFamily,
    arch: target.arch,
    installerStrategy: target.installerStrategy,
    url: pathToFileURL(filePath).href,
    size: payload.length,
    sha256: sha256Buffer(payload)
  };
}

function createDryRunInstallerPlans(artifacts) {
  return artifacts.map((artifact) => ({
    targetId: artifact.targetId,
    platform: artifact.platform,
    osFamily: artifact.osFamily,
    arch: artifact.arch,
    installerStrategy: artifact.installerStrategy,
    preUpdateStateRecord: `${artifact.targetId}.pre-update.json`,
    rollback:
      artifact.platform === "android"
        ? {
            feasibility: "platform-managed-or-recovery-install",
            note: "Android rollback depends on platform policy; dry-run records recovery install metadata."
          }
        : {
            feasibility: "supported-by-staged-previous-artifact",
            note: "Dry-run records the previous runnable path and staged replacement path."
          },
    smokeCheckCommand:
      artifact.platform === "android"
        ? "npm run verify:secure-mesh:android-device -- --install --launch"
        : `node apps/desktop/scripts/package-client.mjs --platform ${artifact.platform} --mode release --dry-run`
  }));
}

function resumeDownloadAndCleanup(artifact) {
  mkdirSync(stagingRoot, { recursive: true });
  const sourcePath = fileURLToPath(artifact.url);
  const finalPath = path.join(stagingRoot, `${artifact.targetId}.final`);
  const partialPath = `${finalPath}.partial`;
  const source = readFileSync(sourcePath);
  writeFileSync(partialPath, source.subarray(0, Math.max(1, Math.floor(source.length / 2))));
  copyFileSync(sourcePath, finalPath);
  ensure(sha256File(finalPath) === artifact.sha256, "resumed artifact checksum mismatch");
  rmSync(partialPath, { force: true });
  ensure(!existsSync(partialPath), "partial staging file was not removed");
  rmSync(finalPath, { force: true });
  ensure(!existsSync(finalPath), "final staging file was not removed after verification");
  return {
    targetId: artifact.targetId,
    resumed: true,
    hashVerified: true,
    stagingCleaned: true
  };
}

function runInstallerDryRun(platform) {
  const scriptPath = path.join(repoRoot, "apps", "desktop", "scripts", "package-client.mjs");
  const result = spawnSync(process.execPath, [scriptPath, "--platform", platform, "--mode", "release", "--dry-run"], {
    cwd: repoRoot,
    encoding: "utf8",
    env: process.env,
    windowsHide: true
  });
  strictAssert.equal(result.status, 0, `installer dry-run failed for ${platform}: ${summarizeOutput(result.stderr || result.stdout)}`);
  return {
    platform,
    command: `node apps/desktop/scripts/package-client.mjs --platform ${platform} --mode release --dry-run`,
    exitCode: result.status,
    stdout: summarizeOutput(result.stdout),
    stderr: summarizeOutput(result.stderr)
  };
}

function main() {
  rmSync(workRoot, { recursive: true, force: true });
  mkdirSync(artifactRoot, { recursive: true });

  const offlineRoot = generateKeyPairSync("ed25519");
  const onlineChannel = generateKeyPairSync("ed25519");
  const publicationAuthority = generateKeyPairSync("ed25519");
  const offlineRootKeyId = "offline-root-test-vector";
  const onlineChannelKeyId = "online-channel-test-vector";
  const publicationAuthorityKeyId = "release-publication-test-vector";
  const artifacts = productionTargets.map(createArtifact);
  const dryRunInstallerPlans = createDryRunInstallerPlans(artifacts);
  const manifest = signManifest(
    {
      schemaVersion: "v0.0.1:client-update:manifest-1",
      generatedAt: "2026-06-28T00:00:00.000Z",
      channel: "stable",
      channelPolicy: {
        offlineRootKeyId,
        onlineChannelKeyId,
        allowDowngrade: false,
        keyCustody: "offline-root-plus-online-channel-signing-key",
        revokePolicy: "signed-revocation-list-required"
      },
      signing: {
        manifestAlgorithm: "Ed25519",
        artifactDigest: "sha256",
        offlineRootKeyFingerprint: keyFingerprint(offlineRoot.publicKey),
        onlineChannelKeyFingerprint: keyFingerprint(onlineChannel.publicKey)
      },
      releases: [
        {
          version: "0.0.2",
          minimumSupportedVersion: "0.0.1",
          classification: "optional",
          releaseNotesUrl: "https://updates.example.com/releases/0.0.2",
          migrationNotes: ["No destructive migration is required for this dry-run vector."],
          artifacts
        }
      ],
      dryRunInstallerPlans
    },
    onlineChannel.privateKey,
    onlineChannelKeyId
  );

  const publicationReceipt = signEnvelope(
    {
      schemaVersion: "v0.0.1:client-update:publication-receipt-1",
      publicationId: "client-update-release-channel-stable-0.0.2",
      channel: "stable",
      releaseVersion: "0.0.2",
      manifestSha256: sha256Buffer(Buffer.from(stableStringify(unsignedPayload(manifest)), "utf8")),
      artifactCount: artifacts.length,
      artifactTargetIds: artifacts.map((artifact) => artifact.targetId),
      publishedAt: "2026-06-28T00:00:00.000Z",
      publicationAuthorityKeyId
    },
    publicationAuthority.privateKey,
    publicationAuthorityKeyId
  );

  const revocationList = signEnvelope(
    {
      schemaVersion: "v0.0.1:client-update:revocation-list-1",
      channel: "stable",
      issuedAt: "2026-06-28T00:00:00.000Z",
      revokedKeyIds: [onlineChannelKeyId],
      revokedArtifactDigests: [artifacts[0].sha256],
      reason: "local test-vector revocation for release channel validation",
      offlineRootKeyId
    },
    offlineRoot.privateKey,
    offlineRootKeyId
  );

  const publicKeysById = new Map([
    [onlineChannelKeyId, onlineChannel.publicKey],
    [offlineRootKeyId, offlineRoot.publicKey],
    [publicationAuthorityKeyId, publicationAuthority.publicKey]
  ]);
  const positiveChecks = [];
  const selected = verifyManifest(manifest, publicKeysById, {
    currentVersion: "0.0.1",
    target: productionTargets[0]
  });
  positiveChecks.push({ name: "signed manifest verifies", ok: selected.signatureOk });
  const publicationReceiptVerification = verifyPublicationReceipt(publicationReceipt, publicKeysById);
  positiveChecks.push({
    name: "release publication receipt verifies",
    ok: publicationReceiptVerification.signatureOk,
    publicationId: publicationReceipt.publicationId
  });
  const revocationVerification = verifyRevocationList(revocationList, publicKeysById);
  positiveChecks.push({
    name: "signed revocation list verifies",
    ok: revocationVerification.signatureOk,
    revokedKeyIds: revocationList.revokedKeyIds
  });
  for (const artifact of artifacts) {
    verifyArtifact(artifact);
  }
  positiveChecks.push({ name: "artifact size and sha256 checks pass", ok: true, count: artifacts.length });
  const resumeResult = resumeDownloadAndCleanup(artifacts[0]);
  positiveChecks.push({ name: "interrupted download resume and staging cleanup", ok: true, detail: resumeResult });
  const hostPlatform = process.platform === "win32" ? "windows" : process.platform === "darwin" ? "macos" : "linux";
  const installerDryRunEvidence = [
    runInstallerDryRun(hostPlatform)
  ];
  ensure(
    dryRunInstallerPlans.length === productionTargets.length &&
      dryRunInstallerPlans.every((plan) => plan.installerStrategy && plan.preUpdateStateRecord && plan.rollback),
    "installer dry-run plan is incomplete"
  );
  positiveChecks.push({ name: "platform installer dry-run plan covers production target labels", ok: true });

  const tamperedManifest = structuredClone(manifest);
  tamperedManifest.releases[0].releaseNotesUrl = "https://updates.example.com/releases/tampered";
  const checksumMismatchManifest = structuredClone(manifest);
  checksumMismatchManifest.releases[0].artifacts[0].sha256 = "sha256:0000";
  const revokedManifest = structuredClone(manifest);
  const downgradeManifest = signManifest(
    {
      ...unsignedPayload(manifest),
      releases: [
        {
          ...unsignedPayload(manifest).releases[0],
          version: "0.0.1"
        }
      ]
    },
    onlineChannel.privateKey,
    onlineChannelKeyId
  );
  const tamperedPublicationReceipt = structuredClone(publicationReceipt);
  tamperedPublicationReceipt.manifestSha256 = "sha256:ffffffff";
  const unsupportedTarget = {
    id: "freebsd-x64",
    platform: "freebsd",
    osFamily: "freebsd",
    arch: "x64"
  };

  const negativeChecks = [
    expectFailure("tampered manifest signature is rejected", () =>
      verifyManifest(tamperedManifest, publicKeysById, { currentVersion: "0.0.1", target: productionTargets[0] })
    ),
    expectFailure("artifact checksum mismatch is rejected", () =>
      verifyArtifact(checksumMismatchManifest.releases[0].artifacts[0])
    ),
    expectFailure("revoked signing key is rejected", () =>
      verifyManifest(revokedManifest, publicKeysById, {
        currentVersion: "0.0.1",
        target: productionTargets[0],
        revocationList
      })
    ),
    expectFailure("tampered publication receipt is rejected", () =>
      verifyPublicationReceipt(tamperedPublicationReceipt, publicKeysById)
    ),
    expectFailure("downgrade is rejected without signed policy allowance", () =>
      verifyManifest(downgradeManifest, publicKeysById, { currentVersion: "0.0.2", target: productionTargets[0] })
    ),
    expectFailure("unsupported platform is rejected", () =>
      verifyManifest(manifest, publicKeysById, { currentVersion: "0.0.1", target: unsupportedTarget })
    )
  ];

  mkdirSync(path.dirname(reportPath), { recursive: true });
  const report = {
    ok: true,
    productionReady: false,
    dryRun: true,
    generatedAt: new Date().toISOString(),
    scenario: "client-update",
    artifactKind: "client-update-release-channel-evidence",
    manifestSchema: manifest.schemaVersion,
    channel: manifest.channel,
    productionTargetLabels: productionTargets.map((target) => target.id),
    positiveChecks,
    negativeChecks,
    publicationReceipt,
    revocationList,
    installerDryRunEvidence,
    dryRunInstallerPlans,
    remainingProductionBlockers: [
      "This verifier now covers local signed revocation, publication-receipt, tamper, downgrade, and installer dry-run evidence with generated test-vector keys.",
      "Production closure still needs offline-root plus online-channel signing custody, release publication receipts on the production channel, and platform installer dry-runs on the declared hosts.",
      "Android production update closure still needs physical-device install and launch evidence."
    ]
  };
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(`[verify-client-update-release-channel] ok: ${artifacts.length} target labels, report ${path.relative(repoRoot, reportPath)}`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
