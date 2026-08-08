import { mkdirSync } from "node:fs";
import { vmUser } from "../constants.mjs";
import { pathsFor } from "../paths.mjs";
import { run } from "../process.mjs";
import { sshRsyncCommand } from "../ssh/session.mjs";

export function fetchArtifacts(distro, remoteDirectory = "lico-artifacts") {
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
    `${vmPaths.artifactRoot}/`,
  ]);
  console.log(
    JSON.stringify({
      ok: true,
      target: `${distro.id}-linux-arm64`,
      artifactsFetched: true,
      localPathIncluded: false,
    }),
  );
}
