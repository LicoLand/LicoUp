import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import process from "node:process";
import { resolveFirmware } from "../distro/select.mjs";
import { pathsFor } from "../paths.mjs";
import { requireTool, run } from "../process.mjs";
import { sshBaseArgs } from "../ssh/session.mjs";

export function runningPid(distro) {
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

export function startDistro(distro, options) {
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
  const accel =
    process.env.LICO_CLIENT_CLI_VM_ACCEL || (process.platform === "darwin" ? "hvf" : "tcg");
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
    "-daemonize",
  ]);
  console.log(`[client-cli-vm] Started ${distro.id} ARM64 VM.`);
}

export function waitForSsh(distro, timeoutSeconds) {
  const started = Date.now();
  while ((Date.now() - started) / 1000 < timeoutSeconds) {
    const result = spawnSync(
      "ssh",
      [...sshBaseArgs(distro), "-o", "ConnectTimeout=5", "true"],
      { stdio: "ignore" },
    );
    if (result.status === 0) {
      return;
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 3000);
  }
  throw new Error(
    `${distro.id} did not become reachable over SSH within ${timeoutSeconds}s.`,
  );
}

export function shutdownDistro(distro) {
  if (!runningPid(distro)) {
    return;
  }
  spawnSync("ssh", [...sshBaseArgs(distro), "sudo", "poweroff"], { stdio: "ignore" });
  const started = Date.now();
  while (Date.now() - started < 60000) {
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

export function destroyDistro(distro) {
  shutdownDistro(distro);
  rmSync(pathsFor(distro).vmRoot, { recursive: true, force: true });
  console.log(`[client-cli-vm] Destroyed ${distro.id} VM state.`);
}
