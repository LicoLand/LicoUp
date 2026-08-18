#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../../", import.meta.url));
const manifestPath = path.join(repoRoot, "tools", "client-version.json");
const schemaVersion = "v0.0.1:client-version-manifest-1";

function fail(message) {
  process.stderr.write(`LicoUp version prepare: ${message}\n`);
  process.exitCode = 1;
}

function main() {
  const [version, buildText] = process.argv.slice(2);
  if (typeof version !== "string" || version.length === 0 || version.length > 64) {
    return fail("version_invalid");
  }
  const build = Number(buildText);
  if (!Number.isSafeInteger(build) || build < 1) {
    return fail("build_invalid");
  }
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  if (manifest.schemaVersion !== schemaVersion) {
    return fail("manifest_schema_invalid");
  }
  manifest.productVersion = version;
  manifest.buildNumber = build;
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  process.stdout.write(
    `${JSON.stringify({ ok: true, productVersion: version, buildNumber: build })}\n`,
  );
}

main();
