import { existsSync, mkdirSync } from "node:fs";
import { pathsFor } from "../paths.mjs";
import { run } from "../process.mjs";

export function createDisk(distro, options) {
  const vmPaths = pathsFor(distro);
  mkdirSync(vmPaths.vmRoot, { recursive: true });
  if (existsSync(vmPaths.disk)) {
    return;
  }
  run("qemu-img", [
    "create",
    "-f",
    "qcow2",
    "-F",
    "qcow2",
    "-b",
    vmPaths.baseImage,
    vmPaths.disk,
    options.diskSize,
  ]);
}
