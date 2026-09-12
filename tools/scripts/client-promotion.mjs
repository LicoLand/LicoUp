#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { candidateMaturity, REQUIRED_PLATFORM_ASSETS, verifyAppCheck, verifyRelease } from "./client-weekly-release.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const repository = "LicoLand/LicoUp";
const actionBranchPattern = /^(feature|fix|docs|refactor|test|chore)\/[A-Za-z0-9._/-]+$/u;
const cutoffBranchPattern = /^nightly-cutoff\/\d{4}-\d{2}-\d{2}$/u;

// Train cuts one snapshot onto `release`. Later `nightly` commits are a later
// cut, not the in-flight version. Public publish remains `origin/release` only.
// These edges do not freeze ordinary merges into `nightly`.
export const releaseTrainEdges = Object.freeze([
  Object.freeze({ head: "current", base: "nightly", aggregate: "Client required" }),
  Object.freeze({ head: "nightly-cutoff/YYYY-MM-DD", base: "stable", aggregate: "Stable client" }),
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
  } else if (base === "stable" && cutoffBranchPattern.test(head)) {
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
  if (cutoffBranchPattern.test(head)) return "stable";
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

export function reconcileRequiredChecks(rollup, required) {
  if (!Array.isArray(rollup) || !Array.isArray(required) || required.length === 0) reject("promotion_check_response_invalid");
  for (const context of required) {
    const matches = rollup.filter(entry => entry?.name === context || entry?.context === context);
    if (matches.length === 0) return Object.freeze({ status: "pending", context });
    if (matches.length > 1) reject("promotion_check_ambiguous");
    const state = matches[0].conclusion || matches[0].state || matches[0].status;
    if (["failure", "FAILED", "error", "cancelled", "timed_out"].includes(state)) return Object.freeze({ status: "failed", context });
    if (!["success", "SUCCESS"].includes(state)) return Object.freeze({ status: "pending", context });
  }
  return Object.freeze({ status: "complete" });
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

function reconcileAndMerge(plan, pullRequest, expectedHead) {
  const number = String(pullRequest.number || "");
  if (!/^[1-9][0-9]*$/u.test(number)) reject("promotion_pull_request_invalid");
  const output = run("gh", ["pr", "view", number, "--repo", repository, "--json", "statusCheckRollup"], { capture: true });
  let rollup;
  try { rollup = JSON.parse(output || "{}").statusCheckRollup; } catch { reject("promotion_check_response_invalid"); }
  const required = plan.base === "stable"
    ? ["Branch flow", "Commit identity", "Auditor", "Stable client", "Monthly candidate ready", "Apple Release ready"]
    : ["Branch flow", "Commit identity", "Auditor", plan.aggregate];
  const state = reconcileRequiredChecks(rollup, required);
  if (state.status !== "complete") return { number, ...state };
  run("gh", ["pr", "merge", number, "--repo", repository, "--merge", "--match-head-commit", expectedHead]);
  const mergedAt = run("gh", [
    "pr", "view", number, "--repo", repository, "--json", "mergedAt", "--jq", ".mergedAt",
  ], { capture: true });
  if (mergedAt === "" || mergedAt === "null") reject("promotion_merge_not_confirmed");
  return { number, status: "merged" };
}

function printReceipt(receipt) {
  process.stdout.write(`${JSON.stringify({ ...receipt, privateDataIncluded: false })}\n`);
}

export function candidateTagForRef(head) {
  if (!cutoffBranchPattern.test(head)) reject("candidate_ref_invalid");
  return `nightly-candidate-${head.slice("nightly-cutoff/".length, -3)}`;
}

export function validateCandidateRemote(plan, values) {
  const revision = run("gh", ["api", `repos/${repository}/git/ref/heads/${encodeURIComponent(plan.head)}`, "--jq", ".object.sha"], { capture: true });
  if (plan.base !== "stable") return revision;
  const tag = candidateTagForRef(plan.head);
  const tagRevision = run("gh", ["api", `repos/${repository}/git/ref/tags/${tag}`, "--jq", ".object.sha"], { capture: true });
  if (revision !== tagRevision) reject("candidate_release_source_mismatch");
  let release, checks;
  try {
    release = JSON.parse(run("gh", ["api", `repos/${repository}/releases/tags/${tag}`], { capture: true }));
    checks = JSON.parse(run("gh", ["api", `repos/${repository}/commits/${revision}/check-runs`, "--jq", ".check_runs"], { capture: true }));
  } catch { reject("candidate_evidence_invalid"); }
  verifyRelease(release, { tag, revision, assets: REQUIRED_PLATFORM_ASSETS });
  if (Date.now() < Date.parse(candidateMaturity(release.published_at))) reject("candidate_immature");
  verifyAppCheck(checks, { name: "Apple Release ready", revision,
    appId: Number(values["apple-app-id"] || process.env.LICOUP_APPLE_RELEASE_APP_ID) });
  return revision;
}

function advance(head, base, values = {}) {
  const plan = promotionPlan(head, base);
  pushTemporaryBranch(plan);
  const status = compareStatus(plan.head, plan.base);
  if (status === "identical") {
    printReceipt({ ok: true, status: "already-promoted", head, base });
    return;
  }
  if (!hasPromotableCommits(status)) reject("promotion_topology_not_ahead");
  const expectedHead = validateCandidateRemote(plan, values);
  const pullRequest = openPullRequest(plan);
  const result = reconcileAndMerge(plan, pullRequest, expectedHead);
  printReceipt({ ok: true, status: result.status, head, base, pullRequestNumber: result.number, pendingContext: result.context });
  return result.status;
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
  if (command === "validate") {
    const plan = promotionPlan(head, values.base || inferPromotionBase(head));
    printReceipt({ ok: true, command, head, base: plan.base, revision: validateCandidateRemote(plan, values), status: "candidate-ready" });
    return;
  }
  if (command === "advance") {
    advance(head, values.base || inferPromotionBase(head), values);
    return;
  }
  if (command === "train") {
    if (!actionBranchPattern.test(head)) reject("promotion_train_source_invalid");
    // One authorized cut: action-prefixed → nightly → stable → release.
    // Do not run this again to fold later nightly into an in-flight publish.
    const status = advance(head, "nightly", values);
    printReceipt({ ok: true, command, status: status === "merged" ? "nightly-updated-awaiting-monthly-candidate" : status });
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
