import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { linuxProductArtifactPaths } from "./artifacts.mjs";

export function writeLinuxProductIncomplete(distro, reason) {
  const artifacts = linuxProductArtifactPaths(distro);
  mkdirSync(artifacts.root, { recursive: true });
  for (const key of [
    "vmReceipt",
    "nodeMatrix",
    "releaseCliProof",
    "archive",
    "signature",
    "verificationManifest",
    "sourceManifest",
  ]) {
    rmSync(artifacts[key], { force: true });
  }
  writeFileSync(
    artifacts.incomplete,
    `${JSON.stringify(
      {
        schema: "licomesh.secure-mesh.linux-current-source-incomplete",
        schemaVersion: 1,
        ok: false,
        artifactKind: "linux-current-source-acceptance",
        reason,
        privacy: {
          redacted: true,
          runtimeIdentityIncluded: false,
          localPathIncluded: false,
          rawLogsIncluded: false,
          rawSecretsIncluded: false,
        },
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
}
