import os from "node:os";
import path from "node:path";
import process from "node:process";
import { repoRoot } from "./constants.mjs";

export function cacheRoot() {
  if (process.env.LICO_CLIENT_CLI_VM_ROOT) {
    return path.resolve(process.env.LICO_CLIENT_CLI_VM_ROOT);
  }
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Caches", "LicoMesh", "client-cli-vms");
  }
  if (process.platform === "win32") {
    return path.join(
      process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"),
      "LicoMesh",
      "ClientCliVms",
    );
  }
  return path.join(
    process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache"),
    "licomesh",
    "client-cli-vms",
  );
}

export function pathsFor(distro) {
  const root = cacheRoot();
  const vmRoot = path.join(root, "vms", `${distro.id}-arm64`);
  return {
    root,
    imagesRoot: path.join(root, "images"),
    sshRoot: path.join(root, "ssh"),
    vmRoot,
    baseImage: path.join(root, "images", distro.imageFile),
    disk: path.join(vmRoot, "disk.qcow2"),
    seedDir: path.join(vmRoot, "seed"),
    seedIso: path.join(vmRoot, "seed.iso"),
    pidFile: path.join(vmRoot, "qemu.pid"),
    serialLog: path.join(vmRoot, "serial.log"),
    monitorSocket: path.join(vmRoot, "monitor.sock"),
    artifactRoot: path.join(repoRoot, "build", "client-cli-vm", `${distro.id}-arm64`),
  };
}
