#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  validatePrepareRunBinding,
  validatePreparedArtifact,
} from "./client-release-workflow-binding.mjs";
import { sha256File } from "./lib/client-release-artifact-digest.mjs";
import { updateSigningKeyEnvironment } from "./lib/update-signing-keychain.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const repository = "LicoLand/LicoUp";
const workflow = ".github/workflows/client-release.yml";

function fail() { throw new Error("local release publication failed closed"); }

function run(command, args, { capture = false, env = process.env } = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    env,
    shell: false,
    stdio: capture ? ["ignore", "pipe", "ignore"] : ["ignore", "ignore", "ignore"],
    timeout: 10 * 60 * 1000,
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) fail();
  return String(result.stdout || "");
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    if (!argv[index]?.startsWith("--") || argv[index + 1] === undefined) fail();
    values[argv[index].slice(2)] = argv[index + 1];
  }
  return values;
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!/^[1-9][0-9]{0,19}$/u.test(args["prepare-run-id"] || "") ||
    !/^[a-f0-9]{64}$/u.test(args.correlation || "")) fail();
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "licoup-local-publish-"));
  const incoming = path.join(temporaryRoot, "incoming");
  try {
    const run = JSON.parse(run("gh", ["api",
      `repos/${repository}/actions/runs/${args["prepare-run-id"]}`], { capture: true }));
    const sourceRevision = String(run.head_sha || "");
    validatePrepareRunBinding(run, {
      runId: args["prepare-run-id"], sourceRevision,
      tag: "v0.1.0", target: "macos-arm64", correlation: args.correlation,
    });
    run("gh", ["run", "download", args["prepare-run-id"], "--repo", repository,
      "--name", "licoup-macos", "--dir", incoming]);
    const artifactDigest = sha256File(path.join(incoming, "LicoUp-macos-arm64.dmg"), {
      maxBytes: 8 * 1024 * 1024 * 1024,
    });
    validatePreparedArtifact(incoming, "macos-arm64", artifactDigest);
    const manifestPath = path.join(temporaryRoot, "LicoUp-update-manifest.json");
    const publicKeysPath = path.join(temporaryRoot, "LicoUp-update-public-keys.json");
    run(process.execPath, [
      "tools/scripts/client-update-manifest.mjs",
      "--assets", incoming,
      "--output", manifestPath,
      "--public-keys-output", publicKeysPath,
      "--tag", "v0.1.0",
      "--repo", repository,
      "--targets", "macos-arm64=true,linux-glibc-arm64=false,android-arm64=false",
      "--minimum-supported-version", "0.0.0",
    ], { env: updateSigningKeyEnvironment() });
    const generatedKeys = JSON.parse(readFileSync(publicKeysPath, "utf8"));
    const bundledKeys = JSON.parse(readFileSync(path.join(repoRoot,
      "crates/licoup-native/resources/client-update-public-keys.json"), "utf8"));
    if (canonicalJson(generatedKeys) !== canonicalJson(bundledKeys)) fail();
    const encodedManifest = readFileSync(manifestPath).toString("base64");
    run("gh", ["workflow", "run", workflow, "--repo", repository, "--ref", "release",
      "--raw-field", "phase=publish",
      "--raw-field", "release_tag=v0.1.0",
      "--raw-field", "target=macos-arm64",
      "--raw-field", `correlation=${args.correlation}`,
      "--raw-field", `prepare_run_id=${args["prepare-run-id"]}`,
      "--raw-field", `source_revision=${sourceRevision}`,
      "--raw-field", `artifact_digest=${artifactDigest}`,
      "--raw-field", `signed_update_manifest_base64=${encodedManifest}`,
      "--raw-field", "publish_release=true"]);
    process.stdout.write(`${JSON.stringify({ ok: true, phase: "publish-dispatched",
      prepareRunId: args["prepare-run-id"], sourceRevision,
      artifactDigest, correlation: args.correlation, privateDataIncluded: false })}\n`);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(); } catch {
    process.stderr.write(`${JSON.stringify({ ok: false,
      code: "local_release_publication_failed", privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  }
}
