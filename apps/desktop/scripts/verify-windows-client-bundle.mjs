#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { sha256File } from "../../../tools/scripts/lib/client-release-artifact-digest.mjs";
import { inspectWindowsPeFile } from "../../../tools/scripts/lib/windows-pe-facts.mjs";

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
        missing.push(`${kind} missing non-empty ${relativePath}`);
      }
    }
    for (const relativePath of [
      path.join("package-metadata", "lico-client", "packaging-modules.json"),
      path.join("package-metadata", "windows", "client-manifest.json"),
      "README-windows.txt"
    ]) {
      if (!(await fileExists(path.join(root, relativePath)))) {
        missing.push(`${kind} missing ${relativePath}`);
      }
    }
    if (root.includes(`${path.sep}runnable${path.sep}`)) {
      const runnableReadme = "RUNNABLE_CLIENT.txt";
      if (!(await fileExists(path.join(root, runnableReadme)))) {
        missing.push(`${kind} missing ${runnableReadme}`);
      }
    }
    const manifestPath = path.join(root, "package-metadata", "windows", "client-manifest.json");
    if (await fileExists(manifestPath)) {
      const manifest = await readJson(manifestPath);
      if (manifest.platform !== "windows") {
        missing.push(`${kind} Windows client manifest platform is invalid`);
      }
      if (manifest.kind !== kind) {
        missing.push(`${kind} Windows client manifest kind is invalid`);
      }
      if (manifest.targetId !== "windows-x64" || manifest.architecture !== "x64") {
        missing.push(`${kind} Windows client manifest target is not windows-x64`);
      }
      if (!/^sha256:[a-f0-9]{64}$/u.test(String(manifest.sourceStateDigest || ""))) {
        missing.push(`${kind} Windows client manifest source digest is invalid`);
      }
      if (manifest.executables?.flutterClient !== "flutter_client.exe") {
        missing.push(`${kind} Windows client manifest has wrong flutterClient`);
      }
      if (manifest.executables?.licoClient !== "lico-client.exe") {
        missing.push(`${kind} Windows client manifest has wrong licoClient`);
      }
      for (const [key, relativePath] of [
        ["flutterClient", "flutter_client.exe"],
        ["licoClient", "lico-client.exe"],
      ]) {
        const artifactPath = path.join(root, relativePath);
        const declared = manifest.artifacts?.[key] || {};
        let facts;
        try {
          facts = inspectWindowsPeFile(artifactPath);
        } catch {
          missing.push(`${kind} ${relativePath} is not a supported PE32+ executable`);
          continue;
        }
        if (facts.architecture !== "x64" || declared.pe?.architecture !== "x64" ||
            declared.pe?.machine !== facts.machine || declared.pe?.format !== "PE32+") {
          missing.push(`${kind} ${relativePath} PE architecture facts are invalid`);
        }
        if (declared.ref !== relativePath || declared.sha256 !== sha256File(artifactPath)) {
          missing.push(`${kind} ${relativePath} digest binding is invalid`);
        }
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
