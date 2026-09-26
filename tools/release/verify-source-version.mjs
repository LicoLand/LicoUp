#!/usr/bin/env node

import { readFile, realpath, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const MAX_SOURCE_BYTES = 4 * 1024 * 1024;
const SEMVER = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;

export async function verifySourceVersion({
  root = process.cwd(),
  configPath = "tools/release/source-version.json",
  tag = ""
} = {}) {
  const repositoryRoot = await realpath(root);
  const config = JSON.parse(await readBounded(repositoryRoot, configPath));
  if (config.schemaVersion !== 1 || !Array.isArray(config.versionSources) || config.versionSources.length === 0) {
    throw new Error("source-version-config");
  }

  const versions = [];
  for (const source of config.versionSources) {
    if (!source || typeof source.path !== "string" || typeof source.pointer !== "string") {
      throw new Error("source-version-config");
    }
    const document = JSON.parse(await readBounded(repositoryRoot, source.path));
    const version = jsonPointer(document, source.pointer);
    if (typeof version !== "string" || !SEMVER.test(version)) throw new Error("source-version-invalid");
    versions.push(version);
  }
  const version = versions[0];
  if (versions.some((candidate) => candidate !== version)) throw new Error("source-version-mismatch");

  if (typeof config.changelog !== "string" || config.changelog.length === 0) throw new Error("source-version-config");
  const changelog = await readBounded(repositoryRoot, config.changelog);
  const heading = new RegExp(`^##\\s+${escapeRegExp(version)}(?:\\s|$)`, "mu");
  if (!heading.test(changelog)) throw new Error("source-version-changelog");

  const prefix = typeof config.tagPrefix === "string" ? config.tagPrefix : "v";
  if (tag && tag !== `${prefix}${version}`) throw new Error("source-version-tag");
  return { ok: true, version, sources: versions.length, tagChecked: Boolean(tag) };
}

async function readBounded(root, relativePath) {
  if (path.isAbsolute(relativePath)) throw new Error("source-version-path");
  const candidate = path.resolve(root, relativePath);
  const resolved = await realpath(candidate);
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) throw new Error("source-version-path");
  const metadata = await stat(resolved);
  if (!metadata.isFile() || metadata.size > MAX_SOURCE_BYTES) throw new Error("source-version-size");
  return readFile(resolved, "utf8");
}

function jsonPointer(document, pointer) {
  if (pointer === "") return document;
  if (!pointer.startsWith("/")) throw new Error("source-version-pointer");
  return pointer.slice(1).split("/").reduce((value, segment) => {
    const key = segment.replace(/~1/gu, "/").replace(/~0/gu, "~");
    if (value === null || typeof value !== "object" || !(key in value)) throw new Error("source-version-pointer");
    return value[key];
  }, document);
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

async function main(argv) {
  let tag = process.env.GITHUB_REF_TYPE === "tag" ? process.env.GITHUB_REF_NAME ?? "" : "";
  let configPath = "tools/release/source-version.json";
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--tag") tag = argv[++index] ?? "";
    else if (argv[index] === "--config") configPath = argv[++index] ?? "";
    else throw new Error("source-version-arguments");
  }
  const result = await verifySourceVersion({ configPath, tag });
  process.stdout.write(`source-version: ${result.version}; ${result.sources} sources; tag ${result.tagChecked ? "checked" : "not requested"}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`source-version: ${error.message}\n`);
    process.exitCode = 1;
  });
}
