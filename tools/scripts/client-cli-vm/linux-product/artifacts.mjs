import { mkdirSync, rmSync } from "node:fs";
import path from "node:path";
import { linuxSourceManifestName } from "../constants.mjs";
import { pathsFor } from "../paths.mjs";

export function linuxProductArtifactPaths(distro) {
  const root = pathsFor(distro).artifactRoot;
  return {
    root,
    vmReceipt: path.join(root, "secure-mesh-linux-vm-package-receipt.json"),
    nodeMatrix: path.join(root, "secure-mesh-linux-node-matrix.json"),
    releaseCliProof: path.join(root, "secure-mesh-release-cli-proof.json"),
    archive: path.join(root, "LicoArc-linux-arm64.tar.gz"),
    signature: path.join(root, "LicoArc-linux-arm64.tar.gz.sig"),
    distributionManifest: path.join(root, "linux-arm64-manifest.json"),
    sourceManifest: path.join(root, linuxSourceManifestName),
    incomplete: path.join(root, "secure-mesh-linux-current-source-incomplete.json"),
  };
}

export function clearLinuxProductHostArtifacts(distro) {
  const artifacts = linuxProductArtifactPaths(distro);
  mkdirSync(artifacts.root, { recursive: true });
  for (const key of [
    "vmReceipt",
    "nodeMatrix",
    "releaseCliProof",
    "archive",
    "signature",
    "distributionManifest",
    "sourceManifest",
    "incomplete",
  ]) {
    rmSync(artifacts[key], { force: true });
  }
}
