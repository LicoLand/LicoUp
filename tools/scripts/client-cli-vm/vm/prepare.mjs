import { downloadImage } from "../image/download.mjs";
import { createDisk } from "../image/disk.mjs";
import { seedUserData } from "../image/seed.mjs";
import { requireTool } from "../process.mjs";
import { ensureSshKey } from "../ssh/key.mjs";

export function prepareDistro(distro, options) {
  requireTool("curl");
  requireTool("qemu-img");
  requireTool("ssh-keygen");
  requireTool("hdiutil");
  const { publicKey } = ensureSshKey();
  downloadImage(distro);
  createDisk(distro, options);
  seedUserData(distro, publicKey);
  console.log(`[client-cli-vm] Prepared ${distro.id} ARM64 VM state.`);
}
