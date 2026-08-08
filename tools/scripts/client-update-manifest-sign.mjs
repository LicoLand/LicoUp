#!/usr/bin/env node
import { createPrivateKey, sign } from "node:crypto";
import {
  lstatSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { sha256File } from "./lib/client-release-artifact-digest.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const schema = "v0.0.1:client-update:manifest-1";
const offlineKeyId = "licoup-update-offline-root-v1";
const onlineKeyId = "licoup-update-online-channel-v1";

function fail(code) {
  throw new Error(code);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined) fail("update_manifest_arguments_invalid");
    result[name.slice(2)] = value;
  }
  return result;
}

function regularFile(value, label, maxBytes) {
  const resolved = path.resolve(value || "");
  const info = lstatSync(resolved, { throwIfNoEntry: false });
  if (!info?.isFile() || info.isSymbolicLink() || info.size <= 0 || info.size > maxBytes ||
      realpathSync(resolved) !== resolved) fail(`${label}_invalid`);
  return resolved;
}

function stableStringify(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  return `{${Object.keys(value).sort().map((key) =>
    `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
}

function signature(keyId, privateKeyPath, payload) {
  const key = createPrivateKey(readFileSync(regularFile(privateKeyPath, "update_private_key", 64 * 1024)));
  if (key.asymmetricKeyType !== "ed25519") fail("update_private_key_algorithm_invalid");
  return {
    keyId,
    algorithm: "Ed25519",
    signature: sign(null, payload, key).toString("base64"),
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const version = String(args.version || "");
  const tag = String(args.tag || "");
  if (!/^\d+\.\d+\.\d+$/.test(version) || tag !== `v${version}`) {
    fail("update_manifest_version_invalid");
  }
  const artifact = regularFile(args.artifact, "update_artifact", 1024 * 1024 * 1024);
  if (path.basename(artifact) !== "LicoUp-macos-arm64-update.tar.gz") {
    fail("update_artifact_name_invalid");
  }
  const output = path.resolve(args.output || "");
  if (!output.startsWith(`${path.join(repoRoot, "build")}${path.sep}`) ||
      path.basename(output) !== "LicoUp-update-stable.json") {
    fail("update_manifest_output_invalid");
  }
  const info = lstatSync(artifact);
  const unsigned = {
    schemaVersion: schema,
    channel: "stable",
    channelPolicy: {
      offlineRootKeyId: offlineKeyId,
      onlineChannelKeyId: onlineKeyId,
      allowDowngrade: false,
    },
    releases: [{
      version,
      minimumSupportedVersion: "0.1.0",
      classification: "optional",
      releaseNotesUrl: `https://github.com/LicoLand/LicoUp/releases/tag/${tag}`,
      migrationNotes: [],
      artifacts: [{
        targetId: "macos-arm64",
        platform: "macos",
        osFamily: "darwin",
        arch: "arm64",
        installerStrategy: "app-bundle-replacement",
        url: `https://github.com/LicoLand/LicoUp/releases/download/${tag}/LicoUp-macos-arm64-update.tar.gz`,
        fileName: "LicoUp-macos-arm64-update.tar.gz",
        size: info.size,
        sha256: sha256File(artifact, { maxBytes: 1024 * 1024 * 1024 }),
        applicationName: "LicoUp.app",
        bundleId: "land.lico.licoup",
      }],
    }],
  };
  const payload = Buffer.from(stableStringify(unsigned));
  const manifest = {
    ...unsigned,
    signatures: [
      signature(offlineKeyId, process.env.LICO_UPDATE_OFFLINE_PRIVATE_KEY_PATH, payload),
      signature(onlineKeyId, process.env.LICO_UPDATE_ONLINE_PRIVATE_KEY_PATH, payload),
    ],
  };
  writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644, flag: "wx" });
  process.stdout.write(`${JSON.stringify({ ok: true, version, targetId: "macos-arm64" })}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error?.message || error}\n`);
  process.exitCode = 1;
}
