import { linuxSourceManifestName, linuxSourceManifestRemoteRef } from "../constants.mjs";
import { quoteShellArg } from "../ssh/session.mjs";
import {
  linuxProductVerificationReportTreePreparationCommand,
  linuxProductOwnerOnlyDirectoryFunction,
  linuxProductReportRootPreparationCommand,
} from "./shell-helpers.mjs";

export function linuxProductCommand(distro, expectedSourceDigest) {
  if (distro.id !== "ubuntu" || !/^sha256:[a-f0-9]{64}$/u.test(expectedSourceDigest)) {
    throw new Error("Linux product acceptance source binding is invalid.");
  }
  const archive =
    "$HOME/lico-up/build/apps/desktop/verification/linux-arm64/LicoUp-linux-arm64-verification.tar.gz";
  const verificationManifest =
    "$HOME/lico-up/build/apps/desktop/verification/linux-arm64/verification-manifest.json";
  const extractedBundleRoot = "$LICO_VM_PRODUCT_ROOT/release-cli/bundle";
  const archivedClient = `${extractedBundleRoot}/licoup`;
  const archivedCli = `${extractedBundleRoot}/licoup-cli`;
  const generateValidationKey = [
    "const {generateKeyPairSync}=require('node:crypto')",
    "const fs=require('node:fs')",
    "const {privateKey}=generateKeyPairSync('ed25519')",
    "fs.writeFileSync(process.argv[1],privateKey.export({type:'pkcs8',format:'pem'}),{mode:0o600})",
  ].join(";");
  const ownerOnlyDirectoryFunction = linuxProductOwnerOnlyDirectoryFunction();
  const prepareReportRoot = linuxProductReportRootPreparationCommand();
  const prepareVerificationReportTree =
    linuxProductVerificationReportTreePreparationCommand();
  return [
    "set -euo pipefail",
    'export PATH="$HOME/.local/node/bin:$HOME/.local/flutter/bin:$PATH"',
    'export PUB_CACHE="$HOME/.cache/licoup/pub-cache"',
    "export CMAKE_BUILD_PARALLEL_LEVEL=1",
    "export LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST=" +
      quoteShellArg(expectedSourceDigest),
    'export LICO_VM_PRODUCT_ROOT="$HOME/.cache/licoup/linux-product"',
    'export LICO_LINUX_VM_REPORT_ROOT="$HOME/lico-product-artifacts"',
    'export LICO_LINUX_VERIFICATION_SIGNING_KEY_PATH="$LICO_VM_PRODUCT_ROOT/validation-key.pem"',
    "export LICO_LINUX_VERIFICATION_SIGNING_KEY_ID=linux-vm-acceptance",
    ownerOnlyDirectoryFunction,
    prepareReportRoot,
    'trap \'rm -f "$LICO_LINUX_VERIFICATION_SIGNING_KEY_PATH"\' EXIT',
    'cd "$HOME/lico-up"',
    "node tools/scripts/client-source-manifest-verify.mjs >/dev/null",
    "printf '%s\\n' '{\"step\":\"source_manifest_verified_before_build\"}'",
    "npm run client:get >/dev/null 2>&1",
    "printf '%s\\n' '{\"step\":\"dependencies_ready\"}'",
    "npm run client:build -- --platform linux >/dev/null 2>&1",
    "printf '%s\\n' '{\"step\":\"linux_bundle_built\"}'",
    `node -e ${quoteShellArg(generateValidationKey)} "$LICO_LINUX_VERIFICATION_SIGNING_KEY_PATH" >/dev/null 2>&1`,
    "npm run client:verify:linux-bundle-carrier >/dev/null 2>&1",
    "printf '%s\\n' '{\"step\":\"verification_carrier_created\"}'",
    prepareVerificationReportTree,
    'rm -rf "$LICO_VM_PRODUCT_ROOT/release-cli"',
    'mkdir -p "$LICO_VM_PRODUCT_ROOT/release-cli"',
    `tar -xzf "${archive}" -C "$LICO_VM_PRODUCT_ROOT/release-cli"`,
    `test -x "${archivedClient}"`,
    `test -x "${archivedCli}"`,
    `"${archivedCli}" --help >/dev/null`,
    "printf '%s\\n' '{\"step\":\"archived_delivered_cli_smoke_ready\"}'",
    "node tools/scripts/client-source-manifest-verify.mjs >/dev/null",
    "printf '%s\\n' '{\"step\":\"source_manifest_verified_after_build\"}'",
    `cp "${archive}" "$HOME/lico-product-artifacts/LicoUp-linux-arm64-verification.tar.gz"`,
    `cp "${archive}.sig" "$HOME/lico-product-artifacts/LicoUp-linux-arm64-verification.tar.gz.sig"`,
    `cp "${verificationManifest}" "$HOME/lico-product-artifacts/linux-arm64-verification-manifest.json"`,
    `cp "$HOME/lico-up/${linuxSourceManifestRemoteRef}" "$HOME/lico-product-artifacts/${linuxSourceManifestName}"`,
    "printf '%s\\n' '{\"ok\":true,\"currentSourceArchive\":true,\"archivedDeliveredCliSmokeReady\":true}'",
  ].join(" && ");
}
