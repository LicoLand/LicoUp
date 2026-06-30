#!/usr/bin/env node
/**
 * Run client verification commands after explicit toolchain checks.
 *
 * Usage:
 *   node tools/scripts/client-toolchain-runner.mjs --check cargo -- cargo test --workspace
 *   node tools/scripts/client-toolchain-runner.mjs --check flutter --cwd apps/desktop -- flutter analyze
 */

import { spawn, spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  symlinkSync,
  unlinkSync,
  writeFileSync
} from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_CLIENT_PUB_CACHE = path.join(ROOT, ".cache", "flutter", "pub-cache");
const FLUTTER_GENERATED_PLUGIN_FILES = [
  "linux/flutter/generated_plugin_registrant.cc",
  "linux/flutter/generated_plugin_registrant.h",
  "linux/flutter/generated_plugins.cmake",
  "macos/Flutter/GeneratedPluginRegistrant.swift",
  "windows/flutter/generated_plugin_registrant.cc",
  "windows/flutter/generated_plugin_registrant.h",
  "windows/flutter/generated_plugins.cmake"
];

function parseArgs(argv) {
  const checks = [];
  let cwd = ROOT;
  const separator = argv.indexOf("--");
  if (separator === -1 || separator === argv.length - 1) {
    throw new Error("Command must be provided after --");
  }
  const optionArgs = argv.slice(0, separator);
  const commandArgs = argv.slice(separator + 1);

  for (let index = 0; index < optionArgs.length; index += 1) {
    const arg = optionArgs[index];
    if (arg === "--check" && optionArgs[index + 1]) {
      checks.push(optionArgs[index + 1]);
      index += 1;
    } else if (arg === "--check-docker") {
      checks.push("docker");
    } else if (arg === "--cwd" && optionArgs[index + 1]) {
      cwd = resolveWorkspaceCwd(optionArgs[index + 1]);
      index += 1;
    } else {
      throw new Error(`Unknown client runner option: ${arg}`);
    }
  }

  return {
    checks,
    cwd,
    command: commandArgs[0],
    args: commandArgs.slice(1)
  };
}

function resolveWorkspaceCwd(value) {
  const resolved = path.resolve(ROOT, value);
  if (resolved !== ROOT && !resolved.startsWith(`${ROOT}${path.sep}`)) {
    throw new Error(`Client runner cwd escapes workspace: ${value}`);
  }
  return resolved;
}

function quoteWindowsCommandArg(value) {
  const text = String(value);
  if (text.length === 0) {
    return '""';
  }
  if (!/[\s"&()^|<>]/.test(text)) {
    return text;
  }
  return `"${text.replaceAll('"', '""')}"`;
}

function commandHasPathSeparator(command) {
  return command.includes(path.sep) || (process.platform === "win32" && command.includes("/"));
}

function windowsCommandCandidateRank(candidate) {
  const extension = path.extname(candidate).toLowerCase();
  if (extension === ".exe" || extension === ".com") return 0;
  if (extension === ".cmd" || extension === ".bat") return 1;
  if (extension) return 20;
  return 100;
}

function resolveWindowsPathCommand(command) {
  const extension = path.extname(command);
  const candidates = extension
    ? [command]
    : [
        `${command}.exe`,
        `${command}.com`,
        `${command}.cmd`,
        `${command}.bat`,
        command
      ];
  return candidates.find((candidate) => existsSync(candidate)) || command;
}

function resolveCommand(command) {
  if (process.platform !== "win32") {
    return command;
  }
  if (commandHasPathSeparator(command)) {
    return resolveWindowsPathCommand(command);
  }
  const result = spawnSync("where.exe", [command], {
    cwd: ROOT,
    encoding: "utf8",
    windowsHide: true
  });
  if (result.status !== 0) {
    return command;
  }
  const candidates = String(result.stdout || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  return candidates.sort((a, b) => windowsCommandCandidateRank(a) - windowsCommandCandidateRank(b))[0] || command;
}

function trimYamlScalar(value) {
  const trimmed = String(value || "").trim();
  if (
    (trimmed.startsWith("\"") && trimmed.endsWith("\"")) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function pubCacheHostForUrl(value) {
  const normalized = trimYamlScalar(value || "https://pub.dev");
  try {
    return new URL(normalized).host || "pub.dev";
  } catch {
    return normalized || "pub.dev";
  }
}

function defaultSystemPubCacheRoot() {
  if (process.platform === "win32") {
    return path.resolve(process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"), "Pub", "Cache");
  }
  return path.resolve(os.homedir(), ".pub-cache");
}

function clientPubCacheRoot() {
  return path.resolve(process.env.LICO_CLIENT_PUB_CACHE || DEFAULT_CLIENT_PUB_CACHE);
}

function lockFilePath(projectRoot) {
  return path.join(projectRoot, "pubspec.lock");
}

function parseLockedHostedPackages(lockPath) {
  if (!existsSync(lockPath)) {
    return [];
  }
  const packages = [];
  let current = null;
  const finishCurrent = () => {
    if (!current || current.source !== "hosted") {
      return;
    }
    if (!current.version) {
      throw new Error(`Hosted pub package has no locked version: ${current.name}`);
    }
    packages.push({
      name: current.descriptionName || current.name,
      version: current.version,
      url: current.url || "https://pub.dev",
      host: pubCacheHostForUrl(current.url)
    });
  };

  for (const line of readFileSync(lockPath, "utf8").split(/\r?\n/)) {
    const packageMatch = /^  ([A-Za-z0-9_]+):\s*$/.exec(line);
    if (packageMatch) {
      finishCurrent();
      current = {
        name: packageMatch[1],
        descriptionName: null,
        source: null,
        url: null,
        version: null
      };
      continue;
    }
    if (!current) {
      continue;
    }
    const sourceMatch = /^    source:\s+(.+?)\s*$/.exec(line);
    if (sourceMatch) {
      current.source = trimYamlScalar(sourceMatch[1]);
      continue;
    }
    const versionMatch = /^    version:\s+(.+?)\s*$/.exec(line);
    if (versionMatch) {
      current.version = trimYamlScalar(versionMatch[1]);
      continue;
    }
    const descriptionNameMatch = /^      name:\s+(.+?)\s*$/.exec(line);
    if (descriptionNameMatch) {
      current.descriptionName = trimYamlScalar(descriptionNameMatch[1]);
      continue;
    }
    const urlMatch = /^      url:\s+(.+?)\s*$/.exec(line);
    if (urlMatch) {
      current.url = trimYamlScalar(urlMatch[1]);
    }
  }
  finishCurrent();
  return packages;
}

function preferredPubHostedUrl(projectRoot) {
  return process.env.LICO_CLIENT_PUB_HOSTED_URL ||
    parseLockedHostedPackages(lockFilePath(projectRoot))[0]?.url ||
    process.env.PUB_HOSTED_URL ||
    "https://pub.dev";
}

function sourcePubCacheRoots(targetPubCache) {
  const roots = [
    process.env.PUB_CACHE ? path.resolve(process.env.PUB_CACHE) : null,
    defaultSystemPubCacheRoot()
  ].filter(Boolean);
  return [...new Set(roots)].filter((root) => path.resolve(root) !== path.resolve(targetPubCache));
}

function hostedCacheDirs(pubCacheRoot) {
  const hostedRoot = path.join(pubCacheRoot, "hosted");
  if (!existsSync(hostedRoot)) {
    return [];
  }
  return statSync(hostedRoot).isDirectory()
    ? readDirectoryNames(hostedRoot)
    : [];
}

function readDirectoryNames(root) {
  return Array.from(new Set(
    readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
  ));
}

function candidateHostedCacheHosts(packageRef, sourcePubCache) {
  return [
    packageRef.host,
    process.env.PUB_HOSTED_URL ? pubCacheHostForUrl(process.env.PUB_HOSTED_URL) : null,
    "pub.dev",
    "pub.flutter-io.cn",
    ...hostedCacheDirs(sourcePubCache)
  ].filter(Boolean).filter((value, index, list) => list.indexOf(value) === index);
}

function copyLockedPackageFromCache(sourcePubCache, targetPubCache, packageRef) {
  const packageDirName = `${packageRef.name}-${packageRef.version}`;
  const targetPackageDir = path.join(targetPubCache, "hosted", packageRef.host, packageDirName);
  if (existsSync(targetPackageDir)) {
    return "present";
  }

  for (const sourceHost of candidateHostedCacheHosts(packageRef, sourcePubCache)) {
    const sourcePackageDir = path.join(sourcePubCache, "hosted", sourceHost, packageDirName);
    if (!existsSync(sourcePackageDir)) {
      continue;
    }
    mkdirSync(path.dirname(targetPackageDir), { recursive: true });
    cpSync(sourcePackageDir, targetPackageDir, { recursive: true, dereference: false });
    const sourceHashFile = path.join(sourcePubCache, "hosted-hashes", sourceHost, `${packageDirName}.sha256`);
    if (existsSync(sourceHashFile)) {
      const targetHashFile = path.join(targetPubCache, "hosted-hashes", packageRef.host, `${packageDirName}.sha256`);
      mkdirSync(path.dirname(targetHashFile), { recursive: true });
      cpSync(sourceHashFile, targetHashFile);
    }
    return "copied";
  }
  return "missing";
}

function seedStablePubCache(projectRoot, env) {
  const lockPath = lockFilePath(projectRoot);
  const packageRefs = parseLockedHostedPackages(lockPath);
  if (packageRefs.length === 0) {
    return;
  }
  const targetPubCache = env.PUB_CACHE;
  mkdirSync(targetPubCache, { recursive: true });
  let copied = 0;
  const missing = new Set();
  for (const packageRef of packageRefs) {
    let status = "missing";
    for (const cacheRoot of sourcePubCacheRoots(targetPubCache)) {
      status = copyLockedPackageFromCache(cacheRoot, targetPubCache, packageRef);
      if (status !== "missing") {
        break;
      }
    }
    if (status === "copied") {
      copied += 1;
    } else if (status === "missing") {
      missing.add(`${packageRef.name}-${packageRef.version}`);
    }
  }
  console.log(`[client-toolchain-runner] Flutter pub cache: ${path.relative(ROOT, targetPubCache) || targetPubCache}`);
  if (copied > 0) {
    console.log(`[client-toolchain-runner] Seeded ${copied} locked pub package(s) into the local cache.`);
  }
  if (missing.size > 0) {
    console.warn(
      `[client-toolchain-runner] ${missing.size} locked pub package(s) are not in existing caches; ` +
        "run npm run client:get once if offline analysis cannot resolve them."
    );
  }
}

function flutterEnv(projectRoot) {
  const pubCache = clientPubCacheRoot();
  mkdirSync(pubCache, { recursive: true });
  return {
    ...process.env,
    PUB_CACHE: pubCache,
    PUB_HOSTED_URL: preferredPubHostedUrl(projectRoot)
  };
}

function isFlutterCommand(command) {
  const basename = path.basename(command).toLowerCase();
  return basename === "flutter" || basename === "flutter.bat" || basename === "flutter.cmd" || basename === "flutter.exe";
}

function isFlutterPubGet(args) {
  return args[0] === "pub" && args[1] === "get";
}

function shouldPrepareFlutterDependencies(args) {
  return args[0] === "analyze" || args[0] === "test";
}

function withNoImplicitPub(args) {
  if (!shouldPrepareFlutterDependencies(args) || args.includes("--no-pub")) {
    return args;
  }
  return [args[0], "--no-pub", ...args.slice(1)];
}

function withEnforcedLockfile(args) {
  if (!isFlutterPubGet(args) || args.includes("--enforce-lockfile")) {
    return args;
  }
  return [...args, "--enforce-lockfile"];
}

function desktopPluginLinkRoot(projectRoot, platform) {
  return path.join(projectRoot, platform, "flutter", "ephemeral", ".plugin_symlinks");
}

function createDesktopPluginJunctions(projectRoot) {
  const dependenciesPath = path.join(projectRoot, ".flutter-plugins-dependencies");
  if (!existsSync(dependenciesPath)) {
    return 0;
  }
  const dependencies = JSON.parse(readFileSync(dependenciesPath, "utf8"));
  let created = 0;
  for (const platform of ["windows", "linux"]) {
    const platformRoot = path.join(projectRoot, platform);
    const plugins = dependencies.plugins?.[platform] || [];
    if (!existsSync(platformRoot) || plugins.length === 0) {
      continue;
    }
    const linkRoot = desktopPluginLinkRoot(projectRoot, platform);
    mkdirSync(linkRoot, { recursive: true });
    for (const plugin of plugins) {
      if (!plugin?.name || !plugin?.path) {
        continue;
      }
      const target = path.resolve(plugin.path);
      if (!existsSync(target) || !statSync(target).isDirectory()) {
        continue;
      }
      const link = path.join(linkRoot, plugin.name);
      if (existsSync(link)) {
        continue;
      }
      symlinkSync(target, link, "junction");
      created += 1;
    }
  }
  return created;
}

async function runFlutterPubGet(projectRoot, env, { offline }) {
  const args = ["pub", "get", "--enforce-lockfile", ...(offline ? ["--offline"] : [])];
  try {
    await run("flutter", args, { cwd: projectRoot, env });
  } catch (error) {
    if (process.platform !== "win32") {
      throw error;
    }
    const created = createDesktopPluginJunctions(projectRoot);
    if (created === 0) {
      throw error;
    }
    console.warn(`[client-toolchain-runner] Created ${created} Flutter plugin junction(s); retrying pub get.`);
    await run("flutter", args, { cwd: projectRoot, env });
  }
}

function snapshotFlutterGeneratedPluginFiles(projectRoot) {
  return FLUTTER_GENERATED_PLUGIN_FILES.map((relativePath) => {
    const absolutePath = path.join(projectRoot, relativePath);
    return {
      absolutePath,
      exists: existsSync(absolutePath),
      content: existsSync(absolutePath) ? readFileSync(absolutePath) : null
    };
  });
}

function restoreFlutterGeneratedPluginFiles(snapshot) {
  for (const item of snapshot) {
    if (item.exists) {
      writeFileSync(item.absolutePath, item.content);
    } else if (existsSync(item.absolutePath)) {
      unlinkSync(item.absolutePath);
    }
  }
}

async function prepareFlutterCommand(command, args, cwd) {
  if (!isFlutterCommand(command) || !existsSync(path.join(cwd, "pubspec.yaml"))) {
    return { command, args, env: process.env };
  }
  const env = flutterEnv(cwd);
  seedStablePubCache(cwd, env);
  if (shouldPrepareFlutterDependencies(args)) {
    const generatedPluginSnapshot = snapshotFlutterGeneratedPluginFiles(cwd);
    try {
      await runFlutterPubGet(cwd, env, { offline: true });
    } finally {
      restoreFlutterGeneratedPluginFiles(generatedPluginSnapshot);
    }
    return { command, args: withNoImplicitPub(args), env };
  }
  return { command, args: withEnforcedLockfile(args), env };
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const resolvedCommand = resolveCommand(command);
    const env = options.env || process.env;
    const isWindowsScript = process.platform === "win32" && /\.(?:cmd|bat)$/i.test(resolvedCommand);
    const child = isWindowsScript ? spawn(
      process.env.ComSpec || "cmd.exe",
      ["/d", "/s", "/c", ["call", resolvedCommand, ...args].map(quoteWindowsCommandArg).join(" ")],
      {
        cwd: options.cwd || ROOT,
        stdio: options.stdio || "inherit",
        env,
        windowsHide: true
      }
    ) : spawn(resolvedCommand, args, {
      cwd: options.cwd || ROOT,
      stdio: options.stdio || "inherit",
      shell: false,
      env,
      windowsHide: true
    });
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${command} ${args.join(" ")} exited with code ${code}`));
      }
    });
    child.on("error", reject);
  });
}

async function toolExists(command) {
  try {
    if (process.platform === "win32") {
      const resolvedCommand = resolveCommand(command);
      return resolvedCommand !== command || existsSync(resolvedCommand);
    }
    await run("which", [command], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

async function dockerAvailable() {
  try {
    await run("docker", ["info"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

async function verifyToolchain(checks) {
  for (const check of checks) {
    if (check === "cargo" && !(await toolExists("cargo"))) {
      throw new Error("Cargo not found");
    }
    if (check === "flutter" && !(await toolExists("flutter"))) {
      throw new Error("Flutter not found");
    }
    if (check === "docker" && !(await dockerAvailable())) {
      throw new Error("Docker not available");
    }
    if (!["cargo", "flutter", "docker"].includes(check)) {
      throw new Error(`Unknown toolchain check: ${check}`);
    }
  }
}

try {
  const { checks, cwd, command, args } = parseArgs(process.argv.slice(2));
  await verifyToolchain(checks);
  const prepared = await prepareFlutterCommand(command, args, cwd);
  console.log(`[client-toolchain-runner] ${path.relative(ROOT, cwd) || "."}$ ${[prepared.command, ...prepared.args].join(" ")}`);
  await run(prepared.command, prepared.args, { cwd, env: prepared.env });
} catch (error) {
  console.error(`[client-toolchain-runner] ${error.message}`);
  process.exit(1);
}
