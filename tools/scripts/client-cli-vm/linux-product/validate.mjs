import { createHash, createPublicKey, verify } from "node:crypto";
import { existsSync } from "node:fs";
import path from "node:path";
import {
  sha256File as stableSha256File,
  stableReadFile,
} from "../../lib/client-release-artifact-digest.mjs";
import { requireReleaseCliTargetEvidence } from "../../lib/client-release-target-evidence.mjs";
import {
  validateLinuxNodeMatrixReport,
  validateLinuxVmPackageReceipt,
} from "../../lib/secure-mesh-linux-evidence.mjs";
import {
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
} from "../../lib/release-closure-challenge.mjs";
import { repoRoot } from "../constants.mjs";
import { linuxProductArtifactPaths } from "./artifacts.mjs";
import { verifyLinuxProductSourceManifest } from "./source-manifest.mjs";

export function decodeCanonicalBase64(value, label) {
  const encoded = String(value || "").trim();
  if (
    !encoded ||
    encoded.length > 16 * 1024 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(encoded)
  ) {
    throw new Error(`${label} is not canonical base64.`);
  }
  const bytes = Buffer.from(encoded, "base64");
  if (!bytes.length || bytes.toString("base64") !== encoded) {
    throw new Error(`${label} is not canonical base64.`);
  }
  return bytes;
}

export function verifyLinuxArchiveDigestSignature(distribution, signatureBytes, archiveDigest) {
  try {
    if (
      !/^sha256:[a-f0-9]{64}$/u.test(String(archiveDigest || "")) ||
      signatureBytes.length !== 64
    ) {
      return false;
    }
    const publicKeyDer = decodeCanonicalBase64(
      distribution.signature?.publicKeySpkiBase64,
      "Linux product public verification key",
    );
    const publicKey = createPublicKey({ key: publicKeyDer, type: "spki", format: "der" });
    if (publicKey.asymmetricKeyType !== "ed25519") return false;
    const fingerprint = `sha256:${createHash("sha256").update(publicKeyDer).digest("hex")}`;
    return (
      distribution.signature?.publicKeyFingerprint === fingerprint &&
      verify(
        null,
        Buffer.from(archiveDigest.slice("sha256:".length), "hex"),
        publicKey,
        signatureBytes,
      )
    );
  } catch {
    return false;
  }
}

export function validateLinuxProductArtifacts(distro, expectedSourceDigest, releaseBinding) {
  const artifacts = linuxProductArtifactPaths(distro);
  if (
    !existsSync(artifacts.vmReceipt) ||
    !existsSync(artifacts.nodeMatrix) ||
    !existsSync(artifacts.releaseCliProof) ||
    !existsSync(artifacts.archive) ||
    !existsSync(artifacts.signature) ||
    !existsSync(artifacts.distributionManifest) ||
    !existsSync(artifacts.sourceManifest)
  ) {
    throw new Error("Linux product acceptance artifacts are incomplete.");
  }
  verifyLinuxProductSourceManifest(distro, expectedSourceDigest);
  const receipt = JSON.parse(
    stableReadFile(artifacts.vmReceipt, { maxBytes: 2 * 1024 * 1024 }).toString("utf8"),
  );
  const nodeMatrix = JSON.parse(
    stableReadFile(artifacts.nodeMatrix, { maxBytes: 2 * 1024 * 1024 }).toString("utf8"),
  );
  const releaseCliProof = JSON.parse(
    stableReadFile(artifacts.releaseCliProof, { maxBytes: 2 * 1024 * 1024 }).toString("utf8"),
  );
  const distribution = JSON.parse(
    stableReadFile(artifacts.distributionManifest, {
      maxBytes: 2 * 1024 * 1024,
    }).toString("utf8"),
  );
  const clientVersion = JSON.parse(
    stableReadFile(path.join(repoRoot, "tools/client-version.json"), {
      maxBytes: 1024 * 1024,
    }).toString("utf8"),
  );
  validateLinuxVmPackageReceipt(
    receipt,
    expectedSourceDigest,
    clientVersion.productVersion,
    clientVersion.buildNumber,
  );
  validateLinuxNodeMatrixReport(nodeMatrix, expectedSourceDigest);
  requireReleaseCliTargetEvidence(releaseCliProof, {
    platform: "ubuntu-linux-arm64",
    sourceStateDigest: expectedSourceDigest,
    runtimeExecutableDigest: receipt.sourceBinding.nativeClientDigest,
  });
  const archiveDigest = stableSha256File(artifacts.archive);
  const signatureBytes = decodeCanonicalBase64(
    stableReadFile(artifacts.signature, { maxBytes: 16 * 1024 }).toString("utf8").trim(),
    "Linux product signature",
  );
  const directSignatureReady = verifyLinuxArchiveDigestSignature(
    distribution,
    signatureBytes,
    archiveDigest,
  );
  if (
    receipt.sourceBinding.archiveDigest !== archiveDigest ||
    nodeMatrix.sourceBinding.archiveDigest !== archiveDigest ||
    distribution.targetId !== "linux-glibc-arm64" ||
    distribution.sourceStateDigest !== expectedSourceDigest ||
    distribution.productVersion !== clientVersion.productVersion ||
    distribution.buildNumber !== clientVersion.buildNumber ||
    receipt.closureChallengeDigest !==
      releaseClosureChallengeDigest(releaseBinding.challenge) ||
    receipt.invocationNonceDigest !==
      releaseInvocationNonceDigest(releaseBinding.invocationNonce) ||
    releaseCliProof.closureChallengeDigest !==
      releaseClosureChallengeDigest(releaseBinding.challenge) ||
    releaseCliProof.invocationNonceDigest !==
      releaseInvocationNonceDigest(releaseBinding.invocationNonce) ||
    distribution.signature?.algorithm !== "Ed25519" ||
    distribution.signature?.payload !== "archive-sha256-digest" ||
    distribution.signature?.keyId !== "linux-vm-acceptance" ||
    distribution.signature?.file !== "LicoArc-linux-arm64.tar.gz.sig" ||
    distribution.sha256 !== archiveDigest.slice("sha256:".length) ||
    receipt.sourceBinding.bundleManifestDigest !== distribution.bundleManifestDigest ||
    nodeMatrix.sourceBinding.bundleManifestDigest !== distribution.bundleManifestDigest ||
    directSignatureReady !== true
  ) {
    throw new Error("Linux product artifact bindings are inconsistent.");
  }
}
