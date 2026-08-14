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
import {
  loadClientReleaseTargetCatalog,
  selectClientReleaseTargets,
} from "./lib/client-release-targets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const buildRoot = path.join(repoRoot, "build");
const manifestName = "LicoUp-consumer-verification.json";
const correctiveReleaseNotes = [
  "LicoUp v0.1.0 build 2 replaces the damaged v0.1.0 artifacts.",
  "",
  "macOS direct-distribution artifacts are not published by this workflow.",
  "",
  "Verify every download with LicoUp-consumer-verification.json and the signed update manifest.",
].join("\n");

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined ||
      result[flag.slice(2)] !== undefined) fail("invalid publish arguments");
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

export function releaseStateDecision(release, sourceSha, publish) {
  if (release === null) {
    return Object.freeze({ createDraft: true, publish: false });
  }
  if (release.targetCommitish !== sourceSha) {
    fail("GitHub Release source revision does not match this workflow");
  }
  return Object.freeze({
    createDraft: false,
    publish: publish === true && release.isDraft === true,
  });
}

function ensureRelease({ tag, repository, sourceSha }) {
  let release = tryReleaseView(tag, repository);
  if (releaseStateDecision(release, sourceSha, false).createDraft) {
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
      correctiveReleaseNotes,
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
    .filter(([, topology]) => topology.files.every((name) => names.has(name)))
    .map(([target]) => target)
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

function preserveExistingGeneratedAsset(assetsRoot, name) {
  const filePath = path.join(assetsRoot, name);
  const info = lstatSync(filePath, { throwIfNoEntry: false });
  if (!info) return null;
  if (!info.isFile() || info.isSymbolicLink()) {
    fail("existing generated Release metadata is not a regular file");
  }
  const digest = sha256File(filePath, { maxBytes: 1024 * 1024 });
  unlinkSync(filePath);
  return digest;
}

function generatedAssetNeedsUpload(assetsRoot, name, previousDigest) {
  const filePath = path.join(assetsRoot, name);
  const digest = sha256File(filePath, { maxBytes: 1024 * 1024 });
  const decision = generatedAssetDecision(previousDigest, digest);
  if (decision === "reject") {
    fail("generated Release metadata conflicts with the immutable existing asset");
  }
  return decision === "upload";
}

export function generatedAssetDecision(previousDigest, nextDigest) {
  if (!digestPatternForGeneratedAsset(nextDigest)) {
    fail("generated Release metadata digest is invalid");
  }
  if (previousDigest === null) return "upload";
  if (!digestPatternForGeneratedAsset(previousDigest) || previousDigest !== nextDigest) {
    return "reject";
  }
  return "reuse";
}

function digestPatternForGeneratedAsset(value) {
  return /^sha256:[a-f0-9]{64}$/u.test(String(value || ""));
}

const updateManifestName = "LicoUp-update-manifest.json";
const updatePublicKeysName = "LicoUp-update-public-keys.json";

function buildUpdateManifest({ tag, assetsRoot, repository }) {
  const encodedManifest = String(
    process.env.LICO_SIGNED_UPDATE_MANIFEST_BASE64 || "",
  ).trim();
  if (encodedManifest) {
    if (!/^[A-Za-z0-9+/=]{1,524288}$/u.test(encodedManifest)) {
      fail("signed update manifest encoding is invalid");
    }
    const manifestBytes = Buffer.from(encodedManifest, "base64");
    if (manifestBytes.length === 0 || manifestBytes.length > 256 * 1024 ||
      manifestBytes.toString("base64") !== encodedManifest) {
      fail("signed update manifest encoding is invalid");
    }
    JSON.parse(manifestBytes.toString("utf8"));
    writeFileSync(path.join(assetsRoot, updateManifestName), manifestBytes, {
      mode: 0o644,
      flag: "wx",
    });
    copyFileSync(
      path.join(repoRoot, "crates/licoup-native/resources/client-update-public-keys.json"),
      path.join(assetsRoot, updatePublicKeysName),
      constants.COPYFILE_EXCL,
    );
    return Object.freeze({ generated: true, source: "local-offline-signing" });
  }
  if (!process.env.LICO_UPDATE_OFFLINE_ROOT_KEY || !process.env.LICO_UPDATE_ONLINE_CHANNEL_KEY) {
    return Object.freeze({ generated: false, reason: "update signing keys are not configured" });
  }
  run(process.execPath, [
    "tools/scripts/client-update-manifest.mjs",
    "--assets",
    assetsRoot,
    "--output",
    path.join(assetsRoot, updateManifestName),
    "--public-keys-output",
    path.join(assetsRoot, updatePublicKeysName),
    "--tag",
    tag,
    "--repo",
    repository,
    "--targets",
    selectedTargetArgument(assetsRoot),
  ]);
  return Object.freeze({ generated: true });
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

function selectedPublishTargets(value) {
  const ids = String(value || "").split(",");
  if (ids.length === 0 || ids.some((id) => !id || id !== id.trim()) ||
    new Set(ids).size !== ids.length) fail("invalid release target selection");
  const selected = selectClientReleaseTargets(
    loadClientReleaseTargetCatalog(), ids,
  );
  if (selected.some((target) => !CLIENT_RELEASE_TARGETS[target.id])) {
    fail("unsupported release target");
  }
  return selected.map((target) => target.id);
}

export function publishTargets(args) {
  const targets = selectedPublishTargets(args.targets);
  const tag = args.tag || "";
  if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,126}$/u.test(tag)) fail("invalid release tag");
  if (!["true", "false"].includes(args.publish || "")) fail("invalid publish selection");
  const repository = process.env.GITHUB_REPOSITORY || "";
  const sourceSha = process.env.LICO_RELEASE_SOURCE_REVISION || "";
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(repository) ||
    !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/u.test(sourceSha) ||
    !process.env.GH_TOKEN
  ) {
    fail("GitHub publication environment is incomplete");
  }
  if (targets.some((target) => target.startsWith("macos-direct-")) &&
    !String(process.env.LICO_SIGNED_UPDATE_MANIFEST_BASE64 || "").trim()) {
    fail("macOS publication requires a locally signed update manifest");
  }
  const incomingRoot = containedBuildDirectory(args["incoming-root"], "incoming artifacts");
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
  const previousManifestDigest = preserveExistingGeneratedAsset(assetsRoot, manifestName);
  const previousUpdateManifestDigest = preserveExistingGeneratedAsset(
    assetsRoot, updateManifestName);
  const previousUpdateKeysDigest = preserveExistingGeneratedAsset(
    assetsRoot, updatePublicKeysName);
  const merged = targets.map((target) => {
    const targetRoot = path.join(incomingRoot, target);
    const targetInfo = lstatSync(targetRoot, { throwIfNoEntry: false });
    if (!targetInfo?.isDirectory() || targetInfo.isSymbolicLink() ||
      realpathSync(targetRoot) !== targetRoot) {
      fail("incoming target artifact directory is missing");
    }
    return mergeIncomingTarget({ target, incomingRoot: targetRoot, assetsRoot });
  });
  buildManifest({ tag, assetsRoot });
  const updateManifest = buildUpdateManifest({ tag, assetsRoot, repository });
  const artifactUploads = merged.flatMap((entry) => entry.upload);
  if (artifactUploads.length > 0) {
    run("gh", [
      "release",
      "upload",
      tag,
      "--repo",
      repository,
      ...artifactUploads.map((entry) => path.relative(repoRoot, entry.path)),
    ]);
  }
  if (generatedAssetNeedsUpload(assetsRoot, manifestName, previousManifestDigest)) {
    run("gh", [
      "release", "upload", tag, "--repo", repository,
      path.relative(repoRoot, path.join(assetsRoot, manifestName)),
    ]);
  }
  if (updateManifest.generated) {
    const upload = [];
    if (generatedAssetNeedsUpload(assetsRoot, updateManifestName,
      previousUpdateManifestDigest)) upload.push(updateManifestName);
    if (generatedAssetNeedsUpload(assetsRoot, updatePublicKeysName,
      previousUpdateKeysDigest)) upload.push(updatePublicKeysName);
    if (upload.length > 0) {
      run("gh", ["release", "upload", tag, "--repo", repository,
        ...upload.map((name) => path.relative(repoRoot, path.join(assetsRoot, name)))]);
    }
  } else if (previousUpdateManifestDigest || previousUpdateKeysDigest) {
    fail("existing update metadata cannot be reproduced by this candidate");
  }
  verifyRemoteAssets({ tag, repository, assetsRoot });
  if (releaseStateDecision(release, sourceSha, args.publish === "true").publish) {
    run("gh", ["release", "edit", tag, "--repo", repository, "--draft=false"]);
  }
  return Object.freeze({
    ok: true,
    targets: Object.freeze(targets),
    targetCount: targets.length,
    mergedTargetCount: Object.values(CLIENT_RELEASE_TARGETS)
      .filter((topology) => topology.files.every((name) =>
        lstatSync(path.join(assetsRoot, name), { throwIfNoEntry: false })?.isFile()))
      .length,
  });
}

function main() {
  const result = publishTargets(parseArgs(process.argv.slice(2)));
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
