#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const workspaceRoot = path.resolve(process.env.LICO_WORKSPACE_ROOT || path.dirname(repoRoot));
const reportPath = path.join(repoRoot, "build", "reports", "workspace-cache-boundary.json");

const forbiddenAnySegment = new Set([
  "build",
  "target",
  "node_modules",
  ".dart_tool",
  ".gradle",
  ".pub-cache",
  ".pub",
  "Pods",
  "DerivedData",
  ".swiftpm",
  ".build",
  "coverage",
  "dist",
  "out",
  "__pycache__",
  ".pytest_cache",
  ".mypy_cache",
  ".ruff_cache",
  ".next",
  ".nuxt",
  ".turbo",
  ".parcel-cache",
  ".svelte-kit",
  ".playwright-cli",
  "test-results"
]);

const forbiddenTopLevel = new Set([
  ".cache",
  ".lico-agent-history",
  ".lico-server-data",
  "checkpoints",
  "data",
  "exports",
  "logs",
  "outputs",
  "portable-data",
  "reports",
  "runtime",
  "storage",
  "temp",
  "tmp"
]);

const forbiddenDataFiles = new Set([
  "checkpoints.json",
  "client.log",
  "recent-runs.json",
  "settings.json"
]);

const versionControlledSourceDirectories = new Set([
  "apps/desktop/scripts/package-client/build"
]);

function runGit(repo, args) {
  const result = spawnSync("git", args, {
    cwd: repo,
    encoding: "utf8",
    shell: false
  });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(" ")} failed in ${labelFor(repo)}: ${result.stderr.trim()}`);
  }
  return result.stdout.split(/\r?\n/).filter(Boolean);
}

function labelFor(repo) {
  const label = path.relative(workspaceRoot, repo) || ".";
  return label.split(path.sep).join("/");
}

function findGitRoots() {
  const roots = [];
  if (existsSync(path.join(workspaceRoot, ".git"))) {
    roots.push(workspaceRoot);
  }
  for (const entry of readdirSync(workspaceRoot, { withFileTypes: true })) {
    if (!entry.isDirectory()) {
      continue;
    }
    const candidate = path.join(workspaceRoot, entry.name);
    if (existsSync(path.join(candidate, ".git"))) {
      roots.push(candidate);
    }
  }
  return [...new Set(roots)].sort((a, b) => labelFor(a).localeCompare(labelFor(b)));
}

function classifyForbiddenPath(relativePath) {
  const segments = relativePath.split(/[\\/]+/).filter(Boolean);
  for (const [index, segment] of segments.entries()) {
    if (forbiddenAnySegment.has(segment)) {
      const directory = segments.slice(0, index + 1).join("/");
      if (segment === "build" && versionControlledSourceDirectories.has(directory)) {
        continue;
      }
      return { kind: "generated-or-cache-directory", pattern: segment };
    }
  }
  if (segments.length > 0 && forbiddenTopLevel.has(segments[0])) {
    return { kind: "runtime-data-directory", pattern: segments[0] };
  }
  if (segments.length > 1 && forbiddenDataFiles.has(segments[segments.length - 1])) {
    const parent = segments[segments.length - 2];
    if (forbiddenTopLevel.has(parent) || parent === "logs") {
      return { kind: "runtime-data-file", pattern: segments.slice(-2).join("/") };
    }
  }
  return null;
}

function runSelfTest() {
  const allowedSourceFiles = [
    "apps/desktop/scripts/package-client/build/flutter.mjs",
    "apps/desktop/scripts/package-client/build/native.mjs",
    "apps/desktop/scripts/package-client/build/swift.mjs"
  ];
  for (const sourceFile of allowedSourceFiles) {
    if (classifyForbiddenPath(sourceFile) !== null) {
      throw new Error("version-controlled source directory was rejected");
    }
  }

  const rejectedBuildPaths = [
    "build/output.json",
    "apps/desktop/build/output.json",
    "tools/scripts/build/output.mjs",
    "apps/desktop/scripts/package-client/other/build/output.mjs"
  ];
  for (const buildPath of rejectedBuildPaths) {
    const finding = classifyForbiddenPath(buildPath);
    if (
      finding?.kind !== "generated-or-cache-directory" ||
      finding.pattern !== "build"
    ) {
      throw new Error("unapproved build directory was accepted");
    }
  }

  return {
    allowedSourceFiles: allowedSourceFiles.length,
    rejectedBuildPaths: rejectedBuildPaths.length
  };
}

function scanGitignore(repo) {
  const gitignore = path.join(repo, ".gitignore");
  if (!existsSync(gitignore)) {
    return [];
  }
  const findings = [];
  const source = readFileSync(gitignore, "utf8");
  source.split(/\r?\n/).forEach((line, index) => {
    if (/^!\s*\/?build(?:\/|\*|$)/.test(line.trim())) {
      findings.push({
        state: "gitignore-unignore",
        path: ".gitignore",
        line: index + 1,
        reason: "build directories must not be unignored"
      });
    }
  });
  return findings;
}

function scanRepo(repo) {
  const repoLabel = labelFor(repo);
  const findings = [];
  for (const [state, args] of [
    ["tracked", ["ls-files"]],
    ["untracked-unignored", ["ls-files", "--others", "--exclude-standard"]]
  ]) {
    for (const relativePath of runGit(repo, args)) {
      if (!existsSync(path.join(repo, relativePath))) {
        continue;
      }
      const classification = classifyForbiddenPath(relativePath);
      if (!classification) {
        continue;
      }
      findings.push({
        state,
        path: relativePath,
        ...classification
      });
    }
  }
  findings.push(...scanGitignore(repo));
  return { repo: repoLabel, findings };
}

if (process.argv.slice(2).includes("--self-test")) {
  try {
    const result = runSelfTest();
    console.log(JSON.stringify({ ok: true, ...result }, null, 2));
  } catch {
    console.error(JSON.stringify({ ok: false, reasonCode: "SELF_TEST_FAILED" }, null, 2));
    process.exitCode = 1;
  }
  process.exit();
}

const repos = findGitRoots();
const repoReports = repos.map(scanRepo);
const findings = repoReports.flatMap((repoReport) =>
  repoReport.findings.map((finding) => ({ repo: repoReport.repo, ...finding }))
);
const report = {
  ok: findings.length === 0,
  workspace: path.basename(workspaceRoot),
  scannedRepos: repoReports.map((repoReport) => repoReport.repo),
  forbiddenAnySegment: [...forbiddenAnySegment].sort(),
  forbiddenTopLevel: [...forbiddenTopLevel].sort(),
  findings
};

mkdirSync(path.dirname(reportPath), { recursive: true });
writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
console.log(JSON.stringify({
  ok: report.ok,
  scannedRepos: report.scannedRepos.length,
  report: "build/reports/workspace-cache-boundary.json",
  findings
}, null, 2));

if (!report.ok) {
  process.exitCode = 1;
}
