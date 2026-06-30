#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const workspaceRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const roots = [
  path.join(workspaceRoot, "build", "apps", "desktop", "bundles", "windows", "release", "bundle"),
  path.join(workspaceRoot, "build", "apps", "desktop", "runnable", "windows", "release")
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

async function main() {
  const missing = [];
  for (const root of roots) {
    const kind = root.includes(`${path.sep}runnable${path.sep}`) ? "runnable" : "bundle";
    for (const relativePath of ["flutter_client.exe", "lico-client.exe"]) {
      const size = await fileSize(path.join(root, relativePath));
      if (size <= 0) {
        missing.push(`${root} missing non-empty ${relativePath}`);
      }
    }
    for (const relativePath of [
      path.join("package-metadata", "future-client", "packaging-modules.json"),
      path.join("package-metadata", "windows", "client-manifest.json"),
      "README-windows.txt"
    ]) {
      if (!(await fileExists(path.join(root, relativePath)))) {
        missing.push(`${root} missing ${relativePath}`);
      }
    }
    if (root.includes(`${path.sep}runnable${path.sep}`)) {
      const runnableReadme = "RUNNABLE_CLIENT.txt";
      if (!(await fileExists(path.join(root, runnableReadme)))) {
        missing.push(`${root} missing ${runnableReadme}`);
      }
    }
    const manifestPath = path.join(root, "package-metadata", "windows", "client-manifest.json");
    if (await fileExists(manifestPath)) {
      const manifest = await readJson(manifestPath);
      if (manifest.platform !== "windows") {
        missing.push(`${root} Windows client manifest has platform=${manifest.platform}`);
      }
      if (manifest.kind !== kind) {
        missing.push(`${root} Windows client manifest has kind=${manifest.kind}`);
      }
      if (manifest.executables?.flutterClient !== "flutter_client.exe") {
        missing.push(`${root} Windows client manifest has wrong flutterClient`);
      }
      if (manifest.executables?.licoClient !== "lico-client.exe") {
        missing.push(`${root} Windows client manifest has wrong licoClient`);
      }
    }
  }
  if (missing.length > 0) {
    throw new Error(missing.join("\n"));
  }
  console.log("windows client bundle verification passed");
}

try {
  await main();
} catch (error) {
  console.error(`[windows-bundle] ${error.message}`);
  process.exit(1);
}
