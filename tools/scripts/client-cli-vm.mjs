#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import {
  createHash,
  createPublicKey,
  generateKeyPairSync,
  sign,
  verify,
} from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { sanitizeError } from "./lib/sanitize-error.mjs";
import {
  CANONICAL_CLIENT_SOURCE_ROOTS,
  clientSourceStateDigest,
  createClientSourceManifest,
  readAndVerifyClientSourceManifest,
} from "./lib/client-source-state-digest.mjs";
import {
  sha256File as stableSha256File,
  stableReadFile,
} from "./lib/client-release-artifact-digest.mjs";
import {
  validateLinuxNodeMatrixReport,
  validateLinuxVmPackageReceipt
} from "./lib/secure-mesh-linux-evidence.mjs";
import { requireReleaseCliTargetEvidence } from "./lib/client-release-target-evidence.mjs";
import {
  createReleaseClosureChallenge,
  createReleaseInvocationNonce,
  releaseClosureChallengeDigest,
  releaseInvocationNonceDigest,
  requiredReleaseClosureChallenge,
  requiredReleaseClosureStartedAt,
  requiredReleaseInvocationNonce,
} from "./lib/release-closure-challenge.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const matrixPath = path.join(repoRoot, "tools", "client-cli-vm-matrix.json");
const matrix = JSON.parse(readFileSync(matrixPath, "utf8"));
const vmUser = "lico";
const defaultDiskSize = "40G";
const defaultMemory = "4096";
const defaultCpus = "4";
const defaultBootTimeoutSeconds = 360;
const linuxProductNodeVersion = "24.14.1";
const linuxProductNodeArm64Sha256 = "71e427e28b78846f201d4d5ecc30cb13d1508ca099ef3871889a1256c7d6f67e";
const linuxProductFlutterVersion = "3.44.2";
const linuxProductFlutterCommit = "c9a6c484230f8b5e408ec57be1ef71dee1e77020";
const linuxProductRustVersion = "1.95.0";
const linuxProductRustupVersion = "1.28.2";
const linuxProductRustupArm64Sha256 = "e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c";
const clientSourceRoots = CANONICAL_CLIENT_SOURCE_ROOTS;
const linuxSourceManifestName = "client-source-manifest.json";
const linuxSourceManifestRemoteRef =
  `.lico-source-attestation/${linuxSourceManifestName}`;
const firmwareCandidates = [
  process.env.LICO_CLIENT_CLI_VM_EFI,
  ["", "opt", "homebrew", "share", "qemu", "edk2-aarch64-code.fd"].join("/"),
  "/usr/local/share/qemu/edk2-aarch64-code.fd",
  "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
  "/usr/share/AAVMF/AAVMF_CODE.fd"
].filter(Boolean);

function parseArgs(argv = process.argv.slice(2)) {
  const [action = "list", ...rest] = argv;
  const options = {
    action,
    distros: [],
    includeManual: false,
    keepRunning: false,
    memory: process.env.LICO_CLIENT_CLI_VM_MEMORY || defaultMemory,
    cpus: process.env.LICO_CLIENT_CLI_VM_CPUS || defaultCpus,
    diskSize: process.env.LICO_CLIENT_CLI_VM_DISK_SIZE || defaultDiskSize,
    bootTimeoutSeconds: Number(process.env.LICO_CLIENT_CLI_VM_BOOT_TIMEOUT || defaultBootTimeoutSeconds),
    command: []
  };
  const separator = rest.indexOf("--");
  const optionArgs = separator === -1 ? rest : rest.slice(0, separator);
  options.command = separator === -1 ? [] : rest.slice(separator + 1);

  for (let index = 0; index < optionArgs.length; index += 1) {
    const arg = optionArgs[index];
    const next = optionArgs[index + 1];
    if ((arg === "--distro" || arg === "-d") && next) {
      options.distros.push(next);
      index += 1;
    } else if (arg === "--all") {
      options.includeManual = true;
    } else if (arg === "--include-manual") {
      options.includeManual = true;
    } else if (arg === "--keep-running") {
      options.keepRunning = true;
    } else if (arg === "--memory" && next) {
      options.memory = next;
      index += 1;
    } else if (arg === "--cpus" && next) {
      options.cpus = next;
      index += 1;
    } else if (arg === "--disk-size" && next) {
      options.diskSize = next;
      index += 1;
    } else if (arg === "--boot-timeout" && next) {
      options.bootTimeoutSeconds = Number(next);
      index += 1;
    } else {
      throw new Error(`Unknown client CLI VM option: ${arg}`);
    }
  }
  return options;
}

function cacheRoot() {
  if (process.env.LICO_CLIENT_CLI_VM_ROOT) {
    return path.resolve(process.env.LICO_CLIENT_CLI_VM_ROOT);
  }
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Caches", "LicoLite", "client-cli-vms");
  }
  if (process.platform === "win32") {
    return path.join(
      process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"),
      "LicoLite",
      "ClientCliVms"
    );
  }
  return path.join(process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache"), "licolite", "client-cli-vms");
}

function pathsFor(distro) {
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
    artifactRoot: path.join(repoRoot, "build", "client-cli-vm", `${distro.id}-arm64`)
  };
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || repoRoot,
    env: options.env || process.env,
    stdio: options.stdio || "inherit",
    encoding: options.encoding || "utf8"
  });
  if (result.status !== 0) {
    throw new Error(`${command} exited with code ${result.status ?? 1}; command arguments redacted`);
  }
  return result;
}

function commandOutput(command, args) {
  return execFileSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  }).trim();
}

function requireTool(command) {
  try {
    commandOutput("which", [command]);
  } catch {
    throw new Error(`${command} is required for client CLI VM workflows.`);
  }
}

function resolveFirmware() {
  const firmware = firmwareCandidates.find((candidate) => existsSync(candidate));
  if (!firmware) {
    throw new Error("AArch64 UEFI firmware is required. Set LICO_CLIENT_CLI_VM_EFI to an edk2 aarch64 firmware path.");
  }
  return firmware;
}

function imageUrlFor(distro) {
  const envName = distro.imageUrlEnv || `LICO_CLIENT_CLI_VM_${distro.id.toUpperCase()}_IMAGE_URL`;
  return process.env[envName] || distro.imageUrl || "";
}

function selectedDistros(options) {
  const known = new Map(matrix.distros.map((distro) => [distro.id, distro]));
  if (options.distros.length === 0) {
    return matrix.distros.filter((distro) => !distro.manualImageRequired || options.includeManual || imageUrlFor(distro));
  }
  return options.distros.map((id) => {
    const distro = known.get(id);
    if (!distro) {
      throw new Error(`Unknown client CLI VM distro: ${id}`);
    }
    return distro;
  });
}

function ensureSshKey() {
  const sshRoot = path.join(cacheRoot(), "ssh");
  const keyPath = path.join(sshRoot, "id_ed25519");
  mkdirSync(sshRoot, { recursive: true });
  if (!existsSync(keyPath)) {
    run("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", keyPath, "-C", "lico-client-cli-vm"], {
      stdio: "ignore"
    });
    chmodSync(keyPath, 0o600);
  }
  return {
    keyPath,
    publicKey: readFileSync(`${keyPath}.pub`, "utf8").trim()
  };
}

function downloadImage(distro) {
  const vmPaths = pathsFor(distro);
  const url = imageUrlFor(distro);
  if (!url) {
    throw new Error(`${distro.id} requires ${distro.imageUrlEnv || `LICO_CLIENT_CLI_VM_${distro.id.toUpperCase()}_IMAGE_URL`}.`);
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
    url
  ];
  let status = 1;
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    const result = spawnSync("curl", args, {
      cwd: repoRoot,
      stdio: "inherit"
    });
    status = result.status ?? 1;
    if (status === 0) {
      break;
    }
    console.warn(`[client-cli-vm] Download attempt ${attempt} for ${distro.id} failed; retrying with resume.`);
  }
  if (status !== 0) {
    throw new Error(`Unable to download ${distro.id} ARM64 image after resumable retries.`);
  }
  renameSync(partial, vmPaths.baseImage);
}

function createDisk(distro, options) {
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
    options.diskSize
  ]);
}

function seedUserData(distro, publicKey) {
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
      ""
    ].join("\n"),
    "utf8"
  );
  writeFileSync(
    path.join(vmPaths.seedDir, "meta-data"),
    [
      `instance-id: lico-${distro.id}-arm64`,
      `local-hostname: lico-${distro.id}-arm64`,
      ""
    ].join("\n"),
    "utf8"
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
    vmPaths.seedDir
  ]);
}

function prepareDistro(distro, options) {
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

function runningPid(distro) {
  const pidFile = pathsFor(distro).pidFile;
  if (!existsSync(pidFile)) {
    return 0;
  }
  const pid = Number(readFileSync(pidFile, "utf8").trim());
  if (!pid) {
    return 0;
  }
  try {
    process.kill(pid, 0);
    return pid;
  } catch {
    rmSync(pidFile, { force: true });
    return 0;
  }
}

function sshBaseArgs(distro) {
  const { keyPath } = ensureSshKey();
  return [
    "-i",
    keyPath,
    "-p",
    String(distro.sshPort),
    "-o",
    "BatchMode=yes",
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "LogLevel=ERROR",
    `${vmUser}@127.0.0.1`
  ];
}

function quoteShellArg(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function sshRsyncCommand(distro) {
  return ["ssh", ...sshBaseArgs(distro).slice(0, -1)].map(quoteShellArg).join(" ");
}

function runSsh(distro, command, options = {}) {
  return run("ssh", [...sshBaseArgs(distro), `bash -lc ${quoteShellArg(command)}`], {
    stdio: options.stdio || "inherit",
    encoding: options.encoding || "utf8"
  });
}

function startDistro(distro, options) {
  requireTool("qemu-system-aarch64");
  const pid = runningPid(distro);
  if (pid) {
    console.log(`[client-cli-vm] ${distro.id} already running.`);
    return;
  }
  const vmPaths = pathsFor(distro);
  const firmware = resolveFirmware();
  mkdirSync(vmPaths.vmRoot, { recursive: true });
  rmSync(vmPaths.serialLog, { force: true });
  const accel = process.env.LICO_CLIENT_CLI_VM_ACCEL || (process.platform === "darwin" ? "hvf" : "tcg");
  const cpu = accel === "hvf" ? "host" : "max";
  const machine = accel === "none" ? "virt,highmem=on" : `virt,accel=${accel},highmem=on`;
  run("qemu-system-aarch64", [
    "-machine",
    machine,
    "-cpu",
    cpu,
    "-m",
    options.memory,
    "-smp",
    options.cpus,
    "-drive",
    `if=pflash,format=raw,readonly=on,file=${firmware}`,
    "-drive",
    `if=virtio,format=qcow2,file=${vmPaths.disk}`,
    "-drive",
    `if=virtio,format=raw,media=cdrom,file=${vmPaths.seedIso}`,
    "-device",
    "virtio-rng-pci",
    "-netdev",
    `user,id=net0,hostfwd=tcp:127.0.0.1:${distro.sshPort}-:22`,
    "-device",
    "virtio-net-pci,netdev=net0",
    "-display",
    "none",
    "-serial",
    `file:${vmPaths.serialLog}`,
    "-monitor",
    `unix:${vmPaths.monitorSocket},server,nowait`,
    "-pidfile",
    vmPaths.pidFile,
    "-daemonize"
  ]);
  console.log(`[client-cli-vm] Started ${distro.id} ARM64 VM.`);
}

function waitForSsh(distro, timeoutSeconds) {
  const started = Date.now();
  while ((Date.now() - started) / 1000 < timeoutSeconds) {
    const result = spawnSync("ssh", [
      ...sshBaseArgs(distro),
      "-o",
      "ConnectTimeout=5",
      "true"
    ], {
      stdio: "ignore"
    });
    if (result.status === 0) {
      return;
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 3000);
  }
  throw new Error(`${distro.id} did not become reachable over SSH within ${timeoutSeconds}s.`);
}

function bootstrapCommand(distro) {
  const install = {
    apt: [
      "sudo env DEBIAN_FRONTEND=noninteractive apt-get update",
      "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl build-essential pkg-config git rsync file tar gzip python3 nodejs libdbus-1-dev dbus-x11 gnome-keyring libsecret-tools"
    ],
    dnf: [
      "sudo dnf -y install ca-certificates curl gcc gcc-c++ make pkgconf-pkg-config git rsync file tar gzip which python3 nodejs dbus-devel dbus-x11 gnome-keyring libsecret"
    ],
    zypper: [
      "sudo zypper --non-interactive refresh",
      "sudo zypper --non-interactive install ca-certificates curl gcc gcc-c++ make pkg-config git rsync file tar gzip which python3 nodejs dbus-1-devel dbus-1-x11 gnome-keyring libsecret-devel"
    ],
    pacman: [
      "sudo pacman -Sy --noconfirm --needed ca-certificates curl base-devel git rsync file tar gzip which python nodejs dbus gnome-keyring libsecret"
    ]
  }[distro.packageManager];
  if (!install) {
    throw new Error(`Unsupported package manager for ${distro.id}: ${distro.packageManager}`);
  }
  return [
    "set -euo pipefail",
    ...install,
    "mkdir -p \"$HOME/.cache/licolite\"",
    `if [ ! -x "$HOME/.cargo/bin/rustup" ] || ! "$HOME/.cargo/bin/rustup" --version 2>/dev/null | grep -Fq "rustup ${linuxProductRustupVersion} " || [ "$(cat "$HOME/.cache/licolite/rustup-init.verified" 2>/dev/null || true)" != "${linuxProductRustupArm64Sha256}" ]; then curl --retry 3 --retry-connrefused --retry-delay 2 -fsSL https://static.rust-lang.org/rustup/archive/${linuxProductRustupVersion}/aarch64-unknown-linux-gnu/rustup-init -o "$HOME/.cache/licolite/rustup-init" && printf '%s  %s\\n' ${linuxProductRustupArm64Sha256} "$HOME/.cache/licolite/rustup-init" | sha256sum -c - >/dev/null && chmod 0700 "$HOME/.cache/licolite/rustup-init" && "$HOME/.cache/licolite/rustup-init" -y --profile minimal --default-toolchain none --no-modify-path >/dev/null 2>&1 && printf '%s\\n' ${linuxProductRustupArm64Sha256} > "$HOME/.cache/licolite/rustup-init.verified" && rm -f "$HOME/.cache/licolite/rustup-init"; fi`,
    "export PATH=\"$HOME/.cargo/bin:$PATH\"",
    `rustup toolchain install ${linuxProductRustVersion} --profile minimal >/dev/null 2>&1`,
    `rustup default ${linuxProductRustVersion} >/dev/null 2>&1`,
    `rustup target add aarch64-unknown-linux-gnu --toolchain ${linuxProductRustVersion} >/dev/null`,
    "uname -m",
    "rustc --version",
    "cargo --version"
  ].join(" && ");
}

function linuxProductBootstrapCommand(distro) {
  if (distro.id !== "ubuntu" || distro.packageManager !== "apt") {
    throw new Error("Linux product acceptance currently requires the configured Ubuntu ARM64 VM.");
  }
  return [
    "set -euo pipefail",
    "sudo timeout 180 cloud-init status --wait >/dev/null 2>&1 || true",
    "for attempt in 1 2 3 4 5; do if sudo timeout 240 env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update >/dev/null 2>&1; then break; fi; [ \"$attempt\" != 5 ] || exit 1; sleep 3; done",
    "for attempt in 1 2 3 4 5; do if sudo timeout 360 env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y build-essential ca-certificates clang cmake curl dbus-x11 docker.io file git libdbus-1-dev libgtk-3-dev liblzma-dev libsecret-1-dev libstdc++-12-dev ninja-build openssl pkg-config python3 rsync tar unzip xdotool xz-utils xvfb zip >/dev/null 2>&1; then break; fi; [ \"$attempt\" != 5 ] || exit 1; sleep 3; done",
    "printf '%s\\n' '{\"step\":\"package_manager_ready\"}'",
    "mkdir -p \"$HOME/.local/node\" \"$HOME/.local\" \"$HOME/.cache/licolite\"",
    `if [ ! -x "$HOME/.cargo/bin/rustup" ] || ! "$HOME/.cargo/bin/rustup" --version 2>/dev/null | grep -Fq "rustup ${linuxProductRustupVersion} " || [ "$(cat "$HOME/.cache/licolite/rustup-init.verified" 2>/dev/null || true)" != "${linuxProductRustupArm64Sha256}" ]; then curl --retry 3 --retry-connrefused --retry-delay 2 -fsSL https://static.rust-lang.org/rustup/archive/${linuxProductRustupVersion}/aarch64-unknown-linux-gnu/rustup-init -o "$HOME/.cache/licolite/rustup-init" && printf '%s  %s\\n' ${linuxProductRustupArm64Sha256} "$HOME/.cache/licolite/rustup-init" | sha256sum -c - >/dev/null && chmod 0700 "$HOME/.cache/licolite/rustup-init" && "$HOME/.cache/licolite/rustup-init" -y --profile minimal --default-toolchain none --no-modify-path >/dev/null 2>&1 && printf '%s\\n' ${linuxProductRustupArm64Sha256} > "$HOME/.cache/licolite/rustup-init.verified" && rm -f "$HOME/.cache/licolite/rustup-init"; fi`,
    "export PATH=\"$HOME/.local/node/bin:$HOME/.local/flutter/bin:$HOME/.cargo/bin:$PATH\"",
    `rustup toolchain install ${linuxProductRustVersion} --profile minimal >/dev/null 2>&1`,
    `rustup default ${linuxProductRustVersion} >/dev/null 2>&1`,
    `rustup target add aarch64-unknown-linux-gnu --toolchain ${linuxProductRustVersion} >/dev/null 2>&1`,
    `rustc --version | grep -Fq "rustc ${linuxProductRustVersion} "`,
    "printf '%s\\n' '{\"step\":\"rust_toolchain_ready\"}'",
    `if [ ! -x "$HOME/.local/node/bin/node" ] || [ "$("$HOME/.local/node/bin/node" --version)" != "v${linuxProductNodeVersion}" ] || [ "$(cat "$HOME/.cache/licolite/node.verified" 2>/dev/null || true)" != "${linuxProductNodeArm64Sha256}" ]; then rm -rf "$HOME/.local/node" && mkdir -p "$HOME/.local/node" && curl --retry 3 --retry-connrefused --retry-delay 2 -fsSL https://nodejs.org/dist/v${linuxProductNodeVersion}/node-v${linuxProductNodeVersion}-linux-arm64.tar.xz -o "$HOME/.cache/licolite/node.tar.xz" && printf '%s  %s\\n' ${linuxProductNodeArm64Sha256} "$HOME/.cache/licolite/node.tar.xz" | sha256sum -c - >/dev/null && tar -xJf "$HOME/.cache/licolite/node.tar.xz" -C "$HOME/.local/node" --strip-components=1 && printf '%s\\n' ${linuxProductNodeArm64Sha256} > "$HOME/.cache/licolite/node.verified" && rm -f "$HOME/.cache/licolite/node.tar.xz"; fi`,
    "printf '%s\\n' '{\"step\":\"node_toolchain_ready\"}'",
    `if [ ! -x "$HOME/.local/flutter/bin/flutter" ] || [ "$(git -C "$HOME/.local/flutter" rev-parse HEAD 2>/dev/null || true)" != "${linuxProductFlutterCommit}" ]; then rm -rf "$HOME/.local/flutter" && git -c advice.detachedHead=false clone --quiet --filter=blob:none --depth 1 --branch ${linuxProductFlutterVersion} https://github.com/flutter/flutter.git "$HOME/.local/flutter"; fi`,
    `test "$(git -C "$HOME/.local/flutter" rev-parse HEAD)" = "${linuxProductFlutterCommit}"`,
    "git config --global --add safe.directory \"$HOME/.local/flutter\"",
    "flutter --version >/dev/null 2>&1",
    "printf '%s\\n' '{\"step\":\"flutter_arm64_source_toolchain_ready\"}'",
    "flutter config --enable-linux-desktop --no-analytics >/dev/null 2>&1",
    "flutter precache --linux >/dev/null 2>&1",
    "sudo systemctl start docker >/dev/null 2>&1",
    "sudo docker info >/dev/null 2>&1",
    "printf '%s\\n' '{\"ok\":true,\"linuxProductToolchainReady\":true}'"
  ].join(" && ");
}

function linuxProductCommand(distro, expectedSourceDigest, releaseBinding) {
  if (distro.id !== "ubuntu" || !/^sha256:[a-f0-9]{64}$/u.test(expectedSourceDigest)) {
    throw new Error("Linux product acceptance source binding is invalid.");
  }
  if (!releaseBinding?.challenge || !releaseBinding?.invocationNonce ||
    !Number.isFinite(Date.parse(String(releaseBinding?.startedAt || "")))) {
    throw new Error("Linux product release-closure binding is invalid.");
  }
  const archive = "$HOME/lico-arc/build/apps/desktop/distribution/linux-arm64/LicoArc-linux-arm64.tar.gz";
  const distributionManifest = "$HOME/lico-arc/build/apps/desktop/distribution/linux-arm64/manifest.json";
  const vmReceipt = "$HOME/lico-product-artifacts/secure-mesh-linux-vm-package-receipt.json";
  const nodeMatrix = "$HOME/lico-product-artifacts/secure-mesh-linux-node-matrix.json";
  const releaseCliReport = "$HOME/lico-arc/build/apps/desktop/distribution/linux-arm64/secure-mesh-release-cli-proof.json";
  const archivedCli = "$LICO_VM_PRODUCT_ROOT/release-cli/bundle/lico-client";
  const generateValidationKey = [
    "const {generateKeyPairSync}=require('node:crypto')",
    "const fs=require('node:fs')",
    "const {privateKey}=generateKeyPairSync('ed25519')",
    "fs.writeFileSync(process.argv[1],privateKey.export({type:'pkcs8',format:'pem'}),{mode:0o600})"
  ].join(";");
  const ownerOnlyDirectoryFunction = linuxProductOwnerOnlyDirectoryFunction();
  const prepareReportRoot = linuxProductReportRootPreparationCommand();
  const prepareDistributionReportTree =
    linuxProductDistributionReportTreePreparationCommand();
  return [
    "set -euo pipefail",
    ". \"$HOME/.cargo/env\"",
    "export PATH=\"$HOME/.local/node/bin:$HOME/.local/flutter/bin:$HOME/.cargo/bin:$PATH\"",
    "export PUB_CACHE=\"$HOME/.cache/licolite/pub-cache\"",
    "export CARGO_TARGET_DIR=\"$HOME/.cache/licolite/cargo-target\"",
    "export CARGO_BUILD_JOBS=1",
    "export CMAKE_BUILD_PARALLEL_LEVEL=1",
    "export LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST=" + quoteShellArg(expectedSourceDigest),
    "export LICO_CLIENT_RELEASE_CLOSURE_CHALLENGE=" +
      quoteShellArg(releaseBinding.challenge),
    "export LICO_CLIENT_RELEASE_CLOSURE_STARTED_AT=" +
      quoteShellArg(releaseBinding.startedAt),
    "export LICO_CLIENT_RELEASE_INVOCATION_NONCE=" +
      quoteShellArg(releaseBinding.invocationNonce),
    "export LICO_VM_PRODUCT_ROOT=\"$HOME/.cache/licolite/linux-product\"",
    "export LICO_LINUX_VM_REPORT_ROOT=\"$HOME/lico-product-artifacts\"",
    "export LICO_LINUX_RELEASE_SIGNING_KEY_PATH=\"$LICO_VM_PRODUCT_ROOT/validation-key.pem\"",
    "export LICO_LINUX_RELEASE_SIGNING_KEY_ID=linux-vm-acceptance",
    ownerOnlyDirectoryFunction,
    prepareReportRoot,
    "trap 'rm -f \"$LICO_LINUX_RELEASE_SIGNING_KEY_PATH\"' EXIT",
    "cd \"$HOME/lico-arc\"",
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
    "rm -rf \"$LICO_VM_PRODUCT_ROOT/release-cli\"",
    "mkdir -p \"$LICO_VM_PRODUCT_ROOT/release-cli\"",
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
    `cp "${archive}" "$HOME/lico-product-artifacts/LicoArc-linux-arm64.tar.gz"`,
    `cp "${archive}.sig" "$HOME/lico-product-artifacts/LicoArc-linux-arm64.tar.gz.sig"`,
    `cp "${distributionManifest}" "$HOME/lico-product-artifacts/linux-arm64-manifest.json"`,
    `cp "$HOME/lico-arc/${linuxSourceManifestRemoteRef}" "$HOME/lico-product-artifacts/${linuxSourceManifestName}"`,
    "printf '%s\\n' '{\"ok\":true,\"currentSourceArchive\":true,\"vmInstallReceiptReady\":true,\"archivedReleaseCliProofReady\":true,\"threeNodeMatrixReady\":true}'"
  ].join(" && ");
}

function linuxProductOwnerOnlyDirectoryFunction() {
  const checks = [
    "directory=\"$1\"",
    "test ! -L \"$directory\"",
    "install -d -m 0700 \"$directory\"",
    "test -d \"$directory\"",
    "test ! -L \"$directory\"",
    "test \"$(stat -c '%u' \"$directory\")\" = \"$(id -u)\"",
    "test \"$(stat -c '%a' \"$directory\")\" = 700"
  ].join(" && ");
  return `lico_owner_only_directory() { ${checks}; }`;
}

function linuxProductReportRootPreparationCommand() {
  return [
    "test ! -L \"$LICO_VM_PRODUCT_ROOT\"",
    "rm -rf \"$LICO_VM_PRODUCT_ROOT\"",
    "test ! -L \"$LICO_LINUX_VM_REPORT_ROOT\"",
    "rm -rf \"$LICO_LINUX_VM_REPORT_ROOT\"",
    "lico_owner_only_directory \"$LICO_VM_PRODUCT_ROOT\"",
    "lico_owner_only_directory \"$LICO_LINUX_VM_REPORT_ROOT\""
  ].join(" && ");
}

function linuxProductDistributionReportTreePreparationCommand() {
  return [
    "$HOME/lico-arc/build",
    "$HOME/lico-arc/build/apps",
    "$HOME/lico-arc/build/apps/desktop",
    "$HOME/lico-arc/build/apps/desktop/distribution",
    "$HOME/lico-arc/build/apps/desktop/distribution/linux-arm64",
  ].map((directory) => `lico_owner_only_directory \"${directory}\"`).join(" && ");
}

function verifyCommand(distro) {
  const artifactName = `lico-client-${distro.id}-linux-arm64`;
  const assertSecretServicePlatformBinding = [
    "const fs=require('node:fs')",
    "const report=JSON.parse(fs.readFileSync(process.argv[1],'utf8'))",
    "const secretStore=report.secretStore||{}",
    "const allPrivateKeysBoundToPlatform=secretStore.allPrivateKeysInSelectedCustody===true",
    "const pairingSecretBoundToPlatform=secretStore.pairingSecretInSelectedCustody===true",
    "const ready=report.ok===true&&report.selfTestPassed===true&&report.backend==='linux-secret-service-keyring'&&allPrivateKeysBoundToPlatform&&pairingSecretBoundToPlatform&&secretStore.unsafePersistenceDetected!==true&&report.portableConfigPrivateMaterialRedacted===true&&Number(report.ordinaryFileSecretArtifactCount)===0",
    "if(!ready)process.exit(1)",
    "process.stdout.write(JSON.stringify({ok:true,allPrivateKeysBoundToPlatform,pairingSecretBoundToPlatform,rawPrivateMaterialIncluded:false})+'\\n')"
  ].join(";");
  const secretServiceSessionCommand = (commands) =>
    `dbus-run-session -- bash -lc ${quoteShellArg([
      "export LICO_VM_ORIGINAL_HOME=\"$HOME\"",
      "export CARGO_HOME=\"$LICO_VM_ORIGINAL_HOME/.cargo\"",
      "export RUSTUP_HOME=\"$LICO_VM_ORIGINAL_HOME/.rustup\"",
      "export LICO_VM_SECRET_HOME=\"$(mktemp -d)\"",
      "trap 'rm -rf \"$LICO_VM_SECRET_HOME\"' EXIT",
      "export HOME=\"$LICO_VM_SECRET_HOME\"",
      "printf '%s' 'pass' | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1",
      ...commands
    ].join(" && "))} 2>/dev/null`;
  const ubuntuSecretStoreCommand = secretServiceSessionCommand([
    "export LICO_PORTABLE_DIR=\"$(mktemp -d)\"",
    `"$LICO_VM_ORIGINAL_HOME/lico-artifacts/${artifactName}" mobile relay e2ee secret-store-self-test > "$LICO_VM_ORIGINAL_HOME/lico-artifacts/mobile-relay-secret-store-self-test.json"`,
    `node -e ${quoteShellArg(assertSecretServicePlatformBinding)} "$LICO_VM_ORIGINAL_HOME/lico-artifacts/mobile-relay-secret-store-self-test.json"`,
    `node tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs --input-report "$LICO_VM_ORIGINAL_HOME/lico-artifacts/mobile-relay-secret-store-self-test.json" --expect-strategy os_secure_store`
  ]);
  const ubuntuSecretStoreSelfTest = distro.id === "ubuntu"
    ? [ubuntuSecretStoreCommand]
    : [];
  const cargoTestCommand = distro.id === "ubuntu"
    ? secretServiceSessionCommand([
        "cargo test --manifest-path crates/lico-client-native/Cargo.toml --locked -- --test-threads=1"
      ])
    : "cargo test --manifest-path crates/lico-client-native/Cargo.toml --locked -- --test-threads=1";
  return [
    "set -euo pipefail",
    ". \"$HOME/.cargo/env\"",
    "cd \"$HOME/lico-arc\"",
    "export CARGO_TARGET_DIR=\"$HOME/.cache/licolite/cargo-target\"",
    "export CARGO_BUILD_JOBS=1",
    "mkdir -p \"$CARGO_TARGET_DIR\" \"$HOME/lico-artifacts\"",
    cargoTestCommand,
    "cargo build --manifest-path crates/lico-client-native/Cargo.toml --locked --release --bin lico-client",
    `cp "$CARGO_TARGET_DIR/release/lico-client" "$HOME/lico-artifacts/${artifactName}"`,
    `chmod 0755 "$HOME/lico-artifacts/${artifactName}"`,
    `"$HOME/lico-artifacts/${artifactName}" --help >/tmp/lico-client-help.txt`,
    "node tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs --self-test",
    `node tools/scripts/client-secure-mesh-release-cli-proof.mjs --cli "$HOME/lico-artifacts/${artifactName}" --platform "${distro.id}-linux-arm64" --report "$HOME/lico-artifacts/secure-mesh-release-cli-proof.json"`,
    `node tools/scripts/client-secure-mesh-linux-adaptive-custody-proof.mjs --cli "$HOME/lico-artifacts/${artifactName}" --platform "${distro.id}-linux-arm64" --report "$HOME/lico-artifacts/secure-mesh-linux-adaptive-custody-proof.json"`,
    `node tools/scripts/client-secure-mesh-linux-package-update-proof.mjs --cli "$HOME/lico-artifacts/${artifactName}" --platform "${distro.id}-linux-arm64" --package-output "$HOME/lico-artifacts/${artifactName}.tar.gz" --report "$HOME/lico-artifacts/secure-mesh-linux-package-update-proof.json"`,
    ...ubuntuSecretStoreSelfTest,
    "uname -a > \"$HOME/lico-artifacts/uname.txt\"",
    "rustc -Vv > \"$HOME/lico-artifacts/rustc.txt\"",
    `file "$HOME/lico-artifacts/${artifactName}" > "$HOME/lico-artifacts/file.txt"`,
    `(cd "$HOME/lico-artifacts" && sha256sum "${artifactName}" > SHA256SUMS)`
  ].join(" && ");
}

const repoSyncExcludes = Object.freeze([
  ".git",
  ".lico-source-attestation",
  "node_modules",
  "build",
  "target",
  "apps/desktop/.dart_tool",
  "apps/desktop/build",
  "apps/desktop/android/.gradle",
  "apps/desktop/android/build",
  "apps/desktop/ios/build",
]);

function syncRepoToVm(distro) {
  runSsh(distro, "mkdir -p \"$HOME/lico-arc\"");
  run("rsync", [
    "-az",
    "--delete",
    ...repoSyncExcludes.map((value) => `--exclude=${value}`),
    "-e",
    sshRsyncCommand(distro),
    `${repoRoot}/`,
    `${vmUser}@127.0.0.1:~/lico-arc/`
  ]);
}

function fetchArtifacts(distro, remoteDirectory = "lico-artifacts") {
  if (!["lico-artifacts", "lico-product-artifacts"].includes(remoteDirectory)) {
    throw new Error("Client CLI VM artifact directory is invalid.");
  }
  const vmPaths = pathsFor(distro);
  mkdirSync(vmPaths.artifactRoot, { recursive: true });
  run("rsync", [
    "-az",
    "--delete",
    "-e",
    sshRsyncCommand(distro),
    `${vmUser}@127.0.0.1:~/${remoteDirectory}/`,
    `${vmPaths.artifactRoot}/`
  ]);
  console.log(JSON.stringify({
    ok: true,
    target: `${distro.id}-linux-arm64`,
    artifactsFetched: true,
    localPathIncluded: false
  }));
}

function shutdownDistro(distro) {
  if (!runningPid(distro)) {
    return;
  }
  spawnSync("ssh", [...sshBaseArgs(distro), "sudo", "poweroff"], { stdio: "ignore" });
  const started = Date.now();
  while ((Date.now() - started) < 60000) {
    if (!runningPid(distro)) {
      return;
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);
  }
  const pid = runningPid(distro);
  if (pid) {
    process.kill(pid, "SIGTERM");
    rmSync(pathsFor(distro).pidFile, { force: true });
  }
}

function destroyDistro(distro) {
  shutdownDistro(distro);
  rmSync(pathsFor(distro).vmRoot, { recursive: true, force: true });
  console.log(`[client-cli-vm] Destroyed ${distro.id} VM state.`);
}

function verifyDistro(distro, options) {
  prepareDistro(distro, options);
  startDistro(distro, options);
  waitForSsh(distro, options.bootTimeoutSeconds);
  try {
    console.log(`[client-cli-vm] Bootstrapping ${distro.id}.`);
    runSsh(distro, bootstrapCommand(distro), { stdio: "ignore" });
    console.log(`[client-cli-vm] Syncing repository to ${distro.id}.`);
    syncRepoToVm(distro);
    console.log(`[client-cli-vm] Verifying lico-client on ${distro.id} ARM64.`);
    runSsh(distro, verifyCommand(distro));
    fetchArtifacts(distro);
  } finally {
    if (!options.keepRunning) {
      shutdownDistro(distro);
    }
  }
}

function currentClientSourceDigest() {
  return clientSourceStateDigest(repoRoot, clientSourceRoots);
}

function createLinuxProductSourceManifest(distro, sourceStateDigest) {
  const artifacts = linuxProductArtifactPaths(distro);
  const manifest = createClientSourceManifest(
    repoRoot,
    clientSourceRoots,
    sourceStateDigest,
  );
  writeFileSync(artifacts.sourceManifest, `${JSON.stringify(manifest)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  verifyLinuxProductSourceManifest(distro, sourceStateDigest);
  return manifest.manifestDigest;
}

function verifyLinuxProductSourceManifest(distro, sourceStateDigest) {
  return readAndVerifyClientSourceManifest(
    repoRoot,
    linuxProductArtifactPaths(distro).sourceManifest,
    sourceStateDigest,
    { expectedSourceRoots: clientSourceRoots },
  );
}

function syncLinuxProductSourceManifest(distro) {
  const artifacts = linuxProductArtifactPaths(distro);
  runSsh(distro, "rm -rf \"$HOME/lico-arc/.lico-source-attestation\" && " +
    "mkdir -m 0700 \"$HOME/lico-arc/.lico-source-attestation\"");
  run("rsync", [
    "-a",
    "-e",
    sshRsyncCommand(distro),
    artifacts.sourceManifest,
    `${vmUser}@127.0.0.1:~/lico-arc/${linuxSourceManifestRemoteRef}`,
  ]);
  runSsh(distro, `chmod 0600 "$HOME/lico-arc/${linuxSourceManifestRemoteRef}" && ` +
    `test "$(stat -c '%a' "$HOME/lico-arc/${linuxSourceManifestRemoteRef}")" = 600`);
}

function linuxProductArtifactPaths(distro) {
  const root = pathsFor(distro).artifactRoot;
  return {
    root,
    vmReceipt: path.join(root, "secure-mesh-linux-vm-package-receipt.json"),
    nodeMatrix: path.join(root, "secure-mesh-linux-node-matrix.json"),
    releaseCliProof: path.join(root, "secure-mesh-release-cli-proof.json"),
    archive: path.join(root, "LicoArc-linux-arm64.tar.gz"),
    signature: path.join(root, "LicoArc-linux-arm64.tar.gz.sig"),
    distributionManifest: path.join(root, "linux-arm64-manifest.json"),
    sourceManifest: path.join(root, linuxSourceManifestName),
    incomplete: path.join(root, "secure-mesh-linux-current-source-incomplete.json")
  };
}

function clearLinuxProductHostArtifacts(distro) {
  const artifacts = linuxProductArtifactPaths(distro);
  mkdirSync(artifacts.root, { recursive: true });
  for (const key of [
    "vmReceipt",
    "nodeMatrix",
    "releaseCliProof",
    "archive",
    "signature",
    "distributionManifest",
    "sourceManifest",
    "incomplete"
  ]) {
    rmSync(artifacts[key], { force: true });
  }
}

function writeLinuxProductIncomplete(distro, reason) {
  const artifacts = linuxProductArtifactPaths(distro);
  mkdirSync(artifacts.root, { recursive: true });
  for (const key of ["vmReceipt", "nodeMatrix", "releaseCliProof", "archive", "signature", "distributionManifest", "sourceManifest"]) {
    rmSync(artifacts[key], { force: true });
  }
  writeFileSync(artifacts.incomplete, `${JSON.stringify({
    schema: "licolite.secure-mesh.linux-current-source-incomplete",
    schemaVersion: 1,
    ok: false,
    artifactKind: "linux-current-source-acceptance",
    reason,
    privacy: {
      redacted: true,
      runtimeIdentityIncluded: false,
      localPathIncluded: false,
      rawLogsIncluded: false,
      rawSecretsIncluded: false
    }
  }, null, 2)}\n`, "utf8");
}

function validateLinuxProductArtifacts(distro, expectedSourceDigest, releaseBinding) {
  const artifacts = linuxProductArtifactPaths(distro);
  if (!existsSync(artifacts.vmReceipt) || !existsSync(artifacts.nodeMatrix) ||
    !existsSync(artifacts.releaseCliProof) ||
    !existsSync(artifacts.archive) || !existsSync(artifacts.signature) ||
    !existsSync(artifacts.distributionManifest) ||
    !existsSync(artifacts.sourceManifest)) {
    throw new Error("Linux product acceptance artifacts are incomplete.");
  }
  verifyLinuxProductSourceManifest(distro, expectedSourceDigest);
  const receipt = JSON.parse(stableReadFile(artifacts.vmReceipt, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
  const nodeMatrix = JSON.parse(stableReadFile(artifacts.nodeMatrix, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
  const releaseCliProof = JSON.parse(stableReadFile(artifacts.releaseCliProof, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
  const distribution = JSON.parse(stableReadFile(artifacts.distributionManifest, {
    maxBytes: 2 * 1024 * 1024,
  }).toString("utf8"));
  const clientVersion = JSON.parse(stableReadFile(
    path.join(repoRoot, "tools/client-version.json"),
    { maxBytes: 1024 * 1024 },
  ).toString("utf8"));
  validateLinuxVmPackageReceipt(
    receipt,
    expectedSourceDigest,
    clientVersion.productVersion,
    clientVersion.buildNumber,
  );
  validateLinuxNodeMatrixReport(nodeMatrix, expectedSourceDigest);
  requireReleaseCliTargetEvidence(releaseCliProof, {
    platform: "ubuntu-linux-arm64",
    sourceStateDigest: expectedSourceDigest,
    runtimeExecutableDigest: receipt.sourceBinding.nativeClientDigest,
  });
  const archiveDigest = stableSha256File(artifacts.archive);
  const signatureBytes = decodeCanonicalBase64(
    stableReadFile(artifacts.signature, { maxBytes: 16 * 1024 }).toString("utf8").trim(),
    "Linux product signature",
  );
  const directSignatureReady = verifyLinuxArchiveDigestSignature(
    distribution,
    signatureBytes,
    archiveDigest,
  );
  if (receipt.sourceBinding.archiveDigest !== archiveDigest ||
    nodeMatrix.sourceBinding.archiveDigest !== archiveDigest ||
    distribution.targetId !== "linux-glibc-arm64" ||
    distribution.sourceStateDigest !== expectedSourceDigest ||
    distribution.productVersion !== clientVersion.productVersion ||
    distribution.buildNumber !== clientVersion.buildNumber ||
    receipt.closureChallengeDigest !==
      releaseClosureChallengeDigest(releaseBinding.challenge) ||
    receipt.invocationNonceDigest !==
      releaseInvocationNonceDigest(releaseBinding.invocationNonce) ||
    releaseCliProof.closureChallengeDigest !==
      releaseClosureChallengeDigest(releaseBinding.challenge) ||
    releaseCliProof.invocationNonceDigest !==
      releaseInvocationNonceDigest(releaseBinding.invocationNonce) ||
    distribution.signature?.algorithm !== "Ed25519" ||
    distribution.signature?.payload !== "archive-sha256-digest" ||
    distribution.signature?.keyId !== "linux-vm-acceptance" ||
    distribution.signature?.file !== "LicoArc-linux-arm64.tar.gz.sig" ||
    distribution.sha256 !== archiveDigest.slice("sha256:".length) ||
    receipt.sourceBinding.bundleManifestDigest !== distribution.bundleManifestDigest ||
    nodeMatrix.sourceBinding.bundleManifestDigest !== distribution.bundleManifestDigest ||
    directSignatureReady !== true) {
    throw new Error("Linux product artifact bindings are inconsistent.");
  }
}

function decodeCanonicalBase64(value, label) {
  const encoded = String(value || "").trim();
  if (!encoded || encoded.length > 16 * 1024 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(encoded)) {
    throw new Error(`${label} is not canonical base64.`);
  }
  const bytes = Buffer.from(encoded, "base64");
  if (!bytes.length || bytes.toString("base64") !== encoded) {
    throw new Error(`${label} is not canonical base64.`);
  }
  return bytes;
}

function verifyLinuxArchiveDigestSignature(distribution, signatureBytes, archiveDigest) {
  try {
    if (!/^sha256:[a-f0-9]{64}$/u.test(String(archiveDigest || "")) ||
      signatureBytes.length !== 64) return false;
    const publicKeyDer = decodeCanonicalBase64(
      distribution.signature?.publicKeySpkiBase64,
      "Linux product public verification key",
    );
    const publicKey = createPublicKey({ key: publicKeyDer, type: "spki", format: "der" });
    if (publicKey.asymmetricKeyType !== "ed25519") return false;
    const fingerprint = `sha256:${createHash("sha256").update(publicKeyDer).digest("hex")}`;
    return distribution.signature?.publicKeyFingerprint === fingerprint && verify(
      null,
      Buffer.from(archiveDigest.slice("sha256:".length), "hex"),
      publicKey,
      signatureBytes,
    );
  } catch {
    return false;
  }
}

function verifyLinuxProductToolchainDistro(distro, options) {
  prepareDistro(distro, options);
  startDistro(distro, options);
  waitForSsh(distro, options.bootTimeoutSeconds);
  try {
    runSsh(distro, linuxProductBootstrapCommand(distro));
    console.log(JSON.stringify({
      ok: true,
      target: "ubuntu-linux-arm64",
      nodeToolchainPinned: true,
      rustToolchainPinned: true,
      flutterSourceTagPinned: true,
      flutterCommitPinned: true,
      downloadChecksumsVerified: true,
      dockerReady: true,
      rawLogsIncluded: false
    }, null, 2));
  } finally {
    if (!options.keepRunning) shutdownDistro(distro);
  }
}

function verifyLinuxProductDistro(distro, options) {
  clearLinuxProductHostArtifacts(distro);
  const inheritedClosure = String(
    process.env.LICO_CLIENT_RELEASE_CLOSURE_CHALLENGE || "",
  ).trim();
  const releaseBinding = Object.freeze({
    challenge: inheritedClosure
      ? requiredReleaseClosureChallenge()
      : createReleaseClosureChallenge(),
    invocationNonce: inheritedClosure
      ? requiredReleaseInvocationNonce()
      : createReleaseInvocationNonce(),
    startedAt: inheritedClosure
      ? requiredReleaseClosureStartedAt().value
      : new Date().toISOString(),
  });
  const sourceBefore = currentClientSourceDigest();
  let sourceManifestDigest = "";
  prepareDistro(distro, options);
  startDistro(distro, options);
  waitForSsh(distro, options.bootTimeoutSeconds);
  try {
    console.log(`[client-cli-vm] Preparing Linux product toolchain for ${distro.id}.`);
    runSsh(distro, linuxProductBootstrapCommand(distro));
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_before_sync");
      throw new Error("Client source changed before Linux product sync; verification was not started.");
    }
    sourceManifestDigest = createLinuxProductSourceManifest(distro, sourceBefore);
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_during_manifest_creation");
      throw new Error("Client source changed while creating the Linux source manifest.");
    }
    console.log(`[client-cli-vm] Syncing current source for ${distro.id} Linux product proof.`);
    syncRepoToVm(distro);
    syncLinuxProductSourceManifest(distro);
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_during_sync");
      throw new Error("Client source changed during Linux product sync; verification was not started.");
    }
    if (verifyLinuxProductSourceManifest(distro, sourceBefore).manifestDigest !==
      sourceManifestDigest) {
      writeLinuxProductIncomplete(distro, "source_manifest_changed_during_sync");
      throw new Error("Client source manifest changed during Linux product sync.");
    }
    console.log(`[client-cli-vm] Building and verifying current Linux product on ${distro.id}.`);
    runSsh(distro, linuxProductCommand(distro, sourceBefore, releaseBinding));
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_during_verification");
      throw new Error("Client source changed during Linux product verification; ready evidence was rejected.");
    }
    if (verifyLinuxProductSourceManifest(distro, sourceBefore).manifestDigest !==
      sourceManifestDigest) {
      writeLinuxProductIncomplete(distro, "source_manifest_changed_during_verification");
      throw new Error("Client source manifest changed during Linux product verification.");
    }
    fetchArtifacts(distro, "lico-product-artifacts");
    if (currentClientSourceDigest() !== sourceBefore) {
      writeLinuxProductIncomplete(distro, "source_state_changed_during_artifact_binding");
      throw new Error("Client source changed while binding Linux product artifacts; ready evidence was rejected.");
    }
    if (verifyLinuxProductSourceManifest(distro, sourceBefore).manifestDigest !==
      sourceManifestDigest) {
      writeLinuxProductIncomplete(distro, "source_manifest_changed_during_artifact_binding");
      throw new Error("Client source manifest changed while binding Linux product artifacts.");
    }
    validateLinuxProductArtifacts(distro, sourceBefore, releaseBinding);
    rmSync(linuxProductArtifactPaths(distro).incomplete, { force: true });
    console.log(JSON.stringify({
      ok: true,
      target: "ubuntu-linux-arm64",
      currentSourceArchive: true,
      vmInstallReceiptReady: true,
      threeNodeMatrixReady: true,
      archivedReleaseCliProofReady: true,
      sourceBindingStale: false,
      runtimeDataIncluded: false
    }, null, 2));
  } catch (error) {
    if (!existsSync(linuxProductArtifactPaths(distro).incomplete)) {
      writeLinuxProductIncomplete(distro, "linux_product_verification_failed");
    }
    throw error;
  } finally {
    if (!options.keepRunning) shutdownDistro(distro);
  }
}

function printList(options) {
  const records = matrix.distros.map((distro) => {
    const vmPaths = pathsFor(distro);
    return {
      id: distro.id,
      label: distro.label,
      packageManager: distro.packageManager,
      imageConfigured: Boolean(imageUrlFor(distro)),
      manualImageRequired: Boolean(distro.manualImageRequired),
      prepared: existsSync(vmPaths.disk),
      running: Boolean(runningPid(distro)),
      note: distro.note || undefined
    };
  });
  console.log(JSON.stringify({
    ok: true,
    architecture: matrix.architecture,
    cacheRoot: "<client-cli-vm-cache-root>",
    distros: records,
    selected: selectedDistros(options).map((distro) => distro.id)
  }, null, 2));
}

function ensureCoreTools() {
  requireTool("ssh");
  requireTool("rsync");
}

function runScriptSelfTest() {
  const ubuntu = matrix.distros.find((distro) => distro.id === "ubuntu");
  if (!ubuntu) throw new Error("client CLI VM matrix has no Ubuntu entry");
  const command = verifyCommand(ubuntu);
  const productCommand = linuxProductCommand(ubuntu, `sha256:${"a".repeat(64)}`, {
    challenge: "A".repeat(43),
    invocationNonce: "B".repeat(43),
    startedAt: "2026-01-01T00:00:00.000Z",
  });
  const ownerOnlyDirectoryFunction = linuxProductOwnerOnlyDirectoryFunction();
  const reportRootPreparation = linuxProductReportRootPreparationCommand();
  const distributionReportTreePreparation =
    linuxProductDistributionReportTreePreparationCommand();
  const productBootstrapCommand = linuxProductBootstrapCommand(ubuntu);
  const requiredTokens = [
    "--self-test",
    "--expect-strategy os_secure_store",
    "--platform \"ubuntu-linux-arm64\"",
    "secure-mesh-linux-adaptive-custody-proof.json",
    "mobile-relay-secret-store-self-test.json"
  ];
  if (!requiredTokens.every((token) => command.includes(token))) {
    throw new Error("client CLI VM verification command omitted an adaptive Linux custody check");
  }
  const retiredAuthorities = [
    ["production", "Ready"].join(""),
    ["--expected", "-backend"].join("")
  ];
  for (const retired of retiredAuthorities) {
    if (command.includes(retired)) {
      throw new Error("client CLI VM verification command retained a fixed readiness authority");
    }
  }
  for (const token of [
    "client:build:linux",
    "client:archive:linux-arm64",
    "client-secure-mesh-linux-vm-package-receipt.mjs",
    "client-secure-mesh-linux-node-matrix.mjs",
    "linux-vm-acceptance",
    "secure-mesh-linux-vm-package-receipt.json",
    "secure-mesh-linux-node-matrix.json"
    ,"secure-mesh-release-cli-proof.json"
    ,"archived_release_cli_proof_ready"
    ,"LICO_CLIENT_RELEASE_CLOSURE_CHALLENGE"
    ,"LICO_CLIENT_RELEASE_INVOCATION_NONCE"
    ,"LICO_LINUX_VM_REPORT_ROOT"
    ,"LICO_CLIENT_EXPECTED_SOURCE_STATE_DIGEST"
    ,"client-source-manifest-verify.mjs"
    ,"source_manifest_verified_before_build"
    ,"source_manifest_verified_after_build"
    ,linuxSourceManifestRemoteRef
  ]) {
    if (!productCommand.includes(token)) {
      throw new Error("client CLI VM Linux product command omitted a required current-client proof");
    }
  }
  if ((productCommand.match(/client-source-manifest-verify\.mjs/gu) || []).length !== 2 ||
    (productCommand.match(/export LICO_CLIENT_[A-Z_]*SOURCE[A-Z_]*=/gu) || []).length !== 1) {
    throw new Error("client CLI VM retained environment-only source attestation");
  }
  const symlinkCheck = "test ! -L \"$LICO_LINUX_VM_REPORT_ROOT\"";
  const removeUnsafeRoot = "rm -rf \"$LICO_LINUX_VM_REPORT_ROOT\"";
  if (!productCommand.includes(reportRootPreparation) ||
    !productCommand.includes(ownerOnlyDirectoryFunction) ||
    !productCommand.includes(distributionReportTreePreparation) ||
    reportRootPreparation.indexOf(symlinkCheck) < 0 ||
    reportRootPreparation.indexOf(symlinkCheck) > reportRootPreparation.indexOf(removeUnsafeRoot) ||
    !reportRootPreparation.includes("lico_owner_only_directory \"$LICO_VM_PRODUCT_ROOT\"") ||
    !reportRootPreparation.includes("lico_owner_only_directory \"$LICO_LINUX_VM_REPORT_ROOT\"") ||
    !ownerOnlyDirectoryFunction.includes("install -d -m 0700") ||
    !ownerOnlyDirectoryFunction.includes("stat -c '%u'") ||
    !ownerOnlyDirectoryFunction.includes("stat -c '%a'") ||
    !ownerOnlyDirectoryFunction.includes("= 700") ||
    (distributionReportTreePreparation.match(/lico_owner_only_directory/gu) || []).length !== 5 ||
    productCommand.indexOf(distributionReportTreePreparation) >
      productCommand.indexOf("client-secure-mesh-release-cli-proof.mjs")) {
    throw new Error("client CLI VM Linux report root is not owner-only and symlink-safe");
  }
  if (!repoSyncExcludes.includes(".git") ||
    !repoSyncExcludes.includes(".lico-source-attestation")) {
    throw new Error("client CLI VM repository sync included noncanonical source authority");
  }
  for (const token of [
    "git -c advice.detachedHead=false clone --quiet --filter=blob:none --depth 1 --branch",
    "flutter_arm64_source_toolchain_ready",
    `v${linuxProductNodeVersion}`,
    linuxProductNodeArm64Sha256,
    linuxProductFlutterVersion,
    linuxProductFlutterCommit,
    `rustup ${linuxProductRustupVersion}`,
    linuxProductRustVersion,
    linuxProductRustupArm64Sha256,
    "rust_toolchain_ready"
  ]) {
    if (!productBootstrapCommand.includes(token)) {
      throw new Error("client CLI VM Linux product bootstrap omitted a pinned ARM64 toolchain check");
    }
  }
  if (productBootstrapCommand.includes("flutter_linux_arm64_")) {
    throw new Error("client CLI VM Linux product bootstrap retained a nonexistent ARM64 SDK archive");
  }
  if (productBootstrapCommand.includes(["sh", "rustup.rs"].join(".")) ||
    productBootstrapCommand.includes(["default-toolchain", "stable"].join(" "))) {
    throw new Error("client CLI VM Linux product bootstrap retained an unpinned Rust installer");
  }
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicKeyDer = publicKey.export({ type: "spki", format: "der" });
  const archiveDigest = `sha256:${"a".repeat(64)}`;
  const signatureBytes = sign(
    null,
    Buffer.from(archiveDigest.slice("sha256:".length), "hex"),
    privateKey,
  );
  const distribution = {
    signature: {
      publicKeySpkiBase64: publicKeyDer.toString("base64"),
      publicKeyFingerprint:
        `sha256:${createHash("sha256").update(publicKeyDer).digest("hex")}`,
    },
  };
  if (!verifyLinuxArchiveDigestSignature(distribution, signatureBytes, archiveDigest) ||
    verifyLinuxArchiveDigestSignature(
      distribution,
      signatureBytes,
      `sha256:${"b".repeat(64)}`,
    )) {
    throw new Error("Linux product host signature verification is not fail closed");
  }
  console.log(JSON.stringify({
    ok: true,
    schemaVersion: "licolite.client-cli-vm.self-test.v1",
    exactCapabilityInputValidationReady: true,
    unavailableServiceFallbackProofReady: true,
    unlockedServiceOsStoreProofReady: true,
    currentSourceArchiveBindingReady: true,
    linuxVmInstallSessionSmokeReady: true,
    archivedReleaseCliProofReady: true,
    directArchiveSignatureVerificationReady: true,
    isolatedLinuxNodeMatrixReady: true,
    staleSourceRejectionReady: true,
    hostileUmaskReportRootReady: true,
    unsafeExistingReportRootReplaced: true,
    reportRootSymlinkRejected: true,
    distributionReportAncestorTreeReady: true,
    downstreamLinuxReportRootsAudited: true,
    fixedReadinessAuthorityRemoved: true,
    runtimeDataIncluded: false
  }, null, 2));
}

function main() {
  const options = parseArgs();
  if (options.action === "self-test") {
    runScriptSelfTest();
    return;
  }
  ensureCoreTools();
  const distros = selectedDistros(options);
  if (options.action === "list") {
    printList(options);
    return;
  }
  if (distros.length === 0) {
    throw new Error("No client CLI VM distros selected.");
  }
  for (const distro of distros) {
    if (options.action === "prepare") {
      prepareDistro(distro, options);
    } else if (options.action === "up") {
      prepareDistro(distro, options);
      startDistro(distro, options);
      waitForSsh(distro, options.bootTimeoutSeconds);
    } else if (options.action === "sync") {
      prepareDistro(distro, options);
      startDistro(distro, options);
      waitForSsh(distro, options.bootTimeoutSeconds);
      syncRepoToVm(distro);
    } else if (options.action === "fetch") {
      fetchArtifacts(distro);
    } else if (options.action === "verify") {
      verifyDistro(distro, options);
    } else if (options.action === "linux-product-bootstrap") {
      verifyLinuxProductToolchainDistro(distro, options);
    } else if (options.action === "linux-product") {
      verifyLinuxProductDistro(distro, options);
    } else if (options.action === "ssh") {
      if (distros.length !== 1) {
        throw new Error("client-cli-vm ssh requires exactly one --distro.");
      }
      run("ssh", sshBaseArgs(distro), { stdio: "inherit" });
    } else if (options.action === "run") {
      if (options.command.length === 0) {
        throw new Error("client-cli-vm run requires a command after --.");
      }
      runSsh(distro, options.command.join(" "));
    } else if (options.action === "stop") {
      shutdownDistro(distro);
    } else if (options.action === "destroy") {
      destroyDistro(distro);
    } else {
      throw new Error(`Unknown client CLI VM action: ${options.action}`);
    }
  }
}

try {
  main();
} catch (error) {
  console.error(sanitizeError(error));
  process.exitCode = 1;
}
