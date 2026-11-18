import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, renameSync } from "node:fs";
import { repoRoot } from "../constants.mjs";
import { imageUrlFor } from "../distro/select.mjs";
import { pathsFor } from "../paths.mjs";

export function downloadImage(distro) {
  const vmPaths = pathsFor(distro);
  const url = imageUrlFor(distro);
  if (!url) {
    throw new Error(
      `${distro.id} requires ${distro.imageUrlEnv || `LICO_CLIENT_CLI_VM_${distro.id.toUpperCase()}_IMAGE_URL`}.`,
    );
  }
  mkdirSync(vmPaths.imagesRoot, { recursive: true });
  if (existsSync(vmPaths.baseImage)) {
    return;
  }
  const partial = `${vmPaths.baseImage}.partial`;
  console.log(`[client-cli-vm] Downloading ${distro.id} ARM64 image.`);
  const args = [
    "-L",
    "--fail",
    "--retry",
    "8",
    "--retry-delay",
    "3",
    "--retry-all-errors",
    "--continue-at",
    "-",
    "--output",
    partial,
    url,
  ];
  let status = 1;
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    const result = spawnSync("curl", args, {
      cwd: repoRoot,
      stdio: "inherit",
    });
    status = result.status ?? 1;
    if (status === 0) {
      break;
    }
    console.warn(
      `[client-cli-vm] Download attempt ${attempt} for ${distro.id} failed; retrying with resume.`,
    );
  }
  if (status !== 0) {
    throw new Error(`Unable to download ${distro.id} ARM64 image after resumable retries.`);
  }
  renameSync(partial, vmPaths.baseImage);
}
