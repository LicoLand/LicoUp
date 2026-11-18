import {
  createHash,
  generateKeyPairSync,
  sign,
} from "node:crypto";
import {
  linuxProductFlutterCommit,
  linuxProductFlutterVersion,
  linuxProductNodeArm64Sha256,
  linuxProductNodeVersion,
  linuxSourceManifestRemoteRef,
  matrix,
} from "../constants.mjs";
import { linuxProductBootstrapCommand } from "../linux-product/bootstrap.mjs";
import { linuxProductCommand } from "../linux-product/command.mjs";
import {
  linuxProductVerificationReportTreePreparationCommand,
  linuxProductOwnerOnlyDirectoryFunction,
  linuxProductReportRootPreparationCommand,
} from "../linux-product/shell-helpers.mjs";
import { verifyLinuxArchiveDigestSignature } from "../linux-product/validate.mjs";
import { repoSyncExcludes, repoSyncIncludes } from "../sync/repo.mjs";

export function runScriptSelfTest() {
  const ubuntu = matrix.distros.find((distro) => distro.id === "ubuntu");
  if (!ubuntu) throw new Error("client CLI VM matrix has no Ubuntu entry");
  const productCommand = linuxProductCommand(ubuntu, `sha256:${"a".repeat(64)}`);
  const ownerOnlyDirectoryFunction = linuxProductOwnerOnlyDirectoryFunction();
  const reportRootPreparation = linuxProductReportRootPreparationCommand();
  const distributionReportTreePreparation =
    linuxProductVerificationReportTreePreparationCommand();
  const productBootstrapCommand = linuxProductBootstrapCommand(ubuntu);
  for (const token of [
    "client:build -- --platform linux",
    "client:verify:linux-bundle-carrier",
    "linux-vm-acceptance",
    "LICO_LINUX_VM_REPORT_ROOT",
    "LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST",
    "LICO_LINUX_VERIFICATION_SIGNING_KEY_PATH",
    "LICO_LINUX_VERIFICATION_SIGNING_KEY_ID",
    "client-source-manifest-verify.mjs",
    "source_manifest_verified_before_build",
    "source_manifest_verified_after_build",
    "archived_delivered_cli_smoke_ready",
    "licoup-cli",
    "verification-manifest.json",
    "linux-arm64-verification-manifest.json",
    linuxSourceManifestRemoteRef,
  ]) {
    if (!productCommand.includes(token)) {
      throw new Error(
        "client CLI VM Linux product command omitted a required current-client proof",
      );
    }
  }
  if (
    (productCommand.match(/client-source-manifest-verify\.mjs/gu) || []).length !== 2 ||
    (productCommand.match(/export LICO_CLIENT_[A-Z_]*SOURCE[A-Z_]*=/gu) || []).length !== 1
  ) {
    throw new Error("client CLI VM retained environment-only source attestation");
  }
  for (const retired of [
    "cargo",
    "rustup",
    ".cargo",
    "CARGO_TARGET_DIR",
    "crates/",
    "secure-mesh",
    "client-secure-mesh-",
    "LICO_CLIENT_RELEASE_CLOSURE",
    "LICO_CLIENT_RELEASE_INVOCATION",
    "docker",
  ]) {
    if (productCommand.includes(retired)) {
      throw new Error(
        "client CLI VM Linux product command retained a retired toolchain or proof step",
      );
    }
  }
  const symlinkCheck = 'test ! -L "$LICO_LINUX_VM_REPORT_ROOT"';
  const removeUnsafeRoot = 'rm -rf "$LICO_LINUX_VM_REPORT_ROOT"';
  if (
    !productCommand.includes(reportRootPreparation) ||
    !productCommand.includes(ownerOnlyDirectoryFunction) ||
    !productCommand.includes(distributionReportTreePreparation) ||
    reportRootPreparation.indexOf(symlinkCheck) < 0 ||
    reportRootPreparation.indexOf(symlinkCheck) >
      reportRootPreparation.indexOf(removeUnsafeRoot) ||
    !reportRootPreparation.includes('lico_owner_only_directory "$LICO_VM_PRODUCT_ROOT"') ||
    !reportRootPreparation.includes(
      'lico_owner_only_directory "$LICO_LINUX_VM_REPORT_ROOT"',
    ) ||
    !ownerOnlyDirectoryFunction.includes("install -d -m 0700") ||
    !ownerOnlyDirectoryFunction.includes("stat -c '%u'") ||
    !ownerOnlyDirectoryFunction.includes("stat -c '%a'") ||
    !ownerOnlyDirectoryFunction.includes("= 700") ||
    (distributionReportTreePreparation.match(/lico_owner_only_directory/gu) || [])
      .length !== 5
  ) {
    throw new Error("client CLI VM Linux report root is not owner-only and symlink-safe");
  }
  if (
    !repoSyncExcludes.includes(".git") ||
    !repoSyncExcludes.includes(".lico-source-attestation") ||
    !repoSyncExcludes.includes("build") ||
    !repoSyncIncludes.includes("build/native-artifacts/") ||
    !repoSyncIncludes.includes("build/native-artifacts/**")
  ) {
    throw new Error(
      "client CLI VM repository sync no longer binds canonical source and delivered artifacts",
    );
  }
  for (const token of [
    "git -c advice.detachedHead=false clone --quiet --filter=blob:none --depth 1 --branch",
    "flutter_arm64_source_toolchain_ready",
    `v${linuxProductNodeVersion}`,
    linuxProductNodeArm64Sha256,
    linuxProductFlutterVersion,
    linuxProductFlutterCommit,
  ]) {
    if (!productBootstrapCommand.includes(token)) {
      throw new Error(
        "client CLI VM Linux product bootstrap omitted a pinned ARM64 toolchain check",
      );
    }
  }
  if (productBootstrapCommand.includes("flutter_linux_arm64_")) {
    throw new Error(
      "client CLI VM Linux product bootstrap retained a nonexistent ARM64 SDK archive",
    );
  }
  for (const retired of ["rustup", "rust_toolchain_ready", "cargo", "docker.io"]) {
    if (productBootstrapCommand.includes(retired)) {
      throw new Error(
        "client CLI VM Linux product bootstrap retained a retired toolchain install",
      );
    }
  }
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicKeyDer = publicKey.export({ type: "spki", format: "der" });
  const archiveDigest = `sha256:${"a".repeat(64)}`;
  const signatureBytes = sign(
    null,
    Buffer.from(archiveDigest.slice("sha256:".length), "hex"),
    privateKey,
  );
  const distribution = {
    signature: {
      publicKeySpkiBase64: publicKeyDer.toString("base64"),
      publicKeyFingerprint: `sha256:${createHash("sha256").update(publicKeyDer).digest("hex")}`,
    },
  };
  if (
    !verifyLinuxArchiveDigestSignature(distribution, signatureBytes, archiveDigest) ||
    verifyLinuxArchiveDigestSignature(
      distribution,
      signatureBytes,
      `sha256:${"b".repeat(64)}`,
    )
  ) {
    throw new Error("Linux product host signature verification is not fail closed");
  }
  console.log(
    JSON.stringify(
      {
        ok: true,
        schemaVersion: "licoup.client-cli-vm.self-test.v1",
        currentSourceArchiveBindingReady: true,
        verificationCarrierReady: true,
        archivedDeliveredCliSmokeReady: true,
        deliveredArtifactSyncReady: true,
        directArchiveSignatureVerificationReady: true,
        staleSourceRejectionReady: true,
        hostileUmaskReportRootReady: true,
        unsafeExistingReportRootReplaced: true,
        reportRootSymlinkRejected: true,
        distributionReportAncestorTreeReady: true,
        retiredRustToolchainRemoved: true,
        runtimeDataIncluded: false,
      },
      null,
      2,
    ),
  );
}
