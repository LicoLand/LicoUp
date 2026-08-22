#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const repository = "LicoLand/LicoUp";
const actionBranchPattern = /^(feature|fix|docs|refactor|test|chore)\/[A-Za-z0-9._/-]+$/u;

// Train cuts one snapshot onto `release`. Later `nightly` commits are a later
// cut, not the in-flight version. Public publish remains `origin/release` only.
// These edges do not freeze ordinary merges into `nightly`.
export const releaseTrainEdges = Object.freeze([
  Object.freeze({ head: "current", base: "nightly", aggregate: "Client required" }),
  Object.freeze({ head: "nightly", base: "stable", aggregate: "Stable client" }),
  Object.freeze({ head: "stable", base: "release", aggregate: "Release ready" }),
]);

export class PromotionError extends Error {
  constructor(code) {
    super(code);
    this.name = "PromotionError";
    this.code = code;
  }
}

function reject(code) {
  throw new PromotionError(code);
}

function validBranch(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 &&
    !value.startsWith("-") && !value.startsWith("/") && !value.endsWith("/") &&
    !value.includes("..") && !value.includes("@{") &&
    /^[A-Za-z0-9._/-]+$/u.test(value);
}

export function promotionPlan(head, base) {
  if (!validBranch(head) || !validBranch(base)) reject("promotion_branch_invalid");
  let aggregate;
  if (base === "nightly" && actionBranchPattern.test(head)) {
    aggregate = "Client required";
  } else if (base === "stable" && head === "nightly") {
    aggregate = "Stable client";
  } else if (base === "release" && head === "stable") {
    aggregate = "Release ready";
  } else {
    reject("promotion_edge_invalid");
  }
  return Object.freeze({ repository, head, base, aggregate, mergeMethod: "merge" });
}

export function inferPromotionBase(head) {
  if (actionBranchPattern.test(head)) return "nightly";
  if (head === "nightly") return "stable";
  if (head === "stable") return "release";
  reject("promotion_source_has_no_next_edge");
}

export function hasPromotableCommits(compareStatus) {
  return compareStatus === "ahead" || compareStatus === "diverged";
}

// A fresh pull request can have zero required checks for a short window while
// GitHub registers the aggregate check. Only a rollup entry named after the
// plan's aggregate (check-run `name` or commit-status `context`) proves the
// branch protection gate exists and `gh pr checks --required` will observe it.
export function requiredCheckRegistered(rollup, aggregate) {
  if (!Array.isArray(rollup)) return false;
  return rollup.some((entry) =>
    entry !== null && typeof entry === "object" &&
    (entry.name === aggregate || entry.context === aggregate));
}

function run(command, args, { capture = false, allowFailure = false } = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    if (allowFailure) return null;
    reject("promotion_command_failed");
  }
  return capture ? String(result.stdout || "").trim() : "";
}

function currentBranch() {
  const branch = run("git", ["symbolic-ref", "--quiet", "--short", "HEAD"], {
    capture: true,
  });
  if (!validBranch(branch)) reject("promotion_current_branch_invalid");
  return branch;
}

function assertCleanCurrentBranch(head) {
  if (head !== currentBranch()) reject("promotion_head_not_checked_out");
  if (run("git", ["status", "--porcelain"], { capture: true }) !== "") {
    reject("promotion_worktree_dirty");
  }
}

function assertRepositoryAccess() {
  const actual = run("gh", [
    "repo", "view", repository, "--json", "nameWithOwner", "--jq", ".nameWithOwner",
  ], { capture: true });
  if (actual !== repository) reject("promotion_repository_mismatch");
}

function compareStatus(head, base) {
  return run("gh", [
    "api", `repos/${repository}/compare/${encodeURIComponent(base)}...${encodeURIComponent(head)}`,
    "--jq", ".status",
  ], { capture: true });
}

function findOpenPullRequest(head, base) {
  const output = run("gh", [
    "pr", "list", "--repo", repository, "--state", "open", "--head", head,
    "--base", base, "--limit", "5", "--json", "number,url",
  ], { capture: true });
  let pullRequests;
  try {
    pullRequests = JSON.parse(output || "[]");
  } catch {
    reject("promotion_pull_request_response_invalid");
  }
  if (!Array.isArray(pullRequests) || pullRequests.length > 1) {
    reject("promotion_pull_request_ambiguous");
  }
  return pullRequests[0] || null;
}

function openPullRequest(plan) {
  let pullRequest = findOpenPullRequest(plan.head, plan.base);
  if (pullRequest) return pullRequest;
  run("gh", [
    "pr", "create", "--repo", repository, "--head", plan.head, "--base", plan.base,
    "--title", `Promote ${plan.head} to ${plan.base}`,
    "--body", `Required aggregate: ${plan.aggregate}. Merge method: merge commit.`,
  ]);
  pullRequest = findOpenPullRequest(plan.head, plan.base);
  if (!pullRequest) reject("promotion_pull_request_missing");
  return pullRequest;
}

function pushTemporaryBranch(plan) {
  if (plan.base !== "nightly") return;
  assertCleanCurrentBranch(plan.head);
  run("npm", ["run", "repo:identity:verify"]);
  run("git", ["push", "--set-upstream", "origin", plan.head]);
}

function waitForRequiredCheckRegistration(plan, number) {
  const deadline = Date.now() + 10 * 60 * 1000;
  for (;;) {
    const output = run("gh", [
      "pr", "view", number, "--repo", repository, "--json", "statusCheckRollup",
    ], { capture: true });
    let rollup;
    try {
      rollup = JSON.parse(output || "{}").statusCheckRollup;
    } catch {
      reject("promotion_check_response_invalid");
    }
    if (requiredCheckRegistered(rollup, plan.aggregate)) return;
    if (Date.now() >= deadline) reject("promotion_check_registration_timeout");
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10_000);
  }
}

function waitAndMerge(plan, pullRequest) {
  const number = String(pullRequest.number || "");
  if (!/^[1-9][0-9]*$/u.test(number)) reject("promotion_pull_request_invalid");
  waitForRequiredCheckRegistration(plan, number);
  run("gh", [
    "pr", "checks", number, "--repo", repository, "--required", "--watch",
    "--fail-fast", "--interval", "10",
  ]);
  run("gh", ["pr", "merge", number, "--repo", repository, "--merge"]);
  const mergedAt = run("gh", [
    "pr", "view", number, "--repo", repository, "--json", "mergedAt", "--jq", ".mergedAt",
  ], { capture: true });
  if (mergedAt === "" || mergedAt === "null") reject("promotion_merge_not_confirmed");
  return number;
}

function printReceipt(receipt) {
  process.stdout.write(`${JSON.stringify({ ...receipt, privateDataIncluded: false })}\n`);
}

function advance(head, base) {
  const plan = promotionPlan(head, base);
  pushTemporaryBranch(plan);
  const status = compareStatus(plan.head, plan.base);
  if (status === "identical") {
    printReceipt({ ok: true, status: "already-promoted", head, base });
    return;
  }
  if (!hasPromotableCommits(status)) reject("promotion_topology_not_ahead");
  const pullRequest = openPullRequest(plan);
  const number = waitAndMerge(plan, pullRequest);
  printReceipt({ ok: true, status: "merged", head, base, pullRequestNumber: number });
}

function parseArgs(argv) {
  const command = argv[0] || "plan";
  const values = {};
  for (let index = 1; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined || values[flag.slice(2)] !== undefined) {
      reject("promotion_arguments_invalid");
    }
    values[flag.slice(2)] = value;
  }
  return { command, values };
}

function main() {
  const { command, values } = parseArgs(process.argv.slice(2));
  const head = values.head || currentBranch();
  if (command === "plan") {
    printReceipt({ ok: true, command, ...promotionPlan(head, values.base || inferPromotionBase(head)) });
    return;
  }
  assertRepositoryAccess();
  if (command === "advance") {
    advance(head, values.base || inferPromotionBase(head));
    return;
  }
  if (command === "train") {
    if (!actionBranchPattern.test(head)) reject("promotion_train_source_invalid");
    // One authorized cut: action-prefixed → nightly → stable → release.
    // Do not run this again to fold later nightly into an in-flight publish.
    advance(head, "nightly");
    advance("nightly", "stable");
    advance("stable", "release");
    printReceipt({ ok: true, command, status: "release-branch-promoted" });
    return;
  }
  reject("promotion_command_invalid");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    main();
  } catch (error) {
    const code = error instanceof PromotionError ? error.code : "promotion_failed";
    process.stderr.write(`${JSON.stringify({ ok: false, code, privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  }
}
