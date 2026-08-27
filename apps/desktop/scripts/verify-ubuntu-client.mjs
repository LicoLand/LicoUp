import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const dockerfile = path.join(workspaceRoot, "apps", "desktop", "docker", "ubuntu-client.Dockerfile");
const image = process.env.LICO_UBUNTU_IMAGE || "licoup-ubuntu:local";
const platform = process.env.LICO_UBUNTU_PLATFORM || "linux/amd64";
const guiArtifactDir = path.join(workspaceRoot, "build", "artifacts", "ubuntu-desktop-client");
const containerRoot = path.posix.sep;
const containerWorkspace = path.posix.join(containerRoot, "workspace");
const containerSource = path.posix.join(containerRoot, "source");
const containerArtifacts = path.posix.join(containerRoot, "artifacts");
const containerAdminHome = path.posix.join(containerRoot, "root");

function run(command, args, options = {}) {
  execFileSync(command, args, {
    cwd: workspaceRoot,
    stdio: "inherit",
    ...options,
  });
}

function main() {
  mkdirSync(guiArtifactDir, { recursive: true });

  if (process.env.LICO_UBUNTU_SKIP_IMAGE_BUILD !== "1") {
    run("docker", [
      "build",
      "--platform",
      platform,
      "-f",
      dockerfile,
      "-t",
      image,
      ".",
    ]);
  }

  const prepareWorkspace = [
    `mkdir -p ${containerWorkspace}`,
    "&&",
    [
      "tar",
      `-C ${containerSource}`,
      "--exclude=.git",
      "--exclude=node_modules",
      "--exclude=build",
      "--exclude=tests/fixtures",
      "--exclude=crates/licoup-native/target",
      "--exclude=apps/desktop/.dart_tool",
      "--exclude=apps/desktop/build",
      "-cf -",
      ".",
    ].join(" "),
    "|",
    `tar -C ${containerWorkspace} -xf -`,
  ].join(" ");

  const verifyScript = [
    "set -euo pipefail",
    prepareWorkspace,
    `cd ${containerWorkspace}`,
    "node --version",
    "rustc --version",
    "cargo --version",
    "flutter --version",
    "flutter doctor -v",
    "npm run client:get",
    "npm run client:analyze",
    "npm run client:test",
    "npm run client:native:test",
    "npm run client:build -- --platform linux",
    "npm run client:linux:smoke",
    `LICO_GUI_ARTIFACT_DIR=${containerArtifacts} npm run client:linux:gui-smoke`,
  ].join(" && ");

  run("docker", [
    "run",
    "--rm",
    "--platform",
    platform,
    "--mount",
    `type=bind,src=${workspaceRoot},dst=${containerSource},readonly`,
    "--mount",
    `type=volume,src=lico-ubuntu-pub-cache,dst=${path.posix.join(containerAdminHome, ".pub-cache")}`,
    "--mount",
    `type=volume,src=lico-ubuntu-cargo-registry,dst=${path.posix.join(containerAdminHome, ".cargo", "registry")}`,
    "--mount",
    `type=volume,src=lico-ubuntu-cargo-git,dst=${path.posix.join(containerAdminHome, ".cargo", "git")}`,
    "--mount",
    `type=volume,src=lico-ubuntu-cargo-target,dst=${path.posix.join(containerWorkspace, "build", "crates", "licoup-native", "target")}`,
    "--mount",
    `type=bind,src=${guiArtifactDir},dst=${containerArtifacts}`,
    "-w",
    containerRoot,
    image,
    "bash",
    "-lc",
    verifyScript,
  ]);
}

main();
