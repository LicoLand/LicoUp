#!/usr/bin/env node

import { createPublicKey, verify } from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { CLIENT_RELEASE_TARGETS } from "./client-gate-policy.mjs";
import { sha256File } from "./lib/client-release-artifact-digest.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const repository = "LicoLand/LicoUp";
const artifactName = "LicoUp-macos-arm64-update.tar.gz";
const checksumName = `${artifactName}.sha256`;
const manifestName = "LicoUp-update-stable.json";
const expectedNames = Object.freeze([artifactName, checksumName]);
const keyIds = Object.freeze([
  "licoup-update-offline-root-v1",
  "licoup-update-online-channel-v1",
]);

function fail(code) {
  throw Object.assign(new Error(code), { code });
}

function run(command, args, { env = process.env } = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) fail("update_release_command_failed");
  return result.stdout.trim();
}

function parseArgs(argv) {
  if (argv.length === 1 && argv[0] === "--self-test") return { selfTest: true };
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined) fail("update_release_arguments_invalid");
    result[flag.slice(2)] = value;
  }
  if (!/^\d+$/u.test(result["run-id"] || "")) fail("update_release_run_id_invalid");
  if (!/^\d+\.\d+\.\d+$/u.test(result.version || "") || result.tag !== `v${result.version}`) {
    fail("update_release_version_invalid");
  }
  if (!["true", "false"].includes(result.publish || "")) fail("update_release_publish_invalid");
  return result;
}

function regularFile(filePath, maximumBytes = 1024 * 1024 * 1024) {
  const info = lstatSync(filePath, { throwIfNoEntry: false });
  if (!info?.isFile() || info.isSymbolicLink() || realpathSync(filePath) !== filePath ||
      info.size <= 0 || info.size > maximumBytes) fail("update_release_file_invalid");
  return filePath;
}

function exactFiles(directory, names) {
  const actual = readdirSync(directory, { withFileTypes: true });
  if (actual.some((entry) => !entry.isFile() || entry.isSymbolicLink()) ||
      JSON.stringify(actual.map(({ name }) => name).sort()) !== JSON.stringify([...names].sort())) {
    fail("update_release_asset_set_invalid");
  }
}

function stableStringify(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  return `{${Object.keys(value).sort().map((key) =>
    `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
}

function publicKey(rawBase64) {
  const raw = Buffer.from(rawBase64, "base64");
  if (raw.length !== 32) fail("update_release_public_key_invalid");
  return createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]),
    format: "der",
    type: "spki",
  });
}

function verifyManifest(manifestPath, artifactPath, version, tag) {
  const manifest = JSON.parse(readFileSync(regularFile(manifestPath, 1024 * 1024), "utf8"));
  const keys = JSON.parse(readFileSync(
    path.join(repoRoot, "apps/desktop/assets/update/licoup-update-public-keys.json"),
    "utf8",
  )).keys;
  const signatures = manifest.signatures;
  const unsigned = structuredClone(manifest);
  delete unsigned.signatures;
  const payload = Buffer.from(stableStringify(unsigned));
  const artifact = manifest.releases?.[0]?.artifacts?.[0];
  if (manifest.schemaVersion !== "v0.0.1:client-update:manifest-1" ||
      manifest.channel !== "stable" || manifest.releases?.[0]?.version !== version ||
      manifest.releases?.[0]?.releaseNotesUrl !== `https://github.com/${repository}/releases/tag/${tag}` ||
      artifact?.fileName !== artifactName || artifact?.size !== statSync(artifactPath).size ||
      artifact?.sha256 !== sha256File(artifactPath, { maxBytes: 1024 * 1024 * 1024 }) ||
      !Array.isArray(signatures) || signatures.length !== keyIds.length) {
    fail("update_release_manifest_invalid");
  }
  for (const keyId of keyIds) {
    const signature = signatures.find((entry) => entry.keyId === keyId);
    if (signature?.algorithm !== "Ed25519" || !keys?.[keyId]?.publicKey ||
        !verify(null, payload, publicKey(keys[keyId].publicKey), Buffer.from(signature.signature, "base64"))) {
      fail("update_release_signature_invalid");
    }
  }
}

function privateKeyPaths() {
  const defaultRoot = path.join(os.homedir(), "Library", "Application Support", "LicoUp Release", "update-keys-v1");
  const offline = process.env.LICO_UPDATE_OFFLINE_PRIVATE_KEY_PATH || path.join(defaultRoot, "offline-root.pem");
  const online = process.env.LICO_UPDATE_ONLINE_PRIVATE_KEY_PATH || path.join(defaultRoot, "online-channel.pem");
  regularFile(offline, 64 * 1024);
  regularFile(online, 64 * 1024);
  return { offline, online };
}

function releaseDetails(tag) {
  return JSON.parse(run("gh", [
    "release", "view", tag, "--repo", repository, "--json", "targetCommitish,isDraft,assets",
  ]));
}

function uploadMissing(tag, directory, names, release) {
  const remote = new Set(release.assets.map(({ name }) => name));
  for (const name of names) {
    const source = regularFile(path.join(directory, name));
    if (remote.has(name)) {
      const existingRoot = path.join(directory, "existing");
      mkdirSync(existingRoot, { recursive: true, mode: 0o700 });
      run("gh", ["release", "download", tag, "--repo", repository, "--pattern", name, "--dir", existingRoot]);
      const existing = regularFile(path.join(existingRoot, name));
      if (statSync(existing).size !== statSync(source).size ||
          sha256File(existing) !== sha256File(source)) fail("update_release_asset_conflict");
      continue;
    }
    run("gh", ["release", "upload", tag, "--repo", repository, source]);
  }
}

function finalize(options) {
  if (process.platform !== "darwin" || process.arch !== "arm64") fail("update_release_host_invalid");
  const buildRoot = path.join(repoRoot, "build");
  mkdirSync(buildRoot, { recursive: true });
  if (realpathSync(buildRoot) !== buildRoot) fail("update_release_build_root_invalid");
  const root = mkdtempSync(path.join(buildRoot, "update-finalize-"));
  chmodSync(root, 0o700);
  try {
    const incoming = path.join(root, "incoming");
    mkdirSync(incoming, { mode: 0o700 });
    run("gh", [
      "run", "download", options["run-id"], "--repo", repository,
      "--name", "licoup-macos-update", "--dir", incoming,
    ]);
    exactFiles(incoming, expectedNames);
    const artifact = regularFile(path.join(incoming, artifactName));
    const checksum = readFileSync(regularFile(path.join(incoming, checksumName), 4096), "utf8");
    const digest = sha256File(artifact).slice("sha256:".length);
    if (checksum !== `${digest}  ${artifactName}\n`) fail("update_release_checksum_invalid");
    const manifest = path.join(incoming, manifestName);
    const keys = privateKeyPaths();
    run(process.execPath, [
      "tools/scripts/client-update-manifest-sign.mjs",
      "--version", options.version,
      "--tag", options.tag,
      "--artifact", artifact,
      "--output", manifest,
    ], { env: {
      ...process.env,
      LICO_UPDATE_OFFLINE_PRIVATE_KEY_PATH: keys.offline,
      LICO_UPDATE_ONLINE_PRIVATE_KEY_PATH: keys.online,
    } });
    verifyManifest(manifest, artifact, options.version, options.tag);
    const releaseSha = run("git", ["rev-parse", "origin/release"]);
    let release = releaseDetails(options.tag);
    if (release.targetCommitish !== releaseSha) fail("update_release_source_invalid");
    uploadMissing(options.tag, incoming, [...expectedNames, manifestName], release);
    release = releaseDetails(options.tag);
    const allowedRemoteNames = new Set([
      "LicoUp-consumer-verification.json",
      manifestName,
      ...expectedNames,
      ...Object.values(CLIENT_RELEASE_TARGETS).flatMap(({ files }) => files),
    ]);
    const remoteNames = release.assets.map(({ name }) => name);
    if (new Set(remoteNames).size !== remoteNames.length ||
        remoteNames.some((name) => !allowedRemoteNames.has(name)) ||
        [...expectedNames, manifestName].some((name) => !remoteNames.includes(name))) {
      fail("update_release_remote_asset_set_invalid");
    }
    const verifyRoot = path.join(root, "verify");
    mkdirSync(verifyRoot, { mode: 0o700 });
    for (const name of [...expectedNames, manifestName]) {
      run("gh", ["release", "download", options.tag, "--repo", repository, "--pattern", name, "--dir", verifyRoot]);
    }
    exactFiles(verifyRoot, [...expectedNames, manifestName]);
    verifyManifest(path.join(verifyRoot, manifestName), path.join(verifyRoot, artifactName), options.version, options.tag);
    if (options.publish === "true" && release.isDraft) {
      run("gh", ["release", "edit", options.tag, "--repo", repository, "--draft=false"]);
      release = releaseDetails(options.tag);
    }
    if (options.publish === "true" && release.isDraft) fail("update_release_publish_failed");
    process.stdout.write(`update_release=ready version=${options.version} publish=${options.publish}\n`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

try {
  const options = parseArgs(process.argv.slice(2));
  if (options.selfTest) {
    if (parseArgs(["--run-id", "1", "--version", "1.2.3", "--tag", "v1.2.3", "--publish", "false"]).tag !== "v1.2.3") {
      fail("update_release_self_test_failed");
    }
    process.stdout.write("update_release=self_test_passed\n");
  } else {
    finalize(options);
  }
} catch (error) {
  process.stderr.write(`LicoUp update release: ${error?.code || "update_release_failed"}\n`);
  process.exitCode = 1;
}
