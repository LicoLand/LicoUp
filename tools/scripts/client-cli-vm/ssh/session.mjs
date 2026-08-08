import { vmUser } from "../constants.mjs";
import { run } from "../process.mjs";
import { ensureSshKey } from "./key.mjs";

export function quoteShellArg(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

export function sshBaseArgs(distro) {
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
    `${vmUser}@127.0.0.1`,
  ];
}

export function sshRsyncCommand(distro) {
  return ["ssh", ...sshBaseArgs(distro).slice(0, -1)].map(quoteShellArg).join(" ");
}

export function runSsh(distro, command, options = {}) {
  return run("ssh", [...sshBaseArgs(distro), `bash -lc ${quoteShellArg(command)}`], {
    stdio: options.stdio || "inherit",
    encoding: options.encoding || "utf8",
  });
}
