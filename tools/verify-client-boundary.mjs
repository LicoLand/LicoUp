#!/usr/bin/env node
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, readdir, readFile, stat, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { loadSecureMeshClientBoundaryConfig } from "./scripts/lib/secure-mesh-client-boundary-config.mjs";
import { readSourceCheckBundle } from "./scripts/lib/source-check-bundle.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const execFileAsync = promisify(execFile);
const ignoredDirs = new Set([
  ".git",
  "node_modules",
  "build",
  "target",
  ".dart_tool",
  ".gradle",
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
  ".kt",
  ".swift",
  ".h",
  ".cc",
  ".cpp",
  ".c",
  ".cmake",
  ".txt"
]);
const serverScriptsPath = "tools/" + "server" + "-scripts";
const retiredClientNamePattern = new RegExp(
  "\\b" + "future" + "(?:[_ -]?" + "client" + ")\\b",
  "gi",
);
const forbiddenPathParts = [
  ".agents",
  ".claude",
  ".codex",
  ".local",
  "build",
  "apps/build",
  "apps/desktop/.dart_tool",
  "apps/desktop/build",
  "apps/desktop/android/.gradle",
  "apps/desktop/android/build",
  "apps/desktop/ios/build",
  "apps/desktop/linux/flutter/ephemeral",
  "apps/desktop/macos/Flutter/ephemeral",
  "apps/desktop/macos/Pods",
  "apps/desktop/windows/flutter/ephemeral",
  "crates/lico-client-native/target",
  "docs/plan",
  "scripts/local",
  "skills",
  "tools/local",
  serverScriptsPath
];
const forbiddenContent = [
  { pattern: retiredClientNamePattern, reasonCode: "RETIRED_CLIENT_NAME" },
  { pattern: /\/Users\/[A-Za-z0-9._-]+/g, reasonCode: "FORBIDDEN_MACOS_HOME_PATH" },
  { pattern: /\/home\/[A-Za-z0-9._-]+/g, reasonCode: "FORBIDDEN_LINUX_HOME_PATH" },
  { pattern: /C:\\Users\\[A-Za-z0-9._ -]+/g, reasonCode: "FORBIDDEN_WINDOWS_HOME_PATH" },
  { pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----/g, reasonCode: "FORBIDDEN_PRIVATE_KEY" },
  {
    pattern: new RegExp(serverScriptsPath.replace("/", "\\/"), "g"),
    reasonCode: "FORBIDDEN_SERVER_SCRIPT_PATH"
  },
  { pattern: /\bserver:[A-Za-z0-9_-][A-Za-z0-9:_-]*/g, reasonCode: "FORBIDDEN_SERVER_NPM_SCRIPT" },
  {
    pattern: /\b(?:TOKEN|SECRET|PASSWORD|PRIVATE_KEY)\s*=\s*['"]?[A-Za-z0-9_./+=:-]{12,}/g,
    reasonCode: "FORBIDDEN_SECRET_ASSIGNMENT"
  }
];
const forbiddenPublicDocumentContent = [
  {
    pattern: /\b(?:commercial(?:ization)?|monetization|pricing|revenue|profit)\b/giu,
    reasonCode: "PUBLIC_DOCUMENT_PRODUCT_LANGUAGE_FORBIDDEN"
  },
  {
    pattern: /(?:商业化?|盈利|营收)/gu,
    reasonCode: "PUBLIC_DOCUMENT_PRODUCT_LANGUAGE_FORBIDDEN"
  }
];
const allowedContentPaths = new Set();
const retiredStatePolicyChecks = [
  {
    path: "AGENTS.md",
    token: "Persistent user state owned by a retired product name is reset, not migrated."
  }
];
const flutterSrcRoot = "apps/desktop/lib/src";
const requiredFlutterPhysicalDirs = ["application", "frontend", "backend", "platform", "contracts"];
const allowedFlutterTopLevelDirs = new Set([
  ...requiredFlutterPhysicalDirs
]);
const requiredFrontendFeatureDirs = [
  "agents",
  "mobile_relay",
  "skill_hub",
  "settings",
  "targets"
];
const requiredBackendFeatureDirs = [
  "agents",
  "mobile_relay"
];
const flutterLayerImportRules = [
  {
    root: `${flutterSrcRoot}/frontend`,
    forbiddenTokens: [
      "package:flutter_client/src/backend/",
      "package:flutter_client/src/platform/"
    ],
    message: "frontend must depend on application/contracts/l10n, not backend or platform implementations"
  },
  {
    root: `${flutterSrcRoot}/backend`,
    forbiddenTokens: [
      "package:flutter_client/src/frontend/",
      "package:flutter_client/src/platform/"
    ],
    message: "backend must not import frontend UI or platform implementation code"
  },
  {
    root: `${flutterSrcRoot}/platform`,
    forbiddenTokens: [
      "package:flutter_client/src/frontend/",
      "package:flutter_client/src/backend/"
    ],
    message: "platform bridge code must not import frontend UI or backend implementation code"
  },
  {
    root: `${flutterSrcRoot}/contracts`,
    forbiddenTokens: [
      "package:flutter_client/src/frontend/",
      "package:flutter_client/src/backend/",
      "package:flutter_client/src/platform/"
    ],
    message: "contracts must not import implementation layers"
  }
];

const failures = [];
const checkedFiles = [];
let clientBoundarySummary = null;
let dartSourceFilesCache = null;

function toRelative(absolutePath) {
  return path.relative(repoRoot, absolutePath).split(path.sep).join("/");
}

function safeFailurePath(candidate) {
  if (typeof candidate !== "string" || candidate.length === 0) {
    return "unknown";
  }
  let relativePath = candidate.split(path.sep).join("/");
  if (path.isAbsolute(candidate)) {
    relativePath = toRelative(candidate);
  }
  if (
    relativePath.startsWith("/") ||
    /^[A-Za-z]:/u.test(relativePath) ||
    relativePath === ".." ||
    relativePath.startsWith("../") ||
    relativePath.includes("\0")
  ) {
    return "unknown";
  }
  const normalized = path.posix.normalize(relativePath);
  return normalized === "." || normalized.startsWith("../") ? "unknown" : normalized;
}

function addFailure(reasonCode, relativePath, privateDetail = "") {
  const safePath = safeFailurePath(relativePath);
  const digest = createHash("sha256")
    .update(`${reasonCode}\0${safePath}\0${String(privateDetail)}`, "utf8")
    .digest("hex");
  failures.push({
    reasonCode,
    path: safePath,
    digest
  });
}

async function scanPublicFiles() {
  let output;
  try {
    ({ stdout: output } = await execFileAsync(
      "git",
      ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
      { cwd: repoRoot, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 },
    ));
  } catch (error) {
    addFailure("PUBLIC_FILE_LIST_FAILED", ".", error?.message);
    return;
  }

  const candidates = [...new Set(output.split("\0").filter(Boolean))].sort();
  const candidateSet = new Set(candidates);
  for (const relativePath of candidates) {
    if (!relativePath.endsWith(".md") || path.basename(relativePath) === "AGENTS.md") {
      continue;
    }
    const translationPath = relativePath.endsWith(".zh-CN.md")
      ? relativePath.replace(/\.zh-CN\.md$/u, ".md")
      : relativePath.replace(/\.md$/u, ".zh-CN.md");
    if (!candidateSet.has(translationPath)) {
      addFailure("PUBLIC_DOCUMENT_TRANSLATION_MISSING", relativePath, translationPath);
    }
  }
  for (const relativePath of candidates) {
    const normalized = relativePath.split(path.sep).join("/");
    if (normalized !== relativePath || path.posix.normalize(normalized) !== normalized) {
      addFailure("PUBLIC_PATH_INVALID", relativePath, relativePath);
      continue;
    }
    const entryName = path.basename(relativePath);
    retiredClientNamePattern.lastIndex = 0;
    if (retiredClientNamePattern.test(entryName)) {
      addFailure("RETIRED_CLIENT_PATH", relativePath, entryName);
      continue;
    }
    if (forbiddenPathParts.some((part) => relativePath === part || relativePath.startsWith(`${part}/`))) {
      addFailure("GENERATED_PATH_PRESENT", relativePath, relativePath);
      continue;
    }
    const absolutePath = path.join(repoRoot, relativePath);
    let info;
    try {
      info = await lstat(absolutePath);
    } catch (error) {
      addFailure("PUBLIC_FILE_UNREADABLE", relativePath, error?.message);
      continue;
    }
    if (info.isSymbolicLink()) {
      addFailure("PUBLIC_SYMLINK_FORBIDDEN", relativePath, relativePath);
      continue;
    }
    if (!info.isFile() || info.size > 1024 * 1024) {
      continue;
    }
    const extension = path.extname(entryName);
    if (!textExtensions.has(extension) && entryName !== "LICENSE" && entryName !== ".gitignore") {
      continue;
    }
    checkedFiles.push(relativePath);
    const source = await readFile(absolutePath, "utf8");
    for (const { pattern, reasonCode } of forbiddenContent) {
      if (allowedContentPaths.has(relativePath)) {
        continue;
      }
      pattern.lastIndex = 0;
      const match = pattern.exec(source);
      if (match) {
        addFailure(reasonCode, relativePath, match[0]);
      }
    }
    if (extension === ".md" && entryName !== "AGENTS.md") {
      for (const { pattern, reasonCode } of forbiddenPublicDocumentContent) {
        pattern.lastIndex = 0;
        const match = pattern.exec(source);
        if (match) {
          addFailure(reasonCode, relativePath, match[0]);
        }
      }
    }
  }
}

async function collectBoundaryFiles(relativeRoot, includeExtensions) {
  const absoluteRoot = path.join(repoRoot, relativeRoot);
  const extensionSet = new Set(includeExtensions);
  const files = [];

  async function walkBoundaryDirectory(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      if (ignoredDirs.has(entry.name)) {
        continue;
      }
      const absolutePath = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        await walkBoundaryDirectory(absolutePath);
        continue;
      }
      if (!entry.isFile() || !extensionSet.has(path.extname(entry.name))) {
        continue;
      }
      files.push(toRelative(absolutePath));
    }
  }

  await walkBoundaryDirectory(absoluteRoot);
  return files.sort();
}

async function readImmediateDirectoryNames(relativeRoot) {
  try {
    const entries = await readdir(path.join(repoRoot, relativeRoot), { withFileTypes: true });
    return entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort();
  } catch (error) {
    addFailure("DIRECTORY_UNREADABLE", relativeRoot, error?.message);
    return [];
  }
}

async function collectDartSourceFiles() {
  if (!dartSourceFilesCache) {
    try {
      dartSourceFilesCache = await collectBoundaryFiles(flutterSrcRoot, [".dart"]);
    } catch (error) {
      addFailure("FLUTTER_SOURCE_SCAN_FAILED", flutterSrcRoot, error?.message);
      dartSourceFilesCache = [];
    }
  }
  return dartSourceFilesCache;
}

function isFlutterSourcePath(relativePath) {
  return relativePath.startsWith(`${flutterSrcRoot}/`) && relativePath.endsWith(".dart");
}

async function resolveFlutterSourcePath(relativePath) {
  if (!isFlutterSourcePath(relativePath)) {
    return relativePath;
  }
  try {
    await stat(path.join(repoRoot, relativePath));
    return relativePath;
  } catch {
    const basename = path.basename(relativePath);
    const matches = (await collectDartSourceFiles())
      .filter((candidate) => path.basename(candidate) === basename);
    if (matches.length === 1) {
      return matches[0];
    }
    addFailure(
      "FLUTTER_SOURCE_RESOLUTION_AMBIGUOUS",
      relativePath,
      `${matches.length}\0${matches.join("\0")}`
    );
    return relativePath;
  }
}

function lineNumberForToken(source, token) {
  const lines = source.split(/\r?\n/);
  const index = lines.findIndex((line) => line.includes(token));
  return index >= 0 ? index + 1 : 1;
}

async function enforceFlutterLayerIsolation() {
  for (const rule of flutterLayerImportRules) {
    let files;
    try {
      files = await collectBoundaryFiles(rule.root, [".dart"]);
    } catch (error) {
      addFailure("FLUTTER_LAYER_ROOT_UNREADABLE", rule.root, error?.message);
      continue;
    }
    for (const relativePath of files) {
      const source = await readFile(path.join(repoRoot, relativePath), "utf8");
      for (const token of rule.forbiddenTokens) {
        if (source.includes(token)) {
          addFailure(
            "FLUTTER_LAYER_IMPORT_FORBIDDEN",
            relativePath,
            `${lineNumberForToken(source, token)}\0${rule.message}\0${token}`
          );
        }
      }
    }
  }
}

function ruleAllowsToken(rule, relativePath, token) {
  return rule.allowedMatches.some((match) =>
    (match.file === relativePath ||
      (isFlutterSourcePath(match.file) &&
        isFlutterSourcePath(relativePath) &&
        path.basename(match.file) === path.basename(relativePath))) &&
    match.tokens.includes(token)
  );
}

async function enforceFlutterFeatureFirstLayout() {
  const topLevelDirs = await readImmediateDirectoryNames(flutterSrcRoot);
  for (const requiredDir of requiredFlutterPhysicalDirs) {
    if (!topLevelDirs.includes(requiredDir)) {
      addFailure("FLUTTER_REQUIRED_LAYER_MISSING", `${flutterSrcRoot}/${requiredDir}`, requiredDir);
    }
  }
  for (const topLevelDir of topLevelDirs) {
    if (!allowedFlutterTopLevelDirs.has(topLevelDir)) {
      addFailure("FLUTTER_TOP_LEVEL_LAYER_FORBIDDEN", `${flutterSrcRoot}/${topLevelDir}`, topLevelDir);
    }
  }
  const frontendFeatureDirs = await readImmediateDirectoryNames(`${flutterSrcRoot}/frontend/features`);
  for (const featureDir of requiredFrontendFeatureDirs) {
    if (!frontendFeatureDirs.includes(featureDir)) {
      addFailure(
        "FLUTTER_FRONTEND_FEATURE_MISSING",
        `${flutterSrcRoot}/frontend/features/${featureDir}`,
        featureDir
      );
    }
  }
  const backendFeatureDirs = await readImmediateDirectoryNames(`${flutterSrcRoot}/backend/features`);
  for (const featureDir of requiredBackendFeatureDirs) {
    if (!backendFeatureDirs.includes(featureDir)) {
      addFailure(
        "FLUTTER_BACKEND_FEATURE_MISSING",
        `${flutterSrcRoot}/backend/features/${featureDir}`,
        featureDir
      );
    }
  }
  await enforceFlutterLayerIsolation();
}

async function enforceConfiguredClientBoundary(config) {
  const ruleSummaries = [];
  for (const rule of config.rules) {
    const seenFiles = new Set();
    let allowedMatchCount = 0;
    let violationCount = 0;
    for (const root of rule.roots) {
      let files;
      try {
        files = await collectBoundaryFiles(root, rule.includeExtensions);
      } catch (error) {
        addFailure("CLIENT_BOUNDARY_ROOT_SCAN_FAILED", root, `${rule.id}\0${error?.message}`);
        violationCount += 1;
        continue;
      }
      for (const relativePath of files) {
        if (seenFiles.has(relativePath)) {
          continue;
        }
        seenFiles.add(relativePath);
        const source = await readFile(path.join(repoRoot, relativePath), "utf8");
        for (const token of rule.forbiddenTokens) {
          if (!source.includes(token)) {
            continue;
          }
          if (ruleAllowsToken(rule, relativePath, token)) {
            allowedMatchCount += 1;
            continue;
          }
          violationCount += 1;
          addFailure(
            "CLIENT_BOUNDARY_TOKEN_FORBIDDEN",
            relativePath,
            `${rule.id}\0${lineNumberForToken(source, token)}\0${token}`
          );
        }
      }
    }
    ruleSummaries.push({
      id: rule.id,
      roots: rule.roots,
      includeExtensions: rule.includeExtensions,
      forbiddenTokenCount: rule.forbiddenTokens.length,
      filesScanned: seenFiles.size,
      allowedMatchCount,
      violationCount
    });
  }

  const sourceChecks = [];
  for (const check of config.sourceChecks) {
    let missingTokens = [];
    let forbiddenTokensPresent = [];
    let resolvedFiles = [await resolveFlutterSourcePath(check.file)];
    try {
      const { files, source } = await readSourceCheckBundle(check, async (sourceRef) => {
        const sourcePath = await resolveFlutterSourcePath(sourceRef);
        return readFile(path.join(repoRoot, sourcePath), "utf8");
      });
      missingTokens = check.tokens.filter((token) => !source.includes(token));
      forbiddenTokensPresent = (check.forbiddenTokens || []).filter((token) =>
        source.includes(token)
      );
      resolvedFiles = await Promise.all(files.map(resolveFlutterSourcePath));
    } catch (error) {
      missingTokens = ["<read-failed>"];
      addFailure("CLIENT_BOUNDARY_SOURCE_READ_FAILED", check.file, `${check.id}\0${error?.message}`);
    }
    if (missingTokens.length > 0) {
      addFailure(
        "CLIENT_BOUNDARY_SOURCE_TOKEN_MISSING",
        check.file,
        `${check.id}\0${missingTokens.join("\0")}`
      );
    }
    if (forbiddenTokensPresent.length > 0) {
      addFailure(
        "CLIENT_BOUNDARY_SOURCE_TOKEN_FORBIDDEN",
        check.file,
        `${check.id}\0${forbiddenTokensPresent.join("\0")}`
      );
    }
    sourceChecks.push({
      id: check.id,
      file: await resolveFlutterSourcePath(check.file),
      files: resolvedFiles,
      tokenCount: check.tokens.length,
      forbiddenTokenCount: (check.forbiddenTokens || []).length,
      ok: missingTokens.length === 0 && forbiddenTokensPresent.length === 0
    });
  }

  return {
    configRef: config.configRef,
    schemaVersion: config.schemaVersion,
    ruleCount: config.rules.length,
    sourceCheckCount: config.sourceChecks.length,
    rules: ruleSummaries,
    sourceChecks
  };
}

await scanPublicFiles();
await enforceFlutterFeatureFirstLayout();
clientBoundarySummary = await enforceConfiguredClientBoundary(await loadSecureMeshClientBoundaryConfig());

async function trackedFiles() {
  try {
    const { stdout } = await execFileAsync("git", ["ls-files"], {
      cwd: repoRoot,
      maxBuffer: 10 * 1024 * 1024
    });
    return stdout.split(/\r?\n/).filter(Boolean);
  } catch (error) {
    addFailure("GIT_TRACKED_FILE_QUERY_FAILED", ".git", error?.message);
    return [];
  }
}

for (const relativePath of await trackedFiles()) {
  if (forbiddenPathParts.some((part) => relativePath === part || relativePath.startsWith(`${part}/`))) {
    addFailure("GENERATED_PATH_TRACKED", relativePath, relativePath);
  }
}

const packageJson = JSON.parse(await readFile(path.join(repoRoot, "package.json"), "utf8"));
if (packageJson.private !== false) {
  addFailure("PACKAGE_OPEN_SOURCE_FLAG_INVALID", "package.json", String(packageJson.private));
}
if (packageJson.license !== "GPL-3.0-or-later") {
  addFailure("PACKAGE_LICENSE_INVALID", "package.json", String(packageJson.license));
}
const licenseText = await readFile(path.join(repoRoot, "LICENSE"), "utf8");
if (!licenseText.includes("GNU GENERAL PUBLIC LICENSE") ||
  !licenseText.includes("Version 3, 29 June 2007") ||
  !licenseText.includes("either version 3 of the License, or") ||
  !licenseText.includes("(at your option) any later version")) {
  addFailure("OPEN_SOURCE_LICENSE_TEXT_INVALID", "LICENSE", "GPL-3.0-or-later text missing");
}

const cargoToml = await readFile(path.join(repoRoot, "crates/lico-client-native/Cargo.toml"), "utf8");
if (!cargoToml.includes("publish = false")) {
  addFailure("CARGO_PUBLISH_FLAG_INVALID", "crates/lico-client-native/Cargo.toml", cargoToml);
}
if (!cargoToml.includes("license.workspace = true")) {
  addFailure("CARGO_LICENSE_METADATA_INVALID", "crates/lico-client-native/Cargo.toml", cargoToml);
}
const workspaceCargoToml = await readFile(path.join(repoRoot, "Cargo.toml"), "utf8");
if (!workspaceCargoToml.includes('license = "GPL-3.0-or-later"')) {
  addFailure("CARGO_WORKSPACE_LICENSE_INVALID", "Cargo.toml", workspaceCargoToml);
}

for (const check of retiredStatePolicyChecks) {
  const source = await readFile(path.join(repoRoot, check.path), "utf8");
  if (!source.includes(check.token)) {
    addFailure("RETIRED_STATE_RESET_POLICY_MISSING", check.path, check.token);
  }
}

const report = {
  ok: failures.length === 0,
  checkedFiles: checkedFiles.length,
  retiredNameState: {
    strategy: "direct-reset",
    migrationSupported: false,
    policyChecks: retiredStatePolicyChecks.length
  },
  clientBoundary: clientBoundarySummary,
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
