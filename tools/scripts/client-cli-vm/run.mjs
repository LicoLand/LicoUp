import { parseArgs } from "./cli.mjs";
import { selectedDistros } from "./distro/select.mjs";
import { verifyLinuxProductDistro } from "./linux-product/run.mjs";
import { verifyLinuxProductToolchainDistro } from "./linux-product/toolchain.mjs";
import { printList } from "./list.mjs";
import { requireTool, run } from "./process.mjs";
import { runScriptSelfTest } from "./self-test/runner.mjs";
import { sshBaseArgs, runSsh } from "./ssh/session.mjs";
import { fetchArtifacts } from "./sync/artifacts.mjs";
import { syncRepoToVm } from "./sync/repo.mjs";
import { verifyDistro } from "./verify/distro.mjs";
import {
  destroyDistro,
  shutdownDistro,
  startDistro,
  waitForSsh,
} from "./vm/lifecycle.mjs";
import { prepareDistro } from "./vm/prepare.mjs";

function ensureCoreTools() {
  requireTool("ssh");
  requireTool("rsync");
}

export function main() {
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
