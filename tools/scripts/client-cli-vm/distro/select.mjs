import { existsSync } from "node:fs";
import process from "node:process";
import { firmwareCandidates, matrix } from "../constants.mjs";

export function imageUrlFor(distro) {
  const envName =
    distro.imageUrlEnv || `LICO_CLIENT_CLI_VM_${distro.id.toUpperCase()}_IMAGE_URL`;
  return process.env[envName] || distro.imageUrl || "";
}

export function selectedDistros(options) {
  const known = new Map(matrix.distros.map((distro) => [distro.id, distro]));
  if (options.distros.length === 0) {
    return matrix.distros.filter(
      (distro) =>
        !distro.manualImageRequired || options.includeManual || imageUrlFor(distro),
    );
  }
  return options.distros.map((id) => {
    const distro = known.get(id);
    if (!distro) {
      throw new Error(`Unknown client CLI VM distro: ${id}`);
    }
    return distro;
  });
}

export function resolveFirmware() {
  const firmware = firmwareCandidates.find((candidate) => existsSync(candidate));
  if (!firmware) {
    throw new Error(
      "AArch64 UEFI firmware is required. Set LICO_CLIENT_CLI_VM_EFI to an edk2 aarch64 firmware path.",
    );
  }
  return firmware;
}
