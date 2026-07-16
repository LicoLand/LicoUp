import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { vmUser } from "../constants.mjs";
import { pathsFor } from "../paths.mjs";
import { run } from "../process.mjs";

export function seedUserData(distro, publicKey) {
  const vmPaths = pathsFor(distro);
  rmSync(vmPaths.seedDir, { recursive: true, force: true });
  mkdirSync(vmPaths.seedDir, { recursive: true });
  writeFileSync(
    path.join(vmPaths.seedDir, "user-data"),
    [
      "#cloud-config",
      "preserve_hostname: false",
      `hostname: lico-${distro.id}-arm64`,
      "disable_root: false",
      "ssh_pwauth: false",
      "users:",
      "  - default",
      `  - name: ${vmUser}`,
      "    gecos: Lico Client CLI VM",
      "    groups: users,admin,wheel,sudo",
      "    sudo: ALL=(ALL) NOPASSWD:ALL",
      "    shell: /bin/bash",
      "    lock_passwd: true",
      "    ssh_authorized_keys:",
      `      - ${publicKey}`,
      "",
    ].join("\n"),
    "utf8",
  );
  writeFileSync(
    path.join(vmPaths.seedDir, "meta-data"),
    [
      `instance-id: lico-${distro.id}-arm64`,
      `local-hostname: lico-${distro.id}-arm64`,
      "",
    ].join("\n"),
    "utf8",
  );
  rmSync(vmPaths.seedIso, { force: true });
  run("hdiutil", [
    "makehybrid",
    "-iso",
    "-joliet",
    "-default-volume-name",
    "cidata",
    "-o",
    vmPaths.seedIso,
    vmPaths.seedDir,
  ]);
}
