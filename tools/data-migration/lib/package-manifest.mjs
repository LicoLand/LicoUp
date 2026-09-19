import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { ensureDirectorySync, writeJsonAtomicSync } from "./fs-atomic.mjs";
import { PUBLISHED_FORMAT_PROFILES } from "./catalog.mjs";

export const PACKAGE_MANIFEST_SCHEMA = "v0.0.1:client-data-migration-package-1";

export function sha256File(filePath) {
  const content = fs.readFileSync(filePath);
  return crypto.createHash("sha256").update(content).digest("hex");
}

export function buildPackageArtifact(options = {}) {
  const toolDir = path.resolve(new URL("..", import.meta.url).pathname);
  const outDir = options.outDir || path.resolve(toolDir, "..", "..", "build", "tools", "data-migration");
  ensureDirectorySync(outDir);

  const pkgJson = JSON.parse(fs.readFileSync(path.join(toolDir, "package.json"), "utf8"));
  const version = pkgJson.version || "0.3.0";
  const tarballName = `licoup-data-migration-${version}.tgz`;
  const tarballPath = path.join(outDir, tarballName);

  // Pack package using npm pack
  try {
    execFileSync("npm", ["pack", "--pack-destination", outDir], {
      cwd: toolDir,
      encoding: "utf8",
    });
  } catch (err) {
    // If npm pack fails or not in npm env, create a tar directly
    execFileSync("tar", ["-czf", tarballPath, "-C", path.dirname(toolDir), path.basename(toolDir)]);
  }

  // Identify generated tarball
  let finalTarball = tarballPath;
  if (!fs.existsSync(tarballPath)) {
    // find any .tgz in outDir
    const files = fs.readdirSync(outDir).filter((f) => f.endsWith(".tgz"));
    if (files.length > 0) {
      finalTarball = path.join(outDir, files[0]);
    }
  }

  const stat = fs.statSync(finalTarball);
  const digest = sha256File(finalTarball);

  const manifest = {
    schemaVersion: PACKAGE_MANIFEST_SCHEMA,
    toolName: pkgJson.name || "@licoland/data-migration",
    version,
    license: pkgJson.license || "AGPL-3.0-or-later",
    engines: pkgJson.engines || { node: "^22.0.0 || ^24.0.0 || ^26.0.0" },
    supportedTargetProfiles: Object.keys(PUBLISHED_FORMAT_PROFILES),
    artifacts: [
      {
        filename: path.basename(finalTarball),
        sha256: digest,
        bytes: stat.size,
      },
    ],
    builtAt: new Date().toISOString(),
  };

  const manifestPath = path.join(outDir, "licoup-data-migration-manifest.json");
  writeJsonAtomicSync(manifestPath, manifest);

  return {
    tarballPath: finalTarball,
    manifestPath,
    manifest,
  };
}
