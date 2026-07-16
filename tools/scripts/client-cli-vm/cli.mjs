import process from "node:process";
import {
  defaultBootTimeoutSeconds,
  defaultCpus,
  defaultDiskSize,
  defaultMemory,
} from "./constants.mjs";

export function parseArgs(argv = process.argv.slice(2)) {
  const [action = "list", ...rest] = argv;
  const options = {
    action,
    distros: [],
    includeManual: false,
    keepRunning: false,
    memory: process.env.LICO_CLIENT_CLI_VM_MEMORY || defaultMemory,
    cpus: process.env.LICO_CLIENT_CLI_VM_CPUS || defaultCpus,
    diskSize: process.env.LICO_CLIENT_CLI_VM_DISK_SIZE || defaultDiskSize,
    bootTimeoutSeconds: Number(
      process.env.LICO_CLIENT_CLI_VM_BOOT_TIMEOUT || defaultBootTimeoutSeconds,
    ),
    command: [],
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
