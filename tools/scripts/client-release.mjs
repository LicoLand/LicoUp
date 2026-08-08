#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const repository = "LicoLand/LicoUp";
const versionFiles = Object.freeze([
  "Cargo.lock",
  "Cargo.toml",
  "apps/desktop/ios/Runner.xcodeproj/project.pbxproj",
  "apps/desktop/macos/Runner.xcodeproj/project.pbxproj",
  "apps/desktop/pubspec.yaml",
  "crates/licoup-native/Cargo.toml",
  "package-lock.json",
  "package.json",
  "tools/client-version.json",
]);

function fail(code) {
  throw Object.assign(new Error(code), { code });
}

function assert(condition, code) {
  if (!condition) fail(code);
}

function run(command, args, { capture = false, allowFailure = false } = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || (!allowFailure && result.status !== 0)) fail("release_command_failed");
  return {
    ok: !result.error && result.status === 0,
    stdout: result.stdout?.trim() || "",
  };
}

function git(args, options) {
  return run("git", args, { capture: true, ...options });
}

function gh(args, options) {
  return run("gh", args, { capture: true, ...options });
}

function parseArgs(argv) {
  if (argv.length === 1 && argv[0] === "--self-test") return { selfTest: true };
  const options = { version: "", target: "macos-arm64", publish: true };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === "--draft") {
      options.publish = false;
    } else if (flag === "--version" || flag === "--target") {
      assert(index + 1 < argv.length, "release_argument_missing");
      options[flag.slice(2)] = argv[index + 1];
      index += 1;
    } else {
      fail("release_argument_invalid");
    }
  }
  assert(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(options.version), "release_version_invalid");
  assert(/^[a-z0-9-]+$/u.test(options.target), "release_target_invalid");
  return options;
}

function loadJson(relativePath) {
  return JSON.parse(readFileSync(path.join(repoRoot, relativePath), "utf8"));
}

function validateContract() {
  const template = loadJson("tools/client-release-template.json");
  assert(template.schemaVersion === "licoup.client-release-template.v1", "release_template_invalid");
  assert(
    JSON.stringify(template.promotion?.branches) === JSON.stringify(["nightly", "stable", "release"]),
    "release_promotion_order_invalid",
  );
  assert(template.promotion?.mergeMethod === "merge", "release_promotion_method_invalid");
  assert(template.promotion?.rulesetMutation === "forbidden", "release_ruleset_mutation_invalid");
  assert(template.publication?.operatorMonitoringTimeoutMinutes === null, "release_monitor_timeout_invalid");
  assert(template.localPreflight?.targets?.["macos-arm64"], "release_macos_template_missing");
  assert(
    JSON.stringify(template.stages) === JSON.stringify([
      "version-and-local-preflight",
      "single-release-commit",
      "nightly-integration",
      "stable-promotion",
      "release-promotion",
      "publication-and-monitoring",
    ]),
    "release_stage_order_invalid",
  );
  return template;
}

function versionAt(ref) {
  const result = git(["show", `${ref}:tools/client-version.json`], { allowFailure: true });
  if (!result.ok) return "";
  try {
    return JSON.parse(result.stdout).productVersion || "";
  } catch {
    fail("release_remote_version_invalid");
  }
}

function assertCleanNightly() {
  assert(git(["branch", "--show-current"]).stdout === "nightly", "release_branch_must_be_nightly");
  assert(git(["status", "--porcelain"]).stdout === "", "release_worktree_not_clean");
}

function changedFiles() {
  const output = git(["status", "--porcelain=v1", "-z"]).stdout;
  if (!output) return [];
  return output.split("\0").filter(Boolean).map((record) => record.slice(3));
}

function createReleaseCommit(options) {
  const manifest = loadJson("tools/client-version.json");
  assert(manifest.productVersion !== options.version, "release_version_not_advanced");
  run("npm", ["run", "client:version:set", "--", "--version", options.version, "--build-number", String(manifest.buildNumber + 1)]);
  run("npm", ["run", "client:release:preflight", "--", "--target", options.target, "--tag", `v${options.version}`, "--allow-side-effects"]);
  const actual = changedFiles().sort();
  const allowed = new Set(versionFiles);
  assert(actual.length > 0 && actual.every((file) => allowed.has(file)), "release_change_scope_invalid");
  run("npm", ["run", "repo:identity:install"]);
  run("git", ["add", "--", ...versionFiles]);
  run("git", ["commit", "-m", `Release v${options.version}`]);
}

function ensureReleaseCommit(options) {
  run("git", ["fetch", "origin", "nightly", "stable", "release"]);
  assertCleanNightly();
  const local = git(["rev-parse", "HEAD"]).stdout;
  const upstream = git(["rev-parse", "origin/nightly"]).stdout;
  if (versionAt("origin/nightly") === options.version) return false;
  if (local === upstream) {
    createReleaseCommit(options);
    return true;
  }
  assert(git(["merge-base", "--is-ancestor", upstream, local], { allowFailure: true }).ok, "release_nightly_diverged");
  assert(git(["rev-list", "--count", `${upstream}..${local}`]).stdout === "1", "release_commit_count_invalid");
  assert(loadJson("tools/client-version.json").productVersion === options.version, "release_resume_version_mismatch");
  assert(git(["show", "-s", "--format=%s", "HEAD"]).stdout === `Release v${options.version}`, "release_resume_commit_invalid");
  return true;
}

function ensureFork(login) {
  if (!gh(["repo", "view", `${login}/LicoUp`], { allowFailure: true }).ok) {
    run("gh", ["repo", "fork", repository, "--clone=false"]);
  }
  run("gh", ["repo", "sync", `${login}/LicoUp`, "--source", repository, "--branch", "nightly"]);
  const url = `https://github.com/${login}/LicoUp.git`;
  if (git(["remote", "get-url", "release-fork"], { allowFailure: true }).ok) {
    run("git", ["remote", "set-url", "release-fork", url]);
  } else {
    run("git", ["remote", "add", "release-fork", url]);
  }
  run("git", ["fetch", "release-fork", "nightly"]);
}

function parseArray(value) {
  const parsed = JSON.parse(value || "[]");
  assert(Array.isArray(parsed), "release_github_response_invalid");
  return parsed;
}

async function requiredChecks(prNumber) {
  const headSha = gh(["pr", "view", String(prNumber), "--repo", repository, "--json", "headRefOid", "--jq", ".headRefOid"]).stdout;
  while (true) {
    const combined = JSON.parse(gh(["api", `repos/${repository}/commits/${headSha}/status`]).stdout);
    const identity = (combined.statuses || []).find(({ context }) => context === "LicoUp / commit identity");
    const checks = parseArray(gh([
      "pr", "checks", String(prNumber), "--repo", repository, "--json", "name,state",
    ], { allowFailure: true }).stdout || "[]");
    const branchFlow = checks.find(({ name }) => name === "Branch flow policy");
    if (identity?.state === "failure" || identity?.state === "error") fail("release_identity_gate_failed");
    if (branchFlow?.state === "FAILURE" || branchFlow?.state === "ERROR") fail("release_branch_flow_gate_failed");
    if (identity?.state === "success" && branchFlow?.state === "SUCCESS") return;
    await new Promise((resolve) => setTimeout(resolve, 10000));
  }
}

async function nightlyPullRequest(options, login) {
  const branch = `release/v${options.version}`;
  run("git", ["push", "release-fork", `HEAD:refs/heads/${branch}`]);
  const prs = parseArray(gh([
    "pr", "list", "--repo", repository, "--base", "nightly", "--head", `${login}:${branch}`,
    "--state", "all", "--json", "number,state,mergedAt",
  ]).stdout);
  let pr = prs.find((candidate) => candidate.state === "OPEN" || candidate.mergedAt);
  if (!pr) {
    const url = gh([
      "pr", "create", "--repo", repository, "--base", "nightly", "--head", `${login}:${branch}`,
      "--title", `Release v${options.version}`, "--body", "Automated release promotion generated after the complete local preflight passed.",
    ]).stdout;
    pr = { number: Number(url.split("/").at(-1)), state: "OPEN", mergedAt: null };
  }
  if (!pr.mergedAt) {
    await requiredChecks(pr.number);
    run("gh", ["pr", "merge", String(pr.number), "--repo", repository, "--rebase", "--delete-branch"]);
  }
}

async function promotionPullRequest({ base, head, version }) {
  run("git", ["fetch", "origin", head, base]);
  if (versionAt(`origin/${base}`) === version) return;
  assert(versionAt(`origin/${head}`) === version, "release_promotion_source_version_mismatch");
  const headSha = git(["rev-parse", `origin/${head}`]).stdout;
  const prs = parseArray(gh([
    "pr", "list", "--repo", repository, "--base", base, "--head", head,
    "--state", "all", "--json", "number,state,mergedAt,headRefOid",
  ]).stdout);
  let pr = prs.find((candidate) => candidate.headRefOid === headSha && (candidate.state === "OPEN" || candidate.mergedAt));
  if (!pr) {
    const url = gh([
      "pr", "create", "--repo", repository, "--base", base, "--head", head,
      "--title", `Promote v${version}: ${head} to ${base}`,
      "--body", "Automated direct-branch promotion. The source commit already passed the local release preflight.",
    ]).stdout;
    pr = { number: Number(url.split("/").at(-1)), state: "OPEN", mergedAt: null };
  }
  if (!pr.mergedAt) {
    await requiredChecks(pr.number);
    run("gh", ["pr", "merge", String(pr.number), "--repo", repository, "--merge"]);
  }
}

async function dispatchAndWatch(options, template) {
  if (gh(["release", "view", `v${options.version}`, "--repo", repository], { allowFailure: true }).ok) return;
  run("git", ["fetch", "origin", "release"]);
  const releaseSha = git(["rev-parse", "origin/release"]).stdout;
  const existingRuns = parseArray(gh([
    "run", "list", "--repo", repository, "--workflow", template.publication.workflow,
    "--event", "workflow_dispatch", "--branch", template.publication.ref,
    "--limit", "20", "--json", "databaseId,headSha,status",
  ]).stdout);
  const active = existingRuns.find((candidate) => candidate.headSha === releaseSha && candidate.status !== "completed");
  if (active) {
    run("gh", ["run", "watch", String(active.databaseId), "--repo", repository, "--exit-status", "--interval", "10"]);
    run("gh", ["release", "view", `v${options.version}`, "--repo", repository]);
    return;
  }
  const before = new Set(existingRuns.map(({ databaseId }) => databaseId));
  run("gh", [
    "workflow", "run", template.publication.workflow, "--repo", repository, "--ref", template.publication.ref,
    "-f", `release_tag=v${options.version}`, "-f", `target=${options.target}`,
    "-f", `publish_release=${options.publish}`,
  ]);
  let runId = 0;
  while (!runId) {
    const runs = parseArray(gh([
      "run", "list", "--repo", repository, "--workflow", template.publication.workflow,
      "--event", "workflow_dispatch", "--branch", template.publication.ref,
      "--limit", "20", "--json", "databaseId,headSha",
    ]).stdout);
    runId = runs.find((candidate) => candidate.headSha === releaseSha && !before.has(candidate.databaseId))?.databaseId || 0;
    if (!runId) await new Promise((resolve) => setTimeout(resolve, 5000));
  }
  run("gh", ["run", "watch", String(runId), "--repo", repository, "--exit-status", "--interval", "10"]);
  run("gh", ["release", "view", `v${options.version}`, "--repo", repository]);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const template = validateContract();
  if (options.selfTest) {
    assert(versionFiles.includes("tools/client-version.json"), "release_version_authority_missing");
    process.stdout.write("client_release=self_test_passed\n");
    return;
  }
  run("gh", ["auth", "status"]);
  const origin = git(["remote", "get-url", "origin"]).stdout;
  assert(
    origin === "https://github.com/LicoLand/LicoUp.git" || origin === "git@github.com:LicoLand/LicoUp.git",
    "release_origin_invalid",
  );
  const needsNightlyIntegration = ensureReleaseCommit(options);
  const login = gh(["api", "user", "--jq", ".login"]).stdout;
  ensureFork(login);
  if (needsNightlyIntegration) await nightlyPullRequest(options, login);
  await promotionPullRequest({ base: "stable", head: "nightly", version: options.version });
  await promotionPullRequest({ base: "release", head: "stable", version: options.version });
  await dispatchAndWatch(options, template);
  process.stdout.write(`client_release=published version=${options.version} target=${options.target}\n`);
}

main().catch((error) => {
  process.stderr.write(`LicoUp release: ${error?.code || "release_failed"}\n`);
  process.exitCode = 1;
});
