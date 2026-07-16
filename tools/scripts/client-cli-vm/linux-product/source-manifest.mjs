import { writeFileSync } from "node:fs";
import {
  createClientSourceManifest,
  readAndVerifyClientSourceManifest,
  clientSourceStateDigest,
} from "../../lib/client-source-state-digest.mjs";
import { clientSourceRoots, linuxSourceManifestRemoteRef, repoRoot, vmUser } from "../constants.mjs";
import { run } from "../process.mjs";
import { runSsh, sshRsyncCommand } from "../ssh/session.mjs";
import { linuxProductArtifactPaths } from "./artifacts.mjs";

export function currentClientSourceDigest() {
  return clientSourceStateDigest(repoRoot, clientSourceRoots);
}

export function createLinuxProductSourceManifest(distro, sourceStateDigest) {
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

export function verifyLinuxProductSourceManifest(distro, sourceStateDigest) {
  return readAndVerifyClientSourceManifest(
    repoRoot,
    linuxProductArtifactPaths(distro).sourceManifest,
    sourceStateDigest,
    { expectedSourceRoots: clientSourceRoots },
  );
}

export function syncLinuxProductSourceManifest(distro) {
  const artifacts = linuxProductArtifactPaths(distro);
  runSsh(
    distro,
    'rm -rf "$HOME/lico-arc/.lico-source-attestation" && ' +
      'mkdir -m 0700 "$HOME/lico-arc/.lico-source-attestation"',
  );
  run("rsync", [
    "-a",
    "-e",
    sshRsyncCommand(distro),
    artifacts.sourceManifest,
    `${vmUser}@127.0.0.1:~/lico-arc/${linuxSourceManifestRemoteRef}`,
  ]);
  runSsh(
    distro,
    `chmod 0600 "$HOME/lico-arc/${linuxSourceManifestRemoteRef}" && ` +
      `test "$(stat -c '%a' "$HOME/lico-arc/${linuxSourceManifestRemoteRef}")" = 600`,
  );
}
