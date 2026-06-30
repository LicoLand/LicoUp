#!/usr/bin/env node
import { readdir, readFile, stat, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const ignoredDirs = new Set([
  ".git",
  "node_modules",
  "build",
  "target",
  ".dart_tool",
  ".pub-cache",
  ".pub",
  "Pods",
  "ephemeral",
  ".idea",
  ".vscode"
]);
const textExtensions = new Set([
  ".dart",
  ".mjs",
  ".js",
  ".json",
  ".md",
  ".rs",
  ".toml",
  ".yaml",
  ".yml",
  ".xml",
  ".plist",
  ".gradle",
  ".kts",
  ".swift",
  ".h",
  ".cc",
  ".cpp",
  ".c",
  ".cmake",
  ".txt"
]);
const serverScriptsPath = "tools/" + "server" + "-scripts";
const forbiddenPathParts = [
  "apps/desktop/.dart_tool",
  "apps/desktop/build",
  "apps/desktop/ios/build",
  "apps/desktop/linux/flutter/ephemeral",
  "apps/desktop/macos/Flutter/ephemeral",
  "apps/desktop/macos/Pods",
  "apps/desktop/windows/flutter/ephemeral",
  "crates/lico-client-native/target",
  serverScriptsPath
];
const forbiddenContent = [
  { pattern: /\/Users\/[A-Za-z0-9._-]+/g, label: "macOS home path" },
  { pattern: /\/home\/[A-Za-z0-9._-]+/g, label: "Linux home path" },
  { pattern: /C:\\Users\\[A-Za-z0-9._ -]+/g, label: "Windows home path" },
  { pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----/g, label: "private key" },
  { pattern: new RegExp(serverScriptsPath.replace("/", "\\/"), "g"), label: "server script path" },
  { pattern: /\bserver:[A-Za-z0-9:_-]+/g, label: "server npm script" },
  { pattern: /\b(?:TOKEN|SECRET|PASSWORD|PRIVATE_KEY)\s*=\s*['"]?[A-Za-z0-9_./+=:-]{12,}/g, label: "secret-looking assignment" }
];
const allowedContentPaths = new Set([
  "apps/desktop/README.md",
  "docs/USAGES.md"
]);

const failures = [];
const checkedFiles = [];

function toRelative(absolutePath) {
  return path.relative(repoRoot, absolutePath).split(path.sep).join("/");
}

async function walk(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries) {
    if (ignoredDirs.has(entry.name)) {
      continue;
    }
    const absolutePath = path.join(directory, entry.name);
    const relativePath = toRelative(absolutePath);
    if (forbiddenPathParts.some((part) => relativePath === part || relativePath.startsWith(`${part}/`))) {
      failures.push(`generated path must not be tracked: ${relativePath}`);
      continue;
    }
    if (entry.isDirectory()) {
      await walk(absolutePath);
      continue;
    }
    if (!entry.isFile()) {
      continue;
    }
    const extension = path.extname(entry.name);
    if (!textExtensions.has(extension) && entry.name !== "LICENSE" && entry.name !== ".gitignore") {
      continue;
    }
    const info = await stat(absolutePath);
    if (info.size > 1024 * 1024) {
      continue;
    }
    checkedFiles.push(relativePath);
    const source = await readFile(absolutePath, "utf8");
    for (const { pattern, label } of forbiddenContent) {
      if (allowedContentPaths.has(relativePath)) {
        continue;
      }
      pattern.lastIndex = 0;
      const match = pattern.exec(source);
      if (match) {
        failures.push(`${relativePath}: ${label} (${match[0].slice(0, 80)})`);
      }
    }
  }
}

await walk(repoRoot);

const packageJson = JSON.parse(await readFile(path.join(repoRoot, "package.json"), "utf8"));
if (packageJson.private !== true) {
  failures.push("package.json must keep private=true");
}
if (packageJson.license !== "UNLICENSED") {
  failures.push("package.json must keep license=UNLICENSED");
}

const cargoToml = await readFile(path.join(repoRoot, "crates/lico-client-native/Cargo.toml"), "utf8");
if (!cargoToml.includes("publish = false")) {
  failures.push("crates/lico-client-native/Cargo.toml must keep publish=false");
}
if (!cargoToml.includes("license-file = \"../../LICENSE\"")) {
  failures.push("crates/lico-client-native/Cargo.toml must use the repository proprietary license file");
}

const report = {
  ok: failures.length === 0,
  checkedFiles: checkedFiles.length,
  failures
};
const reportPath = path.join(repoRoot, "build", "reports", "client-boundary.json");
await mkdir(path.dirname(reportPath), { recursive: true });
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);

if (failures.length > 0) {
  console.error(JSON.stringify(report, null, 2));
  process.exit(1);
}

console.log(JSON.stringify(report, null, 2));
