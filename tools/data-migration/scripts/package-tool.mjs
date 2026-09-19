#!/usr/bin/env node
import { buildPackageArtifact } from "../lib/package-manifest.mjs";

try {
  const result = buildPackageArtifact();
  console.log(`Package built successfully:`);
  console.log(`  Artifact: ${result.tarballPath}`);
  console.log(`  Manifest: ${result.manifestPath}`);
  console.log(`  SHA256:   ${result.manifest.artifacts[0].sha256}`);
} catch (err) {
  console.error(`Packaging failed: ${err.message}`);
  process.exit(1);
}
