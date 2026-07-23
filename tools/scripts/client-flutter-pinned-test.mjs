#!/usr/bin/env node
import { cpSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const sourceRoot = path.join(workspaceRoot, "apps", "desktop");
const image = process.env.LICO_FLUTTER_TEST_IMAGE || "lico-arc-flutter-test:3.44.2";
const pubCacheVolume = process.env.LICO_FLUTTER_TEST_PUB_CACHE ||
  "lico-arc-flutter-3-44-2-pub";
const testArgs = process.argv.slice(2);
const containerWorkspace = path.posix.join(path.posix.sep, "workspace");
const containerPubCache = path.posix.join(path.posix.sep, "root", ".pub-cache");

function redact(value, stagingRoot = "") {
  return [
    [workspaceRoot, "<repo>"],
    [os.homedir(), "<home>"],
    [stagingRoot, "<staging>"]
  ].reduce(
    (text, [sensitive, replacement]) => sensitive
      ? text.split(sensitive).join(replacement)
      : text,
    String(value || "")
  ).slice(-16000);
}

function runDocker(args, timeoutMs) {
  return spawnSync("docker", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: timeoutMs
  });
}

let stagingRoot = "";
try {
  if (testArgs.length === 0) {
    throw new Error("Pass one or more flutter test arguments.");
  }
  stagingRoot = mkdtempSync(path.join(os.tmpdir(), "lico-arc-flutter-test-"));
  for (const entry of [
    "analysis_options.yaml",
    "assets",
    "lib",
    "pubspec.lock",
    "pubspec.yaml",
    "test"
  ]) {
    const source = path.join(sourceRoot, entry);
    if (existsSync(source)) {
      cpSync(source, path.join(stagingRoot, entry), { recursive: true });
    }
  }
  const common = [
    "run",
    "--rm",
    "--platform",
    "linux/amd64",
    "-v",
    `${stagingRoot}:${containerWorkspace}`,
    "-v",
    `${pubCacheVolume}:${containerPubCache}`,
    "-w",
    containerWorkspace,
    image
  ];
  const dependencies = runDocker(
    [...common, "flutter", "pub", "get", "--enforce-lockfile"],
    10 * 60 * 1000
  );
  if (dependencies.status !== 0) {
    throw new Error(
      `Pinned Flutter dependency resolution failed.\n${dependencies.stdout || ""}\n` +
      `${dependencies.stderr || ""}`
    );
  }
  const tests = runDocker(
    [...common, "flutter", "test", "--no-pub", ...testArgs],
    20 * 60 * 1000
  );
  if (tests.status !== 0) {
    throw new Error(
      `Pinned Flutter tests failed.\n${tests.stdout || ""}\n${tests.stderr || ""}`
    );
  }
  process.stdout.write(`${JSON.stringify({
    ok: true,
    flutterVersion: "3.44.2",
    isolatedSourceCopy: true,
    testArgumentCount: testArgs.length,
    privatePathsIncluded: false
  })}\n`);
} catch (error) {
  process.stderr.write(`${redact(error?.message || error, stagingRoot)}\n`);
  process.exitCode = 1;
} finally {
  if (stagingRoot) {
    rmSync(stagingRoot, { recursive: true, force: true });
  }
}
