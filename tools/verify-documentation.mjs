#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const failures = [];

const requiredFiles = [
  "README.md",
  "README.zh-CN.md",
  "PRODUCT.md",
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
  ["README.md", "README.zh-CN.md"],
  ["CONTRIBUTING.md", "CONTRIBUTING.zh-CN.md"],
  ["SECURITY.md", "SECURITY.zh-CN.md"],
  ["docs/functionality/USER-GUIDE.md", "docs/functionality/USER-GUIDE.zh-CN.md"],
  ["docs/architecture/README.md", "docs/architecture/README.zh-CN.md"],
  ["docs/protocols/local-bridge.md", "docs/protocols/local-bridge.zh-CN.md"],
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
    execFileSync("git", ["check-ignore", "-q", root], {
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

for (const relativePath of [...candidate].filter((entry) => /\.mdx?$/u.test(entry))) {
  const absolutePath = path.join(repoRoot, relativePath);
  if (!existsSync(absolutePath) || !statSync(absolutePath).isFile()) continue;
  const source = readFileSync(absolutePath, "utf8");
  for (const rawTarget of markdownLinks(source)) {
    const target = localTarget(relativePath, rawTarget);
    if (target !== null && !relativeFileExists(target)) {
      failures.push(`${relativePath}: missing link target ${target}`);
    }
  }
}

const docsIndex = readFileSync(path.join(repoRoot, "docs/README.md"), "utf8");
for (const relativePath of [...candidate].filter(
  (entry) =>
    entry.startsWith("docs/") &&
    /\.md$/u.test(entry) &&
    entry !== "docs/README.md",
)) {
  const fromIndex = path.relative("docs", relativePath).split(path.sep).join("/");
  if (!docsIndex.includes(`(${fromIndex})`)) {
    failures.push(`${relativePath}: absent from docs/README.md`);
  }
}

for (const generatedPath of ["docs/COMPATIBILITY.md", "docs/COMPATIBILITY.zh-CN.md"]) {
  const source = readFileSync(path.join(repoRoot, generatedPath), "utf8");
  for (const token of [
    "tools/client-support-matrix.json",
    "crates/lico-client-native/resources/agent-conversation-drivers.json",
    "crates/lico-client-native/resources/agent-conversation-readiness.json",
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
