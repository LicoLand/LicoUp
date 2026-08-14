#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
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

function runGit(args) {
  const result = spawnSync("git", args, {
    cwd: repoRoot,
    encoding: "utf8",
    shell: false
  });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${result.stderr.trim()}`);
  }
  return result.stdout.split(/\r?\n/).filter(Boolean);
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

function scanGitignore() {
  const gitignore = path.join(repoRoot, ".gitignore");
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

function scanRepo() {
  const findings = [];
  for (const [state, args] of [
    ["tracked", ["ls-files"]],
    ["untracked-unignored", ["ls-files", "--others", "--exclude-standard"]]
  ]) {
    for (const relativePath of runGit(args)) {
      if (!existsSync(path.join(repoRoot, relativePath))) {
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
  findings.push(...scanGitignore());
  return findings;
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

const findings = scanRepo();
const report = {
  ok: findings.length === 0,
  repository: path.basename(repoRoot),
  forbiddenAnySegment: [...forbiddenAnySegment].sort(),
  forbiddenTopLevel: [...forbiddenTopLevel].sort(),
  findings
};

mkdirSync(path.dirname(reportPath), { recursive: true });
writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
console.log(JSON.stringify({
  ok: report.ok,
  repository: report.repository,
  report: "build/reports/workspace-cache-boundary.json",
  findings
}, null, 2));

if (!report.ok) {
  process.exitCode = 1;
}
