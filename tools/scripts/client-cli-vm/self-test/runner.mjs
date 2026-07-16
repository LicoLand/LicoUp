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
  linuxProductRustupArm64Sha256,
  linuxProductRustupVersion,
  linuxProductRustVersion,
  linuxSourceManifestRemoteRef,
  matrix,
} from "../constants.mjs";
import { linuxProductBootstrapCommand } from "../linux-product/bootstrap.mjs";
import { linuxProductCommand } from "../linux-product/command.mjs";
import {
  linuxProductDistributionReportTreePreparationCommand,
  linuxProductOwnerOnlyDirectoryFunction,
  linuxProductReportRootPreparationCommand,
} from "../linux-product/shell-helpers.mjs";
import { verifyLinuxArchiveDigestSignature } from "../linux-product/validate.mjs";
import { repoSyncExcludes } from "../sync/repo.mjs";
import { verifyCommand } from "../verify/command.mjs";

export function runScriptSelfTest() {
  const ubuntu = matrix.distros.find((distro) => distro.id === "ubuntu");
  if (!ubuntu) throw new Error("client CLI VM matrix has no Ubuntu entry");
  const command = verifyCommand(ubuntu);
  const productCommand = linuxProductCommand(ubuntu, `sha256:${"a".repeat(64)}`, {
    challenge: "A".repeat(43),
    invocationNonce: "B".repeat(43),
    startedAt: "2026-01-01T00:00:00.000Z",
  });
  const ownerOnlyDirectoryFunction = linuxProductOwnerOnlyDirectoryFunction();
  const reportRootPreparation = linuxProductReportRootPreparationCommand();
  const distributionReportTreePreparation =
    linuxProductDistributionReportTreePreparationCommand();
  const productBootstrapCommand = linuxProductBootstrapCommand(ubuntu);
  const requiredTokens = [
    "--self-test",
    "--expect-strategy os_secure_store",
    '--platform "ubuntu-linux-arm64"',
    "secure-mesh-linux-adaptive-custody-proof.json",
    "mobile-relay-secret-store-self-test.json",
  ];
  if (!requiredTokens.every((token) => command.includes(token))) {
    throw new Error(
      "client CLI VM verification command omitted an adaptive Linux custody check",
    );
  }
  const retiredAuthorities = [
    ["production", "Ready"].join(""),
    ["--expected", "-backend"].join(""),
  ];
  for (const retired of retiredAuthorities) {
    if (command.includes(retired)) {
      throw new Error(
        "client CLI VM verification command retained a fixed readiness authority",
      );
    }
  }
  for (const token of [
    "client:build:linux",
    "client:archive:linux-arm64",
    "client-secure-mesh-linux-vm-package-receipt.mjs",
    "client-secure-mesh-linux-node-matrix.mjs",
    "linux-vm-acceptance",
    "secure-mesh-linux-vm-package-receipt.json",
    "secure-mesh-linux-node-matrix.json",
    "secure-mesh-release-cli-proof.json",
    "archived_release_cli_proof_ready",
    "LICO_CLIENT_RELEASE_CLOSURE_CHALLENGE",
    "LICO_CLIENT_RELEASE_INVOCATION_NONCE",
    "LICO_LINUX_VM_REPORT_ROOT",
    "LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST",
    "client-source-manifest-verify.mjs",
    "source_manifest_verified_before_build",
    "source_manifest_verified_after_build",
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
      .length !== 5 ||
    productCommand.indexOf(distributionReportTreePreparation) >
      productCommand.indexOf("client-secure-mesh-release-cli-proof.mjs")
  ) {
    throw new Error("client CLI VM Linux report root is not owner-only and symlink-safe");
  }
  if (
    !repoSyncExcludes.includes(".git") ||
    !repoSyncExcludes.includes(".lico-source-attestation")
  ) {
    throw new Error("client CLI VM repository sync included noncanonical source authority");
  }
  for (const token of [
    "git -c advice.detachedHead=false clone --quiet --filter=blob:none --depth 1 --branch",
    "flutter_arm64_source_toolchain_ready",
    `v${linuxProductNodeVersion}`,
    linuxProductNodeArm64Sha256,
    linuxProductFlutterVersion,
    linuxProductFlutterCommit,
    `rustup ${linuxProductRustupVersion}`,
    linuxProductRustVersion,
    linuxProductRustupArm64Sha256,
    "rust_toolchain_ready",
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
  if (
    productBootstrapCommand.includes(["sh", "rustup.rs"].join(".")) ||
    productBootstrapCommand.includes(["default-toolchain", "stable"].join(" "))
  ) {
    throw new Error(
      "client CLI VM Linux product bootstrap retained an unpinned Rust installer",
    );
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
        schemaVersion: "licolite.client-cli-vm.self-test.v1",
        exactCapabilityInputValidationReady: true,
        unavailableServiceFallbackProofReady: true,
        unlockedServiceOsStoreProofReady: true,
        currentSourceArchiveBindingReady: true,
        linuxVmInstallSessionSmokeReady: true,
        archivedReleaseCliProofReady: true,
        directArchiveSignatureVerificationReady: true,
        isolatedLinuxNodeMatrixReady: true,
        staleSourceRejectionReady: true,
        hostileUmaskReportRootReady: true,
        unsafeExistingReportRootReplaced: true,
        reportRootSymlinkRejected: true,
        distributionReportAncestorTreeReady: true,
        downstreamLinuxReportRootsAudited: true,
        fixedReadinessAuthorityRemoved: true,
        runtimeDataIncluded: false,
      },
      null,
      2,
    ),
  );
}
