import { existsSync } from "node:fs";
import path from "node:path";
import {
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
  stableReadFile,
} from "../../lib/client-release-artifact-digest.mjs";
import { LINUX_TAR_RESOURCE_LIMITS } from "../../lib/linux-tar-resource-bounds.mjs";
import { maxJsonBytes, repoRoot, SHA256 } from "../constants.mjs";
import { sanitizeArtifactBinding } from "../sanitize-binding.mjs";
import { artifactFileByteLimit, requireValue, text } from "../util.mjs";
import { verifyArtifactReceipt } from "./receipt.mjs";
import {
  decodeCanonicalBase64,
  verifyLinuxArchiveDigestSignature,
} from "./linux-signature.mjs";

export function verifyLinuxArtifact(target, spec, clientVersion, receiptContext) {
  const productVersion = clientVersion.productVersion;
  const artifactPath = path.join(repoRoot, spec.ref);
  if (!existsSync(artifactPath)) {
    return sanitizeArtifactBinding({ targetId: target.id, artifactKind: spec.artifactKind });
  }
  const buildRoot = path.join(repoRoot, "build");
  const safeArtifactPath = resolveContainedExistingPath(buildRoot, artifactPath, {
    expectedKind: "file",
  });
  const artifactDigest = sha256File(safeArtifactPath, {
    maxBytes: artifactFileByteLimit(spec),
  });
  const manifestPath = resolveContainedExistingPath(
    buildRoot,
    path.join(repoRoot, spec.distributionManifestRef),
    { expectedKind: "file" },
  );
  const manifestSnapshot = stableReadFileSnapshot(manifestPath, {
    maxBytes: maxJsonBytes,
  });
  const distribution = JSON.parse(manifestSnapshot.bytes.toString("utf8"));
  const artifactManifestDigest = sha256Buffer(manifestSnapshot.bytes);
  const signaturePath = resolveContainedExistingPath(
    path.dirname(safeArtifactPath),
    `${safeArtifactPath}.sig`,
    { expectedKind: "file" },
  );
  const signatureEncoded = stableReadFile(signaturePath, {
    maxBytes: 16 * 1024,
  }).toString("utf8").trim();
  const signatureBytes = decodeCanonicalBase64(signatureEncoded);
  const receipt = verifyArtifactReceipt(
    receiptContext,
    spec,
    target.id,
    productVersion,
    clientVersion.buildNumber,
    artifactDigest,
    artifactManifestDigest,
  );
  const targetReady = distribution.targetId === target.id &&
    distribution.platform === "linux" &&
    distribution.architecture === spec.requiredArchitecture &&
    distribution.mode === "release" &&
    distribution.archive === path.basename(safeArtifactPath) &&
    distribution.sha256 === artifactDigest.slice("sha256:".length) &&
    distribution.sourceStateDigest === receiptContext.payload?.sourceStateDigest &&
    SHA256.test(text(distribution.bundleManifestDigest)) &&
    distribution.artifactReady === true &&
    distribution.nonBlockingDistributionGuidance?.githubReleaseBlocked === false;
  const versionReady = distribution.productVersion === productVersion &&
    distribution.buildNumber === clientVersion.buildNumber;
  const directSignatureReady = distribution.signature?.algorithm === "Ed25519" &&
    distribution.signature?.payload === "archive-sha256-digest" &&
    distribution.signature?.keyId === "linux-vm-acceptance" &&
    distribution.signature?.file === path.basename(signaturePath) &&
    SHA256.test(text(distribution.signature?.publicKeyFingerprint)) &&
    verifyLinuxArchiveDigestSignature(distribution, signatureBytes, artifactDigest);
  const consumerVerificationReady = directSignatureReady ||
    receipt.consumerVerificationReady === true;
  return sanitizeArtifactBinding({
    targetId: target.id,
    productVersion,
    artifactKind: spec.artifactKind,
    artifactDigest,
    versionReady,
    targetReady,
    consumerIntegritySignatureReady: directSignatureReady,
    publicVerificationMaterialReady: directSignatureReady,
    consumerVerificationReady,
    platformSecurityReady: receipt.platformSecurityReady,
    consumerIntegritySignatureKind: directSignatureReady
      ? "detached-validation"
      : receipt.consumerIntegritySignatureKind,
    ...receipt,
    ready: versionReady && targetReady && consumerVerificationReady &&
      receipt.installReceiptReady && receipt.receiptProvenanceReady,
  });
}
