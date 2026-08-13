#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import {
  constants,
  copyFileSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  realpathSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { CLIENT_RELEASE_TARGETS } from "./client-gate-policy.mjs";
import { sha256File } from "./lib/client-release-artifact-digest.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const buildRoot = path.join(repoRoot, "build");
const manifestName = "LicoUp-consumer-verification.json";

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined) fail("invalid publish arguments");
    result[flag.slice(2)] = value;
  }
  return result;
}

function containedBuildDirectory(value, label) {
  const resolved = path.resolve(repoRoot, value || "");
  if (resolved === buildRoot || !resolved.startsWith(`${buildRoot}${path.sep}`)) {
    fail(`${label} must be a contained build directory`);
  }
  return resolved;
}

function regularFiles(directory) {
  return readdirSync(directory, { withFileTypes: true })
    .map((entry) => {
      if (!entry.isFile() || entry.isSymbolicLink() || path.basename(entry.name) !== entry.name) {
        fail("release assets must be regular files");
      }
      const filePath = path.join(directory, entry.name);
      const info = lstatSync(filePath);
      if (!info.isFile() || info.isSymbolicLink()) fail("release assets must be regular files");
      return Object.freeze({ name: entry.name, path: filePath });
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

function run(command, args, { capture = false } = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    fail(`release publisher command failed: ${command}`);
  }
  return result.stdout || "";
}

function tryReleaseView(tag, repository) {
  const result = spawnSync(
    "gh",
    [
      "release",
      "view",
      tag,
      "--repo",
      repository,
      "--json",
      "targetCommitish,isDraft,assets",
    ],
    {
      cwd: repoRoot,
      env: process.env,
      encoding: "utf8",
      shell: false,
      stdio: ["ignore", "pipe", "ignore"],
      maxBuffer: 2 * 1024 * 1024,
    },
  );
  if (result.status !== 0) return null;
  const parsed = JSON.parse(result.stdout);
  if (
    typeof parsed?.targetCommitish !== "string" ||
    typeof parsed?.isDraft !== "boolean" ||
    !Array.isArray(parsed?.assets) ||
    parsed.assets.length > 16
  ) {
    fail("existing GitHub Release metadata is invalid");
  }
  return parsed;
}

function ensureRelease({ tag, repository, sourceSha }) {
  let release = tryReleaseView(tag, repository);
  if (!release) {
    run("gh", [
      "release",
      "create",
      tag,
      "--repo",
      repository,
      "--target",
      sourceSha,
      "--title",
      tag,
      "--notes",
      "Verified LicoUp artifacts. See LicoUp-consumer-verification.json.",
      "--draft",
    ]);
    release = tryReleaseView(tag, repository);
  }
  if (!release || release.targetCommitish !== sourceSha) {
    fail("GitHub Release source revision does not match this workflow");
  }
  return release;
}

function downloadExistingAssets({ release, tag, repository, assetsRoot }) {
  const remoteNames = release.assets.map((asset) => {
    if (
      typeof asset?.name !== "string" ||
      asset.name.length === 0 ||
      path.basename(asset.name) !== asset.name
    ) {
      fail("existing GitHub Release contains an invalid asset name");
    }
    return asset.name;
  });
  if (new Set(remoteNames).size !== remoteNames.length) {
    fail("existing GitHub Release contains duplicate asset names");
  }
  if (remoteNames.length > 0) {
    run("gh", [
      "release",
      "download",
      tag,
      "--repo",
      repository,
      "--dir",
      path.relative(repoRoot, assetsRoot),
    ]);
  }
  const downloadedNames = regularFiles(assetsRoot).map((entry) => entry.name);
  if (JSON.stringify(downloadedNames) !== JSON.stringify([...remoteNames].sort())) {
    fail("downloaded GitHub Release assets do not match remote metadata");
  }
}

export function mergeIncomingTarget({ target, incomingRoot, assetsRoot }) {
  const incoming = regularFiles(incomingRoot);
  const expected = [...CLIENT_RELEASE_TARGETS[target].files].sort();
  const actual = incoming.map((entry) => entry.name);
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail("incoming artifact set does not exactly match the selected target");
  }
  const manifestPath = path.join(assetsRoot, manifestName);
  const manifestInfo = lstatSync(manifestPath, { throwIfNoEntry: false });
  if (manifestInfo) {
    if (!manifestInfo.isFile() || manifestInfo.isSymbolicLink()) {
      fail("existing consumer manifest is not a regular file");
    }
    unlinkSync(manifestPath);
  }
  const upload = [];
  for (const entry of incoming) {
    const destination = path.join(assetsRoot, entry.name);
    const existing = lstatSync(destination, { throwIfNoEntry: false });
    if (existing) {
      if (
        !existing.isFile() ||
        existing.isSymbolicLink() ||
        existing.size !== lstatSync(entry.path).size ||
        sha256File(destination, { maxBytes: 1024 * 1024 * 1024 }) !==
          sha256File(entry.path, { maxBytes: 1024 * 1024 * 1024 })
      ) {
        fail("selected target conflicts with an existing GitHub Release asset");
      }
      continue;
    }
    copyFileSync(entry.path, destination, constants.COPYFILE_EXCL);
    upload.push(entry);
  }
  return Object.freeze({ incoming, upload: Object.freeze(upload) });
}

function selectedTargetArgument(assetsRoot) {
  const names = new Set(regularFiles(assetsRoot).map((entry) => entry.name));
  return Object.entries(CLIENT_RELEASE_TARGETS)
    .map(([target, topology]) => {
      const selected = topology.files.some((name) => names.has(name));
      return `${target}=${selected}`;
    })
    .join(",");
}

function buildManifest({ tag, assetsRoot }) {
  run(process.execPath, [
    "tools/scripts/client-consumer-verification-manifest.mjs",
    "--assets",
    assetsRoot,
    "--output",
    path.join(assetsRoot, manifestName),
    "--tag",
    tag,
    "--targets",
    selectedTargetArgument(assetsRoot),
  ]);
}

function verifyRemoteAssets({ tag, repository, assetsRoot }) {
  const encodedTag = encodeURIComponent(tag);
  const remote = run(
    "gh",
    [
      "api",
      `repos/${repository}/releases/tags/${encodedTag}`,
      "--jq",
      ".assets | map({name, size, digest})",
    ],
    { capture: true },
  );
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "lico-release-assets-"));
  try {
    const remotePath = path.join(temporaryRoot, "assets.json");
    writeFileSync(remotePath, remote, { encoding: "utf8", mode: 0o600, flag: "wx" });
    run(process.execPath, [
      "tools/scripts/client-release-remote-asset-set.mjs",
      "--assets",
      assetsRoot,
      "--remote",
      remotePath,
    ]);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

export function publishTarget(args) {
  const target = args.target || "";
  if (!CLIENT_RELEASE_TARGETS[target]) fail("unsupported release target");
  const tag = args.tag || "";
  if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,126}$/u.test(tag)) fail("invalid release tag");
  if (!["true", "false"].includes(args.publish || "")) fail("invalid publish selection");
  const repository = process.env.GITHUB_REPOSITORY || "";
  const sourceSha = process.env.GITHUB_SHA || "";
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(repository) ||
    !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/u.test(sourceSha) ||
    !process.env.GH_TOKEN
  ) {
    fail("GitHub publication environment is incomplete");
  }
  const incomingRoot = containedBuildDirectory(args.incoming, "incoming artifacts");
  const assetsRoot = containedBuildDirectory(args.assets, "merged assets");
  const buildInfo = lstatSync(buildRoot, { throwIfNoEntry: false });
  if (
    !buildInfo?.isDirectory() ||
    buildInfo.isSymbolicLink() ||
    realpathSync(buildRoot) !== buildRoot
  ) {
    fail("release build root is not a canonical directory");
  }
  const incomingInfo = lstatSync(incomingRoot, { throwIfNoEntry: false });
  if (
    !incomingInfo?.isDirectory() ||
    incomingInfo.isSymbolicLink() ||
    realpathSync(incomingRoot) !== incomingRoot
  ) {
    fail("incoming artifact directory is missing");
  }
  mkdirSync(assetsRoot, { recursive: true, mode: 0o755 });
  if (realpathSync(assetsRoot) !== assetsRoot) {
    fail("merged asset directory is not canonical");
  }
  if (regularFiles(assetsRoot).length !== 0) fail("merged asset directory must start empty");

  const release = ensureRelease({ tag, repository, sourceSha });
  downloadExistingAssets({ release, tag, repository, assetsRoot });
  const merged = mergeIncomingTarget({ target, incomingRoot, assetsRoot });
  buildManifest({ tag, assetsRoot });
  if (merged.upload.length > 0) {
    run("gh", [
      "release",
      "upload",
      tag,
      "--repo",
      repository,
      ...merged.upload.map((entry) => path.relative(repoRoot, entry.path)),
    ]);
  }
  run("gh", [
    "release",
    "upload",
    tag,
    "--repo",
    repository,
    path.relative(repoRoot, path.join(assetsRoot, manifestName)),
    "--clobber",
  ]);
  verifyRemoteAssets({ tag, repository, assetsRoot });
  if (args.publish === "true") {
    run("gh", ["release", "edit", tag, "--repo", repository, "--draft=false"]);
  }
  return Object.freeze({
    ok: true,
    target,
    mergedTargetCount: Object.values(CLIENT_RELEASE_TARGETS)
      .filter((topology) => topology.files.every((name) =>
        lstatSync(path.join(assetsRoot, name), { throwIfNoEntry: false })?.isFile()))
      .length,
  });
}

function main() {
  const result = publishTarget(parseArgs(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error?.message || error}\n`);
    process.exitCode = 1;
  }
}
