#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const fixtureRoot = mkdtempSync(path.join(tmpdir(), "lico-consumer-manifest-"));
const script = path.join(repoRoot, "tools/scripts/client-consumer-verification-manifest.mjs");
const artifact = "LicoUp-macos-arm64.dmg";
const updateArtifact = "LicoUp-macos-arm64-update.zip";
const output = path.join(fixtureRoot, "LicoUp-consumer-verification.json");

try {
  const bytes = Buffer.from("canonical-artifact-fixture", "utf8");
  const digest = createHash("sha256").update(bytes).digest("hex");
  const updateBytes = Buffer.from("canonical-update-fixture", "utf8");
  const updateDigest = createHash("sha256").update(updateBytes).digest("hex");
  writeFileSync(path.join(fixtureRoot, artifact), bytes);
  writeFileSync(path.join(fixtureRoot, `${artifact}.sha256`), `${digest}  ${artifact}\n`);
  writeFileSync(path.join(fixtureRoot, updateArtifact), updateBytes);
  writeFileSync(path.join(fixtureRoot, `${updateArtifact}.sha256`),
    `${updateDigest}  ${updateArtifact}\n`);
  const valid = spawnSync(process.execPath, [
    script,
    "--assets", fixtureRoot,
    "--output", output,
    "--tag", "v0.0.1-test",
    "--targets", "macos-arm64=true,linux-glibc-arm64=false,android-arm64=false",
  ], { cwd: repoRoot, encoding: "utf8" });
  if (valid.status !== 0) throw new Error("valid consumer manifest fixture was rejected");
  const manifest = JSON.parse(readFileSync(output, "utf8"));
  if (manifest.schemaVersion !== "licomesh.consumer-verification-manifest.v1" ||
    manifest.artifacts?.length !== 2 || manifest.artifacts[0]?.sha256 !== digest ||
    manifest.artifacts[0]?.name !== artifact ||
    manifest.artifacts[1]?.sha256 !== updateDigest ||
    manifest.artifacts[1]?.name !== updateArtifact ||
    Object.keys(manifest).some((key) => /publisher|account|team|tenant|device/iu.test(key))) {
    throw new Error("consumer manifest exposed invalid or non-verification metadata");
  }
  rmSync(output);
  writeFileSync(path.join(fixtureRoot, `${artifact}.sha256`), `${"0".repeat(64)}  ${artifact}\n`);
  const tampered = spawnSync(process.execPath, [
    script,
    "--assets", fixtureRoot,
    "--output", output,
    "--tag", "v0.0.1-test",
    "--targets", "macos-arm64=true,linux-glibc-arm64=false,android-arm64=false",
  ], { cwd: repoRoot, encoding: "utf8" });
  if (tampered.status === 0) throw new Error("tampered checksum fixture was accepted");
  writeFileSync(path.join(fixtureRoot, `${artifact}.sha256`), "x".repeat(4097));
  const oversized = spawnSync(process.execPath, [
    script,
    "--assets", fixtureRoot,
    "--output", output,
    "--tag", "v0.0.1-test",
    "--targets", "macos-arm64=true,linux-glibc-arm64=false,android-arm64=false",
  ], { cwd: repoRoot, encoding: "utf8" });
  if (oversized.status === 0) throw new Error("oversized checksum fixture was accepted");
  writeFileSync(path.join(fixtureRoot, `${artifact}.sha256`), `${digest}  ${artifact}\n`);
  symlinkSync(path.join(fixtureRoot, artifact), path.join(fixtureRoot, "unexpected-link"));
  const linked = spawnSync(process.execPath, [
    script,
    "--assets", fixtureRoot,
    "--output", output,
    "--tag", "v0.0.1-test",
    "--targets", "macos-arm64=true,linux-glibc-arm64=false,android-arm64=false",
  ], { cwd: repoRoot, encoding: "utf8" });
  if (linked.status === 0) throw new Error("symbolic-link asset fixture was accepted");
  console.log(JSON.stringify({
    ok: true,
    exactAssetSet: true,
    checksumBound: true,
    oversizedMetadataRejected: true,
    symbolicLinksRejected: true,
    metadataMinimal: true,
  }));
} finally {
  rmSync(fixtureRoot, { recursive: true, force: true });
}
