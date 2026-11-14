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
]);

export const repoSyncIncludes = Object.freeze([
  "build/native-artifacts/",
  "build/native-artifacts/**",
]);

export function syncRepoToVm(distro) {
  runSsh(distro, 'mkdir -p "$HOME/lico-up"');
  run("rsync", [
    "-az",
    "--delete",
    ...repoSyncIncludes.map((value) => `--include=${value}`),
    ...repoSyncExcludes.map((value) => `--exclude=${value}`),
    "-e",
    sshRsyncCommand(distro),
    `${repoRoot}/`,
    `${vmUser}@127.0.0.1:~/lico-up/`,
  ]);
}
