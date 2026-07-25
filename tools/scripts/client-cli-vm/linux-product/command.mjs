import { linuxSourceManifestName, linuxSourceManifestRemoteRef } from "../constants.mjs";
import { quoteShellArg } from "../ssh/session.mjs";
import {
  linuxProductDistributionReportTreePreparationCommand,
  linuxProductOwnerOnlyDirectoryFunction,
  linuxProductReportRootPreparationCommand,
} from "./shell-helpers.mjs";

export function linuxProductCommand(distro, expectedSourceDigest, releaseBinding) {
  if (distro.id !== "ubuntu" || !/^sha256:[a-f0-9]{64}$/u.test(expectedSourceDigest)) {
    throw new Error("Linux product acceptance source binding is invalid.");
  }
  if (
    !releaseBinding?.challenge ||
    !releaseBinding?.invocationNonce ||
    !Number.isFinite(Date.parse(String(releaseBinding?.startedAt || "")))
  ) {
    throw new Error("Linux product release-closure binding is invalid.");
  }
  const archive =
    "$HOME/lico-up/build/apps/desktop/distribution/linux-arm64/LicoUp-linux-arm64.tar.gz";
  const distributionManifest =
    "$HOME/lico-up/build/apps/desktop/distribution/linux-arm64/manifest.json";
  const vmReceipt = "$HOME/lico-product-artifacts/secure-mesh-linux-vm-package-receipt.json";
  const nodeMatrix = "$HOME/lico-product-artifacts/secure-mesh-linux-node-matrix.json";
  const releaseCliReport =
    "$HOME/lico-up/build/apps/desktop/distribution/linux-arm64/secure-mesh-release-cli-proof.json";
  const archivedCli = "$LICO_VM_PRODUCT_ROOT/release-cli/bundle/licoup-cli";
  const generateValidationKey = [
    "const {generateKeyPairSync}=require('node:crypto')",
    "const fs=require('node:fs')",
    "const {privateKey}=generateKeyPairSync('ed25519')",
    "fs.writeFileSync(process.argv[1],privateKey.export({type:'pkcs8',format:'pem'}),{mode:0o600})",
  ].join(";");
  const ownerOnlyDirectoryFunction = linuxProductOwnerOnlyDirectoryFunction();
  const prepareReportRoot = linuxProductReportRootPreparationCommand();
  const prepareDistributionReportTree =
    linuxProductDistributionReportTreePreparationCommand();
  return [
    "set -euo pipefail",
    '. "$HOME/.cargo/env"',
    'export PATH="$HOME/.local/node/bin:$HOME/.local/flutter/bin:$HOME/.cargo/bin:$PATH"',
    'export PUB_CACHE="$HOME/.cache/licomesh/pub-cache"',
    'export CARGO_TARGET_DIR="$HOME/.cache/licomesh/cargo-target"',
    "export CARGO_BUILD_JOBS=1",
    "export CMAKE_BUILD_PARALLEL_LEVEL=1",
    "export LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST=" +
      quoteShellArg(expectedSourceDigest),
    "export LICO_CLIENT_RELEASE_CLOSURE_CHALLENGE=" +
      quoteShellArg(releaseBinding.challenge),
    "export LICO_CLIENT_RELEASE_CLOSURE_STARTED_AT=" +
      quoteShellArg(releaseBinding.startedAt),
    "export LICO_CLIENT_RELEASE_INVOCATION_NONCE=" +
      quoteShellArg(releaseBinding.invocationNonce),
    'export LICO_VM_PRODUCT_ROOT="$HOME/.cache/licomesh/linux-product"',
    'export LICO_LINUX_VM_REPORT_ROOT="$HOME/lico-product-artifacts"',
    'export LICO_LINUX_RELEASE_SIGNING_KEY_PATH="$LICO_VM_PRODUCT_ROOT/validation-key.pem"',
    "export LICO_LINUX_RELEASE_SIGNING_KEY_ID=linux-vm-acceptance",
    ownerOnlyDirectoryFunction,
    prepareReportRoot,
    'trap \'rm -f "$LICO_LINUX_RELEASE_SIGNING_KEY_PATH"\' EXIT',
    'cd "$HOME/lico-up"',
    "node tools/scripts/client-source-manifest-verify.mjs >/dev/null",
    "printf '%s\\n' '{\"step\":\"source_manifest_verified_before_build\"}'",
    "npm run client:get >/dev/null 2>&1",
    "printf '%s\\n' '{\"step\":\"dependencies_ready\"}'",
    "npm run client:build:linux >/dev/null 2>&1",
    "printf '%s\\n' '{\"step\":\"linux_bundle_built\"}'",
    `node -e ${quoteShellArg(generateValidationKey)} "$LICO_LINUX_RELEASE_SIGNING_KEY_PATH" >/dev/null 2>&1`,
    "npm run client:archive:linux-arm64 >/dev/null 2>&1",
    "printf '%s\\n' '{\"step\":\"archive_created\"}'",
    `node tools/scripts/client-secure-mesh-linux-vm-package-receipt.mjs --archive "${archive}" --distribution-manifest "${distributionManifest}" --expected-source-digest ${quoteShellArg(expectedSourceDigest)} --report "${vmReceipt}"`,
    "printf '%s\\n' '{\"step\":\"vm_install_receipt_ready\"}'",
    'rm -rf "$LICO_VM_PRODUCT_ROOT/release-cli"',
    'mkdir -p "$LICO_VM_PRODUCT_ROOT/release-cli"',
    `tar -xzf "${archive}" -C "$LICO_VM_PRODUCT_ROOT/release-cli"`,
    `test -x "${archivedCli}"`,
    prepareDistributionReportTree,
    `node tools/scripts/client-secure-mesh-release-cli-proof.mjs --cli "${archivedCli}" --platform "ubuntu-linux-arm64" --report "${releaseCliReport}"`,
    `cp "${releaseCliReport}" "$HOME/lico-product-artifacts/secure-mesh-release-cli-proof.json"`,
    "printf '%s\\n' '{\"step\":\"archived_release_cli_proof_ready\"}'",
    `node tools/scripts/client-secure-mesh-linux-node-matrix.mjs --archive "${archive}" --distribution-manifest "${distributionManifest}" --vm-receipt "${vmReceipt}" --expected-source-digest ${quoteShellArg(expectedSourceDigest)} --docker-command ${quoteShellArg('["sudo","docker"]')} --report "${nodeMatrix}"`,
    "printf '%s\\n' '{\"step\":\"three_node_matrix_ready\"}'",
    "node tools/scripts/client-source-manifest-verify.mjs >/dev/null",
    "printf '%s\\n' '{\"step\":\"source_manifest_verified_after_build\"}'",
    `cp "${archive}" "$HOME/lico-product-artifacts/LicoUp-linux-arm64.tar.gz"`,
    `cp "${archive}.sig" "$HOME/lico-product-artifacts/LicoUp-linux-arm64.tar.gz.sig"`,
    `cp "${distributionManifest}" "$HOME/lico-product-artifacts/linux-arm64-manifest.json"`,
    `cp "$HOME/lico-up/${linuxSourceManifestRemoteRef}" "$HOME/lico-product-artifacts/${linuxSourceManifestName}"`,
    "printf '%s\\n' '{\"ok\":true,\"currentSourceArchive\":true,\"vmInstallReceiptReady\":true,\"archivedReleaseCliProofReady\":true,\"threeNodeMatrixReady\":true}'",
  ].join(" && ");
}
