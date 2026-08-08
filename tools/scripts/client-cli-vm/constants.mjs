import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { CANONICAL_CLIENT_SOURCE_ROOTS } from "../lib/client-source-state-digest.mjs";

export const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
export const matrixPath = path.join(repoRoot, "tools", "client-cli-vm-matrix.json");
export const matrix = JSON.parse(readFileSync(matrixPath, "utf8"));
export const vmUser = "lico";
export const defaultDiskSize = "40G";
export const defaultMemory = "4096";
export const defaultCpus = "4";
export const defaultBootTimeoutSeconds = 360;
export const linuxProductNodeVersion = "24.14.1";
export const linuxProductNodeArm64Sha256 =
  "71e427e28b78846f201d4d5ecc30cb13d1508ca099ef3871889a1256c7d6f67e";
export const linuxProductFlutterVersion = "3.44.2";
export const linuxProductFlutterCommit = "c9a6c484230f8b5e408ec57be1ef71dee1e77020";
export const linuxProductRustVersion = "1.95.0";
export const linuxProductRustupVersion = "1.28.2";
export const linuxProductRustupArm64Sha256 =
  "e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c";
export const clientSourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;
export const linuxSourceManifestName = "client-source-manifest.json";
export const linuxSourceManifestRemoteRef =
  `.lico-source-attestation/${linuxSourceManifestName}`;
export const firmwareCandidates = [
  process.env.LICO_CLIENT_CLI_VM_EFI,
  ["", "opt", "homebrew", "share", "qemu", "edk2-aarch64-code.fd"].join("/"),
  ["", "usr", "local", "share", "qemu", "edk2-aarch64-code.fd"].join("/"),
  ["", "usr", "share", "qemu-efi-aarch64", "QEMU_EFI.fd"].join("/"),
  ["", "usr", "share", "AAVMF", "AAVMF_CODE.fd"].join("/"),
].filter(Boolean);
