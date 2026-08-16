#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { updateSigningKeyEnvironment } from "./lib/update-signing-keychain.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const buildRoot = path.join(repoRoot, "build");
const repository = "LicoLand/LicoUp";
const target = "macos-direct-arm64";

function fail() {
  throw new Error("macos_release_publication_failed");
}

function run(program, args, {
  capture = false,
  env = process.env,
  timeout = 2 * 60 * 60 * 1000,
} = {}) {
  const result = spawnSync(program, args, {
    cwd: repoRoot,
    env,
    encoding: "utf8",
    stdio: capture ? ["ignore", "pipe", "ignore"] : "inherit",
    ...(timeout == null ? {} : { timeout }),
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) fail();
  return String(result.stdout || "").trim();
}

function main() {
  if (process.platform !== "darwin" || process.arch !== "arm64" ||
    process.argv.length !== 2) fail();
  const version = JSON.parse(readFileSync(
    path.join(repoRoot, "tools/client-version.json"), "utf8",
  )).productVersion;
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(version)) fail();
  const sourceRevision = run("git", ["rev-parse", "HEAD"], { capture: true });
  const releaseRevision = run("git", ["rev-parse", "refs/remotes/origin/release"], {
    capture: true,
  });
  if (sourceRevision !== releaseRevision || !/^[a-f0-9]{40,64}$/u.test(sourceRevision)) fail();

  run(process.execPath, ["tools/scripts/client-macos-release-tool.mjs", "beta"], {
    timeout: null,
  });
  run(process.execPath, ["tools/scripts/client-release-packages.mjs", "build", "--target", target]);
  run(process.execPath, ["tools/scripts/client-release-packages.mjs", "verify", "--target", target]);
  run(process.execPath, ["tools/scripts/client-github-release-acceptance.mjs"], {
    env: { ...process.env, LICO_CLIENT_RELEASE_TARGETS: target },
  });

  const temporaryRoot = mkdtempSync(path.join(buildRoot, ".macos-publication-"));
  try {
    const signedManifest = path.join(temporaryRoot, "LicoUp-update-manifest.json");
    const publicKeys = path.join(temporaryRoot, "LicoUp-update-public-keys.json");
    const incomingRoot = path.join(buildRoot, "releases", version);
    run(process.execPath, [
      "tools/scripts/client-update-manifest.mjs",
      "--assets", path.join(incomingRoot, target),
      "--output", signedManifest,
      "--public-keys-output", publicKeys,
      "--tag", `v${version}`,
      "--repo", repository,
      "--targets", target,
      "--minimum-supported-version", "0.0.0",
    ], { env: updateSigningKeyEnvironment() });
    const token = run("gh", ["auth", "token"], { capture: true, timeout: 60_000 });
    if (!token) fail();
    run(process.execPath, [
      "tools/scripts/client-github-release-publish.mjs",
      "--tag", `v${version}`,
      "--targets", target,
      "--incoming-root", incomingRoot,
      "--assets", path.join(temporaryRoot, "assets"),
      "--publish", "true",
    ], {
      env: {
        ...process.env,
        GH_TOKEN: token,
        GITHUB_REPOSITORY: repository,
        LICO_RELEASE_SOURCE_REVISION: sourceRevision,
        LICO_SIGNED_UPDATE_MANIFEST_BASE64: readFileSync(signedManifest).toString("base64"),
      },
    });
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
  process.stdout.write(`${JSON.stringify({
    ok: true,
    version,
    target,
    published: true,
    installed: true,
    launched: true,
    privateDataIncluded: false,
  })}\n`);
}

try {
  main();
} catch {
  process.stderr.write(`${JSON.stringify({
    ok: false,
    code: "macos_release_publication_failed",
    privateDataIncluded: false,
  })}\n`);
  process.exitCode = 1;
}
