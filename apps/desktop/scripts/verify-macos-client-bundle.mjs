#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { sanitizeError } from "../../../tools/scripts/lib/sanitize-error.mjs";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const localProfile = process.argv.slice(2).includes("--local");
const roots = [
  {
    kind: "bundle",
    root: path.join(workspaceRoot, "build", "apps", "desktop", "bundles", "macos", "release", "bundle"),
    appName: "flutter_client.app"
  },
  {
    kind: "runnable",
    root: path.join(workspaceRoot, "build", "apps", "desktop", "runnable", "macos", "release"),
    appName: "Arc.app"
  }
];

async function fileExists(filePath) {
  try {
    const stat = await fs.stat(filePath);
    return stat.isFile();
  } catch {
    return false;
  }
}

async function fileSize(filePath) {
  try {
    const stat = await fs.stat(filePath);
    return stat.isFile() ? stat.size : 0;
  } catch {
    return 0;
  }
}

async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, "utf8"));
}

async function readText(filePath) {
  return fs.readFile(filePath, "utf8");
}

function appExecutablePath(root, appName, executableName = "flutter_client") {
  return path.join(root, appName, "Contents", "MacOS", executableName);
}

function plistHasString(plist, key, value) {
  const pattern = new RegExp(
    `<key>${key}</key>\\s*<string>${value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}</string>`
  );
  return pattern.test(plist);
}

async function main() {
  const missing = [];
  for (const { kind, root, appName } of roots) {
    const appPath = path.join(root, appName);
    const flutterSize = await fileSize(appExecutablePath(root, appName));
    if (flutterSize <= 0) {
      missing.push(`${appPath} missing non-empty Flutter executable`);
    }
    const plistPath = path.join(appPath, "Contents", "Info.plist");
    if (!(await fileExists(plistPath))) {
      missing.push(`${appPath} missing Info.plist`);
    } else {
      const plist = await readText(plistPath);
      if (!plistHasString(plist, "CFBundleName", "Lico Arc")) {
        missing.push(`${appPath} CFBundleName must be Lico Arc`);
      }
      if (!plistHasString(plist, "CFBundleDisplayName", "Arc")) {
        missing.push(`${appPath} CFBundleDisplayName must be Arc`);
      }
    }
    for (const executableName of ["lico-client"]) {
      const size = await fileSize(appExecutablePath(root, appName, executableName));
      if (size <= 0) {
        missing.push(`${appPath} missing non-empty ${executableName}`);
      }
    }
    for (const relativePath of [
      path.join("package-metadata", "lico-client", "packaging-modules.json"),
      "README-macos.txt"
    ]) {
      if (!(await fileExists(path.join(root, relativePath)))) {
        missing.push(`${root} missing ${relativePath}`);
      }
    }
    if (kind === "runnable" && !(await fileExists(path.join(root, "RUNNABLE_CLIENT.txt")))) {
      missing.push(`${root} missing RUNNABLE_CLIENT.txt`);
    }
    const manifestPath = path.join(root, "package-metadata", "lico-client", "packaging-modules.json");
    if (await fileExists(manifestPath)) {
      const manifest = await readJson(manifestPath);
      if (manifest.platform !== "macos") {
        missing.push(`${root} macOS package manifest has platform=${manifest.platform}`);
      }
      if (manifest.mode !== "release") {
        missing.push(`${root} macOS package manifest has mode=${manifest.mode}`);
      }
      const signing = manifest.signing || {};
      if (signing.signingKind !== "local-ad-hoc-codesign") {
        missing.push(`${root} macOS package manifest has signing.signingKind=${signing.signingKind}`);
      }
      const expectedProductionEntitlements = !localProfile;
      const expectedEntitlementProfile = localProfile ? "release" : "production-release";
      const expectedEntitlementsFile = localProfile
        ? "apps/desktop/macos/Runner/Release.entitlements"
        : "apps/desktop/macos/Runner/ProductionRelease.entitlements";
      if (signing.productionEntitlementsRequested !== expectedProductionEntitlements) {
        missing.push(
          `${root} macOS package manifest has signing.productionEntitlementsRequested=${signing.productionEntitlementsRequested}`
        );
      }
      if (signing.entitlementProfile !== expectedEntitlementProfile) {
        missing.push(`${root} macOS package manifest has signing.entitlementProfile=${signing.entitlementProfile}`);
      }
      if (signing.entitlementsFile !== expectedEntitlementsFile) {
        missing.push(`${root} macOS package manifest has signing.entitlementsFile=${signing.entitlementsFile}`);
      }
      const expectedExecutable = kind === "runnable"
        ? path.join("Arc.app", "Contents", "MacOS", "flutter_client")
        : path.join("flutter_client.app", "Contents", "MacOS", "flutter_client");
      if (manifest.flutterExecutable !== expectedExecutable) {
        missing.push(`${root} macOS package manifest has flutterExecutable=${manifest.flutterExecutable}`);
      }
    }
  }
  if (missing.length > 0) {
    throw new Error(missing.join("\n"));
  }
  console.log(`macOS ${localProfile ? "local" : "production-entitlements"} bundle verification passed`);
}

try {
  await main();
} catch (error) {
  console.error(`[macos-bundle] ${sanitizeError(error)}`);
  process.exit(1);
}
