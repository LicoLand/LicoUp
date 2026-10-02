#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const defaultDockerfile = path.join(repoRoot, "apps/desktop/docker/ubuntu-client.Dockerfile");

// This adapter reproduces the Ubuntu engineering job. Other target hosts own
// their platform toolchain setup and must not reuse the Linux archive flow.
export function assertLinuxEngineeringHost(platform = process.platform) {
  if (platform !== "linux") fail("android_sdk_bootstrap_linux_required");
}

function fail(code) {
  const error = new Error(code);
  error.code = code;
  throw error;
}

function parseArgs(argv) {
  const options = {
    dockerfile: defaultDockerfile,
    project_root: path.join(repoRoot, "apps", "desktop"),
  };
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!value || ![
      "--sdk-root",
      "--command-line-tools-root",
      "--dockerfile",
      "--project-root",
      "--flutter-root",
    ].includes(key)) {
      fail("android_sdk_bootstrap_usage");
    }
    options[key.slice(2).replaceAll("-", "_")] = path.resolve(value);
  }
  if (!options.sdk_root) fail("android_sdk_root_required");
  return Object.freeze(options);
}

function resolveFlutterRoot(options, runCommand) {
  const configured = options.flutter_root || process.env.FLUTTER_ROOT;
  if (configured) return path.resolve(configured);
  const which = runCommand("which", ["flutter"]);
  if (which.status !== 0 || !String(which.stdout || "").trim()) fail("flutter_root_unavailable");
  return path.dirname(path.dirname(realpathSync(String(which.stdout).trim().split(/\r?\n/u)[0])));
}

function writeAndroidLocalProperties(options, flutterRoot) {
  if ([options.sdk_root, flutterRoot].some((value) => /[\r\n]/u.test(value))) {
    fail("android_local_properties_path_invalid");
  }
  if (!existsSync(path.join(flutterRoot, "packages", "flutter_tools", "gradle"))) {
    fail("flutter_root_invalid");
  }
  const androidRoot = path.join(options.project_root, "android");
  if (!existsSync(androidRoot)) fail("android_project_root_invalid");
  writeFileSync(
    path.join(androidRoot, "local.properties"),
    `sdk.dir=${options.sdk_root}\nflutter.sdk=${flutterRoot}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
}

export function readAndroidToolAuthority(dockerfile) {
  const source = readFileSync(dockerfile, "utf8");
  const readArg = (name, pattern) => {
    const matches = [...source.matchAll(new RegExp(`^ARG ${name}=(${pattern})$`, "gmu"))];
    if (matches.length !== 1) fail("android_command_line_tools_authority_invalid");
    return matches[0][1];
  };
  return Object.freeze({
    revision: readArg("ANDROID_COMMAND_LINE_TOOLS_REVISION", "[0-9]+"),
    version: readArg("ANDROID_COMMAND_LINE_TOOLS_VERSION", "[0-9]+\\.[0-9]+"),
    sha256: readArg("ANDROID_COMMAND_LINE_TOOLS_SHA256", "[a-f0-9]{64}"),
  });
}

export function readAndroidPackages(dockerfile) {
  const source = readFileSync(dockerfile, "utf8");
  const names = [
    "ANDROID_PLATFORM_PACKAGE",
    "ANDROID_COMPAT_NDK_PACKAGE",
    "ANDROID_CI_NDK_PACKAGE",
    "ANDROID_PRIMARY_NDK_PACKAGE",
  ];
  return Object.freeze(names.map((name) => {
    const matches = [...source.matchAll(new RegExp(
      `^ARG ${name}=((?:platforms|ndk);[a-zA-Z0-9._-]+)$`, "gmu",
    ))];
    if (matches.length !== 1) fail("client_ci_android_packages_missing");
    return matches[0][1];
  }));
}

function installedVersion(root) {
  const properties = path.join(root, "source.properties");
  if (!existsSync(properties)) return null;
  return readFileSync(properties, "utf8").match(/^Pkg\.Revision\s*=\s*(\S+)\s*$/mu)?.[1] || null;
}

function run(command, args, options = {}) {
  return spawnSync(command, args, {
    encoding: "utf8",
    input: options.input,
    stdio: options.input === undefined ? ["ignore", "pipe", "pipe"] : ["pipe", "pipe", "pipe"],
  });
}

async function sha256(file) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

async function installTools(sdkRoot, authority, runCommand) {
  const destination = path.join(sdkRoot, "cmdline-tools", "licoup");
  if (installedVersion(destination) === authority.version) return destination;
  const temporary = mkdtempSync(path.join(os.tmpdir(), "licoup-android-tools-"));
  try {
    const archive = path.join(temporary, "command-line-tools.zip");
    const download = runCommand("curl", [
      "--retry", "3", "--retry-connrefused", "--retry-delay", "2", "-fsSL",
      `https://dl.google.com/android/repository/commandlinetools-linux-${authority.revision}_latest.zip`,
      "-o", archive,
    ]);
    if (download.status !== 0) fail("android_command_line_tools_download_failed");
    if (await sha256(archive) !== authority.sha256) fail("android_command_line_tools_checksum_failed");
    const extracted = path.join(temporary, "extracted");
    mkdirSync(extracted, { recursive: true, mode: 0o700 });
    if (runCommand("unzip", ["-q", archive, "-d", extracted]).status !== 0) {
      fail("android_command_line_tools_extract_failed");
    }
    const candidate = path.join(extracted, "cmdline-tools");
    if (installedVersion(candidate) !== authority.version) fail("android_command_line_tools_version_mismatch");
    mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
    rmSync(destination, { recursive: true, force: true });
    renameSync(candidate, destination);
    return destination;
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

export async function bootstrapAndroidSdk(options, runCommand = run) {
  const authority = readAndroidToolAuthority(options.dockerfile);
  const packages = readAndroidPackages(options.dockerfile);
  mkdirSync(options.sdk_root, { recursive: true, mode: 0o700 });
  const toolsRoot = options.command_line_tools_root ||
    await installTools(options.sdk_root, authority, runCommand);
  if (installedVersion(toolsRoot) !== authority.version) fail("android_command_line_tools_version_mismatch");
  const sdkmanager = path.join(toolsRoot, "bin", "sdkmanager");
  const sdkRootArgument = `--sdk_root=${options.sdk_root}`;
  const licenses = runCommand(sdkmanager, [sdkRootArgument, "--licenses"], {
    input: "y\n".repeat(200),
  });
  if (licenses.status !== 0) fail("android_sdk_licenses_failed");
  const install = runCommand(sdkmanager, [sdkRootArgument, ...packages], { input: "" });
  if (install.status !== 0) fail("android_sdk_packages_failed");
  writeAndroidLocalProperties(options, resolveFlutterRoot(options, runCommand));
  return Object.freeze({
    ok: true,
    schemaVersion: "licoup.android-sdk-bootstrap.v1",
    status: "passed",
    executionScope: "linux-engineering",
    commandLineToolsVersion: authority.version,
    packageCount: packages.length,
    rawLogsIncluded: false,
  });
}

export async function runAndroidSdkBootstrapSelfTest() {
  const fixture = mkdtempSync(path.join(os.tmpdir(), "licoup-android-sdk-bootstrap-"));
  const toolsRoot = path.join(fixture, "tools");
  const sdkRoot = path.join(fixture, "sdk");
  const flutterRoot = path.join(fixture, "flutter");
  const projectRoot = path.join(fixture, "project");
  const dockerfile = path.join(fixture, "Dockerfile");
  const calls = [];
  try {
    mkdirSync(toolsRoot);
    mkdirSync(path.join(flutterRoot, "packages", "flutter_tools", "gradle"), {
      recursive: true,
    });
    mkdirSync(path.join(projectRoot, "android"), { recursive: true });
    writeFileSync(path.join(toolsRoot, "source.properties"), "Pkg.Revision=12.0\n", "utf8");
    writeFileSync(dockerfile, [
      "ARG ANDROID_COMMAND_LINE_TOOLS_REVISION=11076708",
      "ARG ANDROID_COMMAND_LINE_TOOLS_VERSION=12.0",
      "ARG ANDROID_COMMAND_LINE_TOOLS_SHA256=2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258",
      "ARG ANDROID_PLATFORM_PACKAGE=platforms;android-33",
      "ARG ANDROID_COMPAT_NDK_PACKAGE=ndk;27.0.12077973",
      "ARG ANDROID_CI_NDK_PACKAGE=ndk;28.2.13676358",
      "ARG ANDROID_PRIMARY_NDK_PACKAGE=ndk;30.0.14904198",
      "",
    ].join("\n"), "utf8");
    assert.doesNotThrow(() => assertLinuxEngineeringHost("linux"));
    assert.throws(() => assertLinuxEngineeringHost("darwin"),
      /android_sdk_bootstrap_linux_required/u);
    assert.throws(() => assertLinuxEngineeringHost("win32"),
      /android_sdk_bootstrap_linux_required/u);
    assert.deepEqual(readAndroidToolAuthority(dockerfile), {
      revision: "11076708",
      version: "12.0",
      sha256: "2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258",
    });
    const receipt = await bootstrapAndroidSdk({
      sdk_root: sdkRoot,
      command_line_tools_root: toolsRoot,
      dockerfile,
      flutter_root: flutterRoot,
      project_root: projectRoot,
    }, (command, args, options = {}) => {
      calls.push({ command, args, input: options.input });
      return { status: 0, stdout: "", stderr: "" };
    });
    assert.equal(receipt.status, "passed");
    assert.equal(receipt.executionScope, "linux-engineering");
    assert.equal(receipt.rawLogsIncluded, false);
    assert.deepEqual(calls.map(({ args }) => args), [
      [`--sdk_root=${sdkRoot}`, "--licenses"],
      [
        `--sdk_root=${sdkRoot}`,
        "platforms;android-33",
        "ndk;27.0.12077973",
        "ndk;28.2.13676358",
        "ndk;30.0.14904198",
      ],
    ]);
    assert.equal(calls[0].input.startsWith("y\n"), true);
    assert.equal(readFileSync(path.join(projectRoot, "android", "local.properties"), "utf8"),
      `sdk.dir=${sdkRoot}\nflutter.sdk=${flutterRoot}\n`);
    return Object.freeze({
      ok: true,
      schemaVersion: "licoup.android-sdk-bootstrap.self-test.v1",
      status: "passed",
      networkAccessed: false,
      authorityParsed: true,
      argvPreserved: true,
      linuxScopeEnforced: true,
      localPropertiesWritten: true,
    });
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
}

export async function main(argv = process.argv.slice(2)) {
  try {
    if (argv.length === 1 && argv[0] === "self-test") {
      process.stdout.write(`${JSON.stringify(await runAndroidSdkBootstrapSelfTest())}\n`);
      return;
    }
    assertLinuxEngineeringHost();
    const receipt = await bootstrapAndroidSdk(parseArgs(argv));
    process.stdout.write(`${JSON.stringify(receipt)}\n`);
  } catch (error) {
    const reasonCode = /^[a-z0-9_]+$/u.test(error?.code || error?.message || "")
      ? (error.code || error.message)
      : "android_sdk_bootstrap_failed";
    process.stdout.write(`${JSON.stringify({
      ok: false,
      schemaVersion: "licoup.android-sdk-bootstrap.v1",
      status: "blocked",
      reasonCode,
      rawLogsIncluded: false,
    })}\n`);
    process.exitCode = 2;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
