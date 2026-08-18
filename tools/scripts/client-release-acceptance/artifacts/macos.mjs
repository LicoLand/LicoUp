import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import {
  artifactTreeDigest,
  resolveContainedExistingPath,
  sha256Buffer,
  sha256File,
} from "../../lib/client-release-artifact-digest.mjs";
import { inspectBoundedMacosCodePolicy } from "../../lib/macos-bundle-integrity.mjs";
import {
  maxJsonBytes,
  maxMacosArchiveBytes,
  maxMacosSidecarBytes,
  repoRoot,
  SHA256,
} from "../constants.mjs";
import { sanitizeArtifactBinding } from "../sanitize-binding.mjs";
import { artifactFileByteLimit, requireValue, text } from "../util.mjs";
import { artifactPlatformVersion, plistValue } from "./helpers.mjs";
import { verifyArtifactReceipt } from "./receipt.mjs";

export function verifyMacosArtifact(target, spec, clientVersion, receiptContext) {
  const productVersion = clientVersion.productVersion;
  const artifactPath = path.join(repoRoot, spec.ref);
  if (!existsSync(artifactPath)) return sanitizeArtifactBinding({ targetId: target.id });
  const safeArtifactPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    artifactPath,
    { expectedKind: "file" },
  );
  const safeInstallArtifactPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    path.join(repoRoot, spec.installArtifactRef),
    { expectedKind: "directory" },
  );
  const manifestPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    path.join(repoRoot, spec.distributionManifestRef),
    { expectedKind: "file" },
  );
  const manifestSnapshot = stableReadFileSnapshot(manifestPath, {
    maxBytes: maxJsonBytes,
  });
  const distribution = JSON.parse(manifestSnapshot.bytes.toString("utf8"));
  const artifactManifestDigest = sha256Buffer(manifestSnapshot.bytes);
  const artifactDigest = sha256File(safeArtifactPath, {
    maxBytes: artifactFileByteLimit(spec),
  });
  const expectedVersion = artifactPlatformVersion(spec, productVersion);
  const executable = plistValue(safeInstallArtifactPath, "CFBundleExecutable");
  const version = plistValue(safeInstallArtifactPath, "CFBundleShortVersionString");
  const buildNumber = plistValue(safeInstallArtifactPath, "CFBundleVersion");
  const executablePath = executable
    ? resolveContainedExistingPath(
        safeInstallArtifactPath,
        path.join(safeInstallArtifactPath, "Contents", "MacOS", executable),
        { expectedKind: "file" },
      )
    : "";
  const architecture = executable
    ? spawnSync("/usr/bin/lipo", ["-archs", executablePath], { cwd: repoRoot, encoding: "utf8", stdio: "pipe", timeout: 5_000 })
    : { status: 1, stdout: "" };
  const entitlementsPath = resolveContainedExistingPath(
    path.join(repoRoot, "build"),
    path.join(repoRoot, spec.entitlementsRef),
    { expectedKind: "file" },
  );
  const codePolicy = executable
    ? inspectBoundedMacosCodePolicy(
        safeInstallArtifactPath,
        executable,
        entitlementsPath,
      )
    : null;
  const signature = codePolicy?.signature || {};
  const nestedCodeReady = codePolicy?.nestedSignatures?.length > 0 &&
    codePolicy.nestedSignatures.every(({ signature: nestedSignature }) =>
      nestedSignature.verified === true &&
      nestedSignature.signatureKind === "local-identity-codesign" &&
      nestedSignature.hardenedRuntime === true &&
      nestedSignature.entitlementsEmpty === true);
  const signatureKind = signature.signatureKind === "local-identity-codesign"
    ? "identity"
    : signature.signatureKind === "local-ad-hoc-codesign" ? "adhoc" : "unknown";
  const installArtifactDigest = text(codePolicy?.artifactDigest);
  const targetReady = architecture.status === 0 &&
    text(architecture.stdout).split(/\s+/u).includes(spec.requiredArchitecture) &&
    distribution.schemaVersion === "v0.0.1:client-macos:distribution-1" &&
    distribution.targetId === target.id && distribution.platform === "macos" &&
    distribution.architecture === spec.requiredArchitecture &&
    distribution.archive === path.basename(safeArtifactPath) &&
    distribution.sha256 === artifactDigest.slice("sha256:".length) &&
    distribution.sourceStateDigest === receiptContext.payload?.sourceStateDigest &&
    distribution.installArtifactKind === "macos-app-bundle" &&
    distribution.installArtifactDigest === installArtifactDigest &&
    SHA256.test(text(distribution.bundleManifestDigest)) &&
    distribution.artifactReady === true &&
    distribution.productionReady !== true;
  const versionReady = version === expectedVersion &&
    buildNumber === String(clientVersion.buildNumber) &&
    distribution.productVersion === productVersion &&
    distribution.buildNumber === clientVersion.buildNumber;
  const receipt = verifyArtifactReceipt(
    receiptContext,
    spec,
    target.id,
    productVersion,
    clientVersion.buildNumber,
    artifactDigest,
    artifactManifestDigest,
  );
  const runtimeExecutableDigest = executablePath
    ? sha256File(resolveContainedExistingPath(
        safeInstallArtifactPath,
        path.join(safeInstallArtifactPath, "Contents/MacOS/licoup-cli"),
        { expectedKind: "file" },
      ), { maxBytes: maxMacosSidecarBytes })
    : "";
  const runtimeDigestReady = SHA256.test(runtimeExecutableDigest) &&
    receipt.runtimeExecutableDigest === runtimeExecutableDigest;
  const localValidationReady = signature.verified === true &&
    signature.hardenedRuntime === true && signature.entitlementsMatch === true &&
    nestedCodeReady === true &&
    SHA256.test(text(signature.entitlementsDigest)) &&
    receipt.consumerVerificationReady === true;
  return sanitizeArtifactBinding({
    targetId: target.id,
    productVersion,
    artifactKind: spec.artifactKind,
    artifactDigest,
    versionReady,
    targetReady,
    consumerIntegritySignatureReady:
      receipt.consumerIntegritySignatureReady,
    publicVerificationMaterialReady:
      receipt.publicVerificationMaterialReady,
    consumerVerificationReady: receipt.consumerVerificationReady,
    platformSecurityReady: receipt.platformSecurityReady,
    consumerIntegritySignatureKind:
      receipt.consumerIntegritySignatureKind,
    ...receipt,
    runtimeExecutableDigest,
    ready: versionReady && targetReady && localValidationReady &&
      runtimeDigestReady && receipt.installReceiptReady &&
      receipt.receiptProvenanceReady
  });
}
