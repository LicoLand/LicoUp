#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const verifier = path.join(repoRoot, "tools/scripts/client-release-remote-asset-set.mjs");
const root = mkdtempSync(path.join(tmpdir(), "lico-remote-assets-"));

try {
  const artifactName = "LicoUp-macos-arm64.zip";
  const artifactBytes = Buffer.from("canonical-artifact", "utf8");
  const artifactSha256 = createHash("sha256").update(artifactBytes).digest("hex");
  const checksumName = `${artifactName}.sha256`;
  const checksumBytes = Buffer.from(`${artifactSha256}  ${artifactName}\n`, "utf8");
  const name = "LicoUp-consumer-verification.json";
  const installerName = "install-macos.sh";
  const installerBytes = Buffer.from("#!/bin/bash\n", "utf8");
  const bytes = Buffer.from(`${JSON.stringify({
    schemaVersion: "licomesh.consumer-verification-manifest.v1",
    artifactName: "LicoUp",
    releaseTag: "v0.0.1-test",
    artifacts: [{
      name: artifactName,
      version: "0.0.1-test",
      platform: "macos-arm64",
      byteSize: artifactBytes.length,
      sha256: artifactSha256,
      verification: { checksum: checksumName, algorithm: "SHA-256" },
    }],
  })}\n`, "utf8");
  writeFileSync(path.join(root, artifactName), artifactBytes);
  writeFileSync(path.join(root, checksumName), checksumBytes);
  writeFileSync(path.join(root, installerName), installerBytes);
  writeFileSync(path.join(root, name), bytes);
  const localAssets = [
    { name: artifactName, bytes: artifactBytes },
    { name: checksumName, bytes: checksumBytes },
    { name: installerName, bytes: installerBytes },
    { name, bytes },
  ].map((entry) => ({
    name: entry.name,
    size: entry.bytes.length,
    digest: `sha256:${createHash("sha256").update(entry.bytes).digest("hex")}`,
  }));
  const remote = path.join(root, "..", `${path.basename(root)}-remote.json`);
  writeFileSync(remote, `${JSON.stringify(localAssets)}\n`);
  const valid = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (valid.status !== 0) throw new Error("exact remote asset set was rejected");
  writeFileSync(path.join(root, artifactName), Buffer.from("changed-artifact", "utf8"));
  const staleManifest = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (staleManifest.status === 0) throw new Error("stale consumer manifest was accepted");
  writeFileSync(path.join(root, artifactName), artifactBytes);
  writeFileSync(remote, `${JSON.stringify([
    ...localAssets,
    { name: "unexpected", size: 1, digest: `sha256:${"0".repeat(64)}` },
  ])}\n`);
  const extra = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (extra.status === 0) throw new Error("extra remote asset was accepted");
  writeFileSync(remote, "x".repeat(128 * 1024 + 1));
  const oversized = spawnSync(process.execPath, [
    verifier, "--assets", root, "--remote", remote,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (oversized.status === 0) throw new Error("oversized remote metadata was accepted");
  console.log(JSON.stringify({
    ok: true,
    namesSizesAndDigestsBound: true,
    manifestSemanticsBound: true,
    extrasRejected: true,
    oversizedMetadataRejected: true,
  }));
  rmSync(remote, { force: true });
} finally {
  rmSync(root, { recursive: true, force: true });
}
