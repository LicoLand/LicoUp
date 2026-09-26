#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { documentDate, markdownAnchors, validateModuleRoutes } from "./development/documentation.mjs";
import { CLIENT_MODULE_CATALOG } from "./regression/client-module-catalog.mjs";
import { inspectCandidate } from "./development/artifacts.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const failures = [];
for (const finding of inspectCandidate(repoRoot).findings) {
  failures.push(`${finding.file}: ${finding.reason} (${finding.snapshot})`);
}

const requiredFiles = [
  "PRODUCT.md",
  "PRODUCT.zh-CN.md",
  "CONTRIBUTING.md",
  "CODE_OF_CONDUCT.md",
  "CHANGELOG.md",
  "LICENSE",
  "SECURITY.md",
  "docs/README.md",
  "docs/RUNBOOK.md",
  "docs/COMPATIBILITY.md",
  "docs/ENTITY-CONFIG-LAYOUT.md",
  "docs/architecture/README.md",
  "docs/functionality/README.md",
  "docs/protocols/README.md",
  "docs/examples/README.md",
  "docs/adrs/README.md",
];

const localRoots = ["docs/plans", "docs/reports", "cache", "build"];
const languagePairs = [
  ["PRODUCT.md", "PRODUCT.zh-CN.md"],
  ["CONTRIBUTING.md", "CONTRIBUTING.zh-CN.md"],
  ["SECURITY.md", "SECURITY.zh-CN.md"],
  ["docs/functionality/USER-GUIDE.md", "docs/functionality/USER-GUIDE.zh-CN.md"],
  ["docs/architecture/README.md", "docs/architecture/README.zh-CN.md"],
  [
    "docs/protocols/licoarc-station-adapter.md",
    "docs/protocols/licoarc-station-adapter.zh-CN.md",
  ],
  ["docs/COMPATIBILITY.md", "docs/COMPATIBILITY.zh-CN.md"],
];

function gitLines(args) {
  return execFileSync("git", args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  })
    .split(/\r?\n/u)
    .filter(Boolean);
}

function relativeFileExists(relativePath) {
  const absolutePath = path.resolve(repoRoot, relativePath);
  return absolutePath === repoRoot || absolutePath.startsWith(`${repoRoot}${path.sep}`)
    ? existsSync(absolutePath)
    : false;
}

function candidateFiles() {
  return new Set(
    gitLines([
      "ls-files",
      "--cached",
      "--others",
      "--exclude-standard",
      "--",
      "*.md",
      "*.mdx",
      "LICENSE",
    ]).filter(relativeFileExists),
  );
}

function markdownLinks(source) {
  return [...source.matchAll(/!?\[[^\]]*\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/gu)]
    .map((match) => match[1]);
}

function localTarget(sourcePath, rawTarget) {
  const withoutAngles =
    rawTarget.startsWith("<") && rawTarget.endsWith(">")
      ? rawTarget.slice(1, -1)
      : rawTarget;
  const target = withoutAngles.split("#", 1)[0];
  if (
    target.length === 0 ||
    target.startsWith("/") ||
    /^[a-z][a-z0-9+.-]*:/iu.test(target)
  ) {
    return null;
  }
  let decoded;
  try {
    decoded = decodeURIComponent(target);
  } catch {
    failures.push(`${sourcePath}: invalid percent-encoding in link`);
    return null;
  }
  const resolved = path.resolve(repoRoot, path.dirname(sourcePath), decoded);
  if (resolved !== repoRoot && !resolved.startsWith(`${repoRoot}${path.sep}`)) {
    failures.push(`${sourcePath}: link escapes repository`);
    return null;
  }
  return path.relative(repoRoot, resolved).split(path.sep).join("/");
}

const candidate = candidateFiles();

for (const relativePath of candidate) {
  if (!/\.mdx?$/u.test(relativePath)) continue;
  const issue = documentDate(readFileSync(path.join(repoRoot, relativePath), "utf8"));
  if (issue) failures.push(`${relativePath}: ${issue}`);
}
const modules = JSON.parse(readFileSync(path.join(repoRoot, "tools/development/modules.json"), "utf8"));
const scripts = JSON.parse(readFileSync(path.join(repoRoot, "package.json"), "utf8")).scripts;
const closureSteps = JSON.parse(readFileSync(path.join(repoRoot, "tools/development/closure-steps.json"), "utf8"));
for (const step of closureSteps) {
  if (!scripts[step.command]) failures.push(`closure ${step.id}: command is missing`);
}
for (const file of candidate) {
  if (file.startsWith("docs/modules/") && /\.md$/u.test(file) && !modules.some((module) => module.guide === file)) {
    failures.push(`${file}: module guide is not registered`);
  }
}
failures.push(...validateModuleRoutes(modules, {
  exists: relativeFileExists,
  read: (file) => readFileSync(path.join(repoRoot, file), "utf8"),
  scripts,
  regressionIds: new Set(CLIENT_MODULE_CATALOG.map((entry) => entry.id)),
}));
const entry = readFileSync(path.join(repoRoot, "docs/RUNBOOK.md"), "utf8");
for (const module of modules) {
  if (!entry.includes(path.relative("docs", module.guide))) failures.push(`${module.id}: absent from developer entry`);
}

for (const required of requiredFiles) {
  if (!relativeFileExists(required)) failures.push(`${required}: required file is missing`);
  if (!candidate.has(required)) failures.push(`${required}: absent from public Git candidate`);
  try {
    execFileSync("git", ["check-ignore", "--no-index", "-q", required], {
      cwd: repoRoot,
      stdio: "ignore",
    });
    failures.push(`${required}: required public file is ignored`);
  } catch {
    // A nonzero result means no ignore rule claims the required public file.
  }
}

for (const root of localRoots) {
  try {
    execFileSync("git", ["check-ignore", "-q", `${root}/`], {
      cwd: repoRoot,
      stdio: "ignore",
    });
  } catch {
    failures.push(`${root}: local root is not ignored`);
  }
  const tracked = gitLines(["ls-files", "--", root]);
  if (tracked.length > 0) failures.push(`${root}: local root contains tracked files`);
  for (const candidatePath of candidate) {
    if (candidatePath === root || candidatePath.startsWith(`${root}/`)) {
      failures.push(`${root}: local root entered public Git candidate`);
      break;
    }
  }
}

for (const [englishPath, localizedPath] of languagePairs) {
  if (!relativeFileExists(englishPath) || !relativeFileExists(localizedPath)) {
    failures.push(`${englishPath}: bilingual pair is incomplete`);
    continue;
  }
  const english = readFileSync(path.join(repoRoot, englishPath), "utf8");
  const localized = readFileSync(path.join(repoRoot, localizedPath), "utf8");
  if (!english.includes(path.basename(localizedPath))) {
    failures.push(`${englishPath}: missing localized-language link`);
  }
  if (!localized.includes(path.basename(englishPath))) {
    failures.push(`${localizedPath}: missing normative-language link`);
  }
}

for (const relativePath of [...candidate].filter(
  (entry) => /\.mdx?$/u.test(entry) && entry !== "README.md" && entry !== "README.zh-CN.md",
)) {
  const absolutePath = path.join(repoRoot, relativePath);
  if (!existsSync(absolutePath) || !statSync(absolutePath).isFile()) continue;
  const source = readFileSync(absolutePath, "utf8");
  for (const rawTarget of markdownLinks(source)) {
    const target = localTarget(relativePath, rawTarget);
    if (target !== null && !relativeFileExists(target)) {
      failures.push(`${relativePath}: missing link target ${target}`);
    }
    if (target !== null && localRoots.some((root) => target === root || target.startsWith(`${root}/`))) {
      failures.push(`${relativePath}: public link targets local-only material`);
    }
    const anchor = rawTarget.split("#")[1];
    const anchorFile = rawTarget.startsWith("#") ? relativePath : target;
    if (anchor && anchorFile && /\.mdx?$/u.test(anchorFile) && relativeFileExists(anchorFile)) {
      let decoded;
      try { decoded = decodeURIComponent(anchor); } catch { failures.push(`${relativePath}: invalid anchor encoding`); continue; }
      const headings = markdownAnchors(readFileSync(path.join(repoRoot, anchorFile), "utf8"));
      if (!headings.has(decoded)) failures.push(`${relativePath}: missing anchor ${anchorFile}#${decoded}`);
    }
  }
}

for (const generatedPath of ["docs/COMPATIBILITY.md", "docs/COMPATIBILITY.zh-CN.md"]) {
  const source = readFileSync(path.join(repoRoot, generatedPath), "utf8");
  for (const token of [
    "tools/client-support-matrix.json",
    "crates/licoup-native/resources/agent-conversation-drivers.json",
    "crates/licoup-native/resources/agent-native-capabilities.json",
    "crates/licoup-native/resources/agent-conversation-readiness.json",
    "client:support-matrix:sync",
    "client:support-matrix:check",
  ]) {
    if (!source.includes(token)) failures.push(`${generatedPath}: missing generated-source token`);
  }
}

if (failures.length > 0) {
  for (const failure of [...new Set(failures)].sort()) {
    process.stderr.write(`documentation_invalid: ${failure}\n`);
  }
  process.exitCode = 1;
} else {
  process.stdout.write(
    `${JSON.stringify({
      ok: true,
      publicCandidateCount: candidate.size,
      bilingualPairCount: languagePairs.length,
      localRootCount: localRoots.length,
    })}\n`,
  );
}
