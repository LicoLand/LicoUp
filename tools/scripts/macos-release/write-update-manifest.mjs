#!/usr/bin/env node

import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { main as writeUpdateManifest } from "../client-update-manifest.mjs";

const repositoryRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));

function fail(message) {
  throw new Error(message);
}

function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!["--tag", "--repository", "--version"].includes(flag) || value === undefined) {
      fail("usage: write-update-manifest.mjs --tag TAG --repository OWNER/REPO --version VERSION");
    }
    const name = flag.slice(2);
    if (Object.hasOwn(values, name)) fail(`duplicate ${flag}`);
    values[name] = value;
  }
  if (Object.keys(values).length !== 3) fail("tag, repository, and version are required");
  return values;
}

function run(argv = process.argv.slice(2)) {
  const { tag, repository, version } = parseArguments(argv);
  const versionDocument = JSON.parse(
    readFileSync(path.join(repositoryRoot, "tools", "client-version.json"), "utf8"),
  );
  if (repository !== "LicoLand/LicoUp") fail("release repository does not match LicoUp");
  if (versionDocument.productVersion !== version) fail("release version does not match LicoUp metadata");
  if (tag !== `v${version}`) fail("release tag does not match the authorized version");

  writeUpdateManifest([
    "--assets",
    "build/apple-release",
    "--tag",
    tag,
    "--repo",
    repository,
    "--targets",
    "macos-direct-arm64",
    "--output",
    "build/apple-release/LicoUp-update-manifest.json",
  ]);
}

try {
  run();
} catch (error) {
  process.stderr.write(`macos-release-update-manifest: ${error?.message || error}\n`);
  process.exitCode = 1;
}
