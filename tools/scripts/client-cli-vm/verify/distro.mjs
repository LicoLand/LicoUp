import { fetchArtifacts } from "../sync/artifacts.mjs";
import { syncRepoToVm } from "../sync/repo.mjs";
import { runSsh } from "../ssh/session.mjs";
import { prepareDistro } from "../vm/prepare.mjs";
import { shutdownDistro, startDistro, waitForSsh } from "../vm/lifecycle.mjs";
import { bootstrapCommand } from "./bootstrap.mjs";
import { verifyCommand } from "./command.mjs";

export function verifyDistro(distro, options) {
  prepareDistro(distro, options);
  startDistro(distro, options);
  waitForSsh(distro, options.bootTimeoutSeconds);
  try {
    console.log(`[client-cli-vm] Bootstrapping ${distro.id}.`);
    runSsh(distro, bootstrapCommand(distro), { stdio: "ignore" });
    console.log(`[client-cli-vm] Syncing repository to ${distro.id}.`);
    syncRepoToVm(distro);
    console.log(`[client-cli-vm] Verifying licoup on ${distro.id} ARM64.`);
    runSsh(distro, verifyCommand(distro));
    fetchArtifacts(distro);
  } finally {
    if (!options.keepRunning) {
      shutdownDistro(distro);
    }
  }
}
