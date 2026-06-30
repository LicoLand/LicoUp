#!/usr/bin/env node
import { copyFileSync, existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const flutterClientRoot = path.join(workspaceRoot, "apps", "desktop");
const outputRoot = path.join(workspaceRoot, "build", "apps", "desktop", "android");
const localFlutterBuildRoot = path.join(flutterClientRoot, "build");
const localAndroidBuildRoot = path.join(flutterClientRoot, "android", "build");

function parseArgs(argv = process.argv.slice(2)) {
  const options = {
    mode: "debug",
    keepLocalBuild: process.env.LICO_KEEP_FLUTTER_BUILD_CACHE === "1",
    passthrough: []
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === "--mode" && next) {
      options.mode = normalizeMode(next);
      index += 1;
    } else if (["--debug", "--profile", "--release"].includes(arg)) {
      options.mode = normalizeMode(arg.slice(2));
    } else if (arg === "--keep-local-build" || arg === "--keep-flutter-build-cache") {
      options.keepLocalBuild = true;
    } else {
      options.passthrough.push(arg);
    }
  }
  return options;
}

function normalizeMode(value) {
  const normalized = String(value || "").toLowerCase();
  if (["debug", "profile", "release"].includes(normalized)) {
    return normalized;
  }
  throw new Error(`Unsupported Android build mode: ${value}`);
}

function hasOption(args, name) {
  return args.some((arg) => arg === name || arg.startsWith(`${name}=`));
}

function runFlutterBuild(options) {
  const args = ["build", "apk", `--${options.mode}`, ...options.passthrough];
  if (!hasOption(args, "--android-project-cache-dir")) {
    args.push("--android-project-cache-dir", path.join(outputRoot, ".gradle"));
  }
  execFileSync("flutter", args, {
    cwd: flutterClientRoot,
    stdio: "inherit"
  });
}

function collectApks(directory, files = []) {
  if (!existsSync(directory)) {
    return files;
  }
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const child = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      collectApks(child, files);
    } else if (entry.isFile() && entry.name.endsWith(".apk")) {
      files.push(child);
    }
  }
  return files;
}

function stageApks(options) {
  const apkSearchRoots = [
    path.join(localFlutterBuildRoot, "app", "outputs", "flutter-apk"),
    path.join(localFlutterBuildRoot, "app", "outputs", "apk")
  ];
  const apks = apkSearchRoots.flatMap((apkSearchRoot) => collectApks(apkSearchRoot));
  if (apks.length === 0) {
    throw new Error("No Android APK was produced by flutter build apk.");
  }

  const outputDir = path.join(outputRoot, options.mode);
  rmSync(outputDir, { recursive: true, force: true });
  mkdirSync(outputDir, { recursive: true });

  const staged = [];
  for (const apk of apks.sort()) {
    const target = path.join(outputDir, path.basename(apk));
    copyFileSync(apk, target);
    staged.push({
      file: path.relative(workspaceRoot, target),
      byteSize: statSync(target).size
    });
  }

  const manifestPath = path.join(outputDir, "manifest.json");
  writeFileSync(
    manifestPath,
    `${JSON.stringify({
      schemaVersion: "v0.0.1:client-android:apk-manifest-1",
      generatedAt: new Date().toISOString(),
      mode: options.mode,
      outputDir: path.relative(workspaceRoot, outputDir),
      apks: staged
    }, null, 2)}\n`,
    "utf8"
  );
  return { outputDir, manifestPath, staged };
}

function cleanupLocalBuild(options) {
  if (options.keepLocalBuild) {
    return;
  }
  rmSync(localFlutterBuildRoot, { recursive: true, force: true });
  rmSync(localAndroidBuildRoot, { recursive: true, force: true });
}

function main() {
  const options = parseArgs();
  runFlutterBuild(options);
  const result = stageApks(options);
  cleanupLocalBuild(options);
  console.log("");
  console.log(`Android APK output: ${result.outputDir}`);
  for (const apk of result.staged) {
    console.log(`APK: ${apk.file} (${apk.byteSize} bytes)`);
  }
  console.log(`Manifest: ${result.manifestPath}`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}
