import { repoRoot, vmUser } from "../constants.mjs";
import { run } from "../process.mjs";
import { runSsh, sshRsyncCommand } from "../ssh/session.mjs";

export const repoSyncExcludes = Object.freeze([
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

export function syncRepoToVm(distro) {
  runSsh(distro, 'mkdir -p "$HOME/lico-arc"');
  run("rsync", [
    "-az",
    "--delete",
    ...repoSyncExcludes.map((value) => `--exclude=${value}`),
    "-e",
    sshRsyncCommand(distro),
    `${repoRoot}/`,
    `${vmUser}@127.0.0.1:~/lico-arc/`,
  ]);
}
