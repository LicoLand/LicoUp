import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { buildPackageArtifact, PACKAGE_MANIFEST_SCHEMA, sha256File } from "../lib/package-manifest.mjs";

test("buildPackageArtifact produces distribution tarball and verified release manifest", () => {
  const outDir = fs.mkdtempSync(path.join(os.tmpdir(), "licoup-pack-test-"));
  try {
    const result = buildPackageArtifact({ outDir });
    assert.ok(fs.existsSync(result.tarballPath), "Distribution tarball must exist");
    assert.ok(fs.existsSync(result.manifestPath), "Package manifest must exist");

    const manifest = JSON.parse(fs.readFileSync(result.manifestPath, "utf8"));
    assert.equal(manifest.schemaVersion, PACKAGE_MANIFEST_SCHEMA);
    assert.equal(manifest.toolName, "@licoland/data-migration");
    assert.equal(manifest.version, "0.3.0");
    assert.ok(manifest.supportedTargetProfiles.includes("v0.1.0"));
    assert.ok(manifest.supportedTargetProfiles.includes("v0.3.0"));
    assert.equal(manifest.artifacts.length, 1);

    const artifact = manifest.artifacts[0];
    assert.equal(artifact.filename, path.basename(result.tarballPath));
    assert.equal(artifact.sha256, sha256File(result.tarballPath));
    assert.ok(artifact.bytes > 0);
  } finally {
    fs.rmSync(outDir, { recursive: true, force: true });
  }
});
