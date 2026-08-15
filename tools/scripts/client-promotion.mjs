#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { verifyDocsFastCandidate } from "./docs-fast-promotion.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const repository = "LicoLand/LicoUp";
const actionBranchPattern = /^(feature|fix|docs|refactor|test|chore|release-candidate)\/[A-Za-z0-9._/-]+$/u;
const docsBranch = "docs/readme-refresh";
const docsEfficiencyThresholdMs = 300_000;

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

function run(command, args, {
  capture = false,
  allowFailure = false,
  attempts = 1,
  retryTransient = false,
} = {}) {
  let attempt = 0;
  for (;;) {
    attempt += 1;
    const result = spawnSync(command, args, {
      cwd: repoRoot,
      env: process.env,
      encoding: "utf8",
      shell: false,
      stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
      maxBuffer: 4 * 1024 * 1024,
    });
    if (!result.error && result.status === 0) {
      return capture ? String(result.stdout || "").trim() : "";
    }
    const diagnostic = `${result.error?.message || ""}\n${result.stderr || ""}`;
    if (
      retryTransient &&
      /(?:\bEOF\b|timed? out|connection reset|temporarily unavailable|HTTP 50[0234]|TLS handshake)/iu
        .test(diagnostic)
    ) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1_000);
      continue;
    }
    if (attempt >= attempts) {
      if (allowFailure) return null;
      reject("promotion_command_failed");
    }
  }
  reject("promotion_command_failed");
}

function currentBranch() {
  const branch = run("git", ["symbolic-ref", "--quiet", "--short", "HEAD"], {
    capture: true,
  });
  if (!validBranch(branch)) reject("promotion_current_branch_invalid");
  return branch;
}

function assertCleanWorktree() {
  if (run("git", ["status", "--porcelain"], { capture: true }) !== "") {
    reject("promotion_worktree_dirty");
  }
}

function assertCleanCurrentBranch(head) {
  if (head !== currentBranch()) reject("promotion_head_not_checked_out");
  assertCleanWorktree();
}

function assertRepositoryAccess() {
  const actual = run("gh", [
    "api", `repos/${repository}`, "--jq", ".full_name",
  ], { capture: true, attempts: 3, retryTransient: true });
  if (actual !== repository) reject("promotion_repository_mismatch");
}

function compareStatus(head, base) {
  return run("gh", [
    "api", `repos/${repository}/compare/${encodeURIComponent(base)}...${encodeURIComponent(head)}`,
    "--jq", ".status",
  ], { capture: true, attempts: 3, retryTransient: true });
}

function findOpenPullRequest(head, base) {
  const output = run("gh", [
    "api", "--method", "GET", `repos/${repository}/pulls`,
    "-f", "state=open", "-f", `head=LicoLand:${head}`, "-f", `base=${base}`,
    "--jq", "map({number, url: .html_url})",
  ], { capture: true, attempts: 3, retryTransient: true });
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
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    let pullRequest = findOpenPullRequest(plan.head, plan.base);
    if (pullRequest) return pullRequest;
    run("gh", [
      "api", "--method", "POST", `repos/${repository}/pulls`,
      "-f", `head=${plan.head}`, "-f", `base=${plan.base}`,
      "-f", `title=Promote ${plan.head} to ${plan.base}`,
      "-f", `body=Required aggregate: ${plan.aggregate}. Merge method: merge commit.`,
    ], { capture: true, allowFailure: true });
    pullRequest = findOpenPullRequest(plan.head, plan.base);
    if (pullRequest) return pullRequest;
  }
  reject("promotion_pull_request_missing");
}

function pushTemporaryBranch(plan) {
  if (plan.base !== "nightly") return;
  assertCleanCurrentBranch(plan.head);
  run("npm", ["run", "repo:identity:verify"]);
  run("git", ["push", "--set-upstream", "origin", plan.head]);
}

function waitForRequiredChecks(pullRequest, plan) {
  const number = String(pullRequest.number || "");
  const headSha = run("gh", [
    "api", `repos/${repository}/pulls/${number}`, "--jq", ".head.sha",
  ], { capture: true, attempts: 3, retryTransient: true });
  if (!/^[a-f0-9]{40,64}$/u.test(headSha)) reject("promotion_head_revision_invalid");
  for (;;) {
    const output = run("gh", [
      "api", "--method", "GET", `repos/${repository}/commits/${headSha}/check-runs`,
      "-f", "per_page=100",
    ], { capture: true, attempts: 3, retryTransient: true });
    let runs;
    try {
      runs = JSON.parse(output).check_runs;
    } catch {
      reject("promotion_check_response_invalid");
    }
    if (!Array.isArray(runs)) reject("promotion_check_response_invalid");
    const requiredNames = ["Branch flow", "Commit identity", plan.aggregate, "Auditor"];
    const requiredRuns = requiredNames.map((name) => ({
      name,
      checks: runs.filter((check) => check?.name === name),
    }));
    const completed = requiredRuns.every(({ checks }) =>
      checks.length > 0 && checks.every((check) => check.status === "completed"));
    if (completed) {
      if (requiredRuns.some(({ checks }) =>
        checks.some((check) => check.conclusion !== "success"))) {
        reject("promotion_required_check_failed");
      }
      return;
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10_000);
  }
}

function waitAndMerge(pullRequest, plan) {
  const number = String(pullRequest.number || "");
  if (!/^[1-9][0-9]*$/u.test(number)) reject("promotion_pull_request_invalid");
  waitForRequiredChecks(pullRequest, plan);
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    run("gh", [
      "api", "--method", "PUT", `repos/${repository}/pulls/${number}/merge`,
      "-f", "merge_method=merge",
    ], { capture: true, allowFailure: true });
    const mergedAt = run("gh", [
      "api", `repos/${repository}/pulls/${number}`, "--jq", ".merged_at",
    ], { capture: true, attempts: 3, retryTransient: true });
    if (mergedAt !== "" && mergedAt !== "null") {
      return Object.freeze({ number, mergedAt });
    }
  }
  reject("promotion_merge_not_confirmed");
}

function printReceipt(receipt) {
  process.stdout.write(`${JSON.stringify({ ...receipt, privateDataIncluded: false })}\n`);
}

function advance(head, base) {
  const started = performance.now();
  const plan = promotionPlan(head, base);
  pushTemporaryBranch(plan);
  const status = compareStatus(plan.head, plan.base);
  if (status === "identical") {
    const receipt = Object.freeze({
      ok: true,
      status: "already-promoted",
      head,
      base,
      durationMs: Math.round(performance.now() - started),
    });
    printReceipt(receipt);
    return receipt;
  }
  if (!hasPromotableCommits(status)) reject("promotion_topology_not_ahead");
  const pullRequest = openPullRequest(plan);
  const merged = waitAndMerge(pullRequest, plan);
  const receipt = Object.freeze({
    ok: true,
    status: "merged",
    head,
    base,
    pullRequestNumber: merged.number,
    mergedAt: merged.mergedAt,
    durationMs: Math.round(performance.now() - started),
  });
  printReceipt(receipt);
  return receipt;
}

function commandSucceeds(command, args) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: ["ignore", "ignore", "ignore"],
  });
  return !result.error && result.status === 0;
}

function assertDetachedDocsCandidate() {
  if (commandSucceeds("git", ["symbolic-ref", "--quiet", "HEAD"])) {
    reject("docs_candidate_not_detached");
  }
  assertCleanWorktree();
  run("git", ["fetch", "origin", "--prune"]);
  const record = run("git", ["rev-list", "--parents", "-n", "1", "HEAD"], {
    capture: true,
  }).split(" ");
  const nightly = run("git", ["rev-parse", "origin/nightly"], { capture: true });
  if (record.length !== 2 || record[1] !== nightly) reject("docs_candidate_parent_invalid");
  if (commandSucceeds("git", ["show-ref", "--verify", "--quiet", `refs/heads/${docsBranch}`])) {
    reject("docs_branch_exists_local");
  }
  if (commandSucceeds("git", ["ls-remote", "--exit-code", "--heads", "origin", docsBranch])) {
    reject("docs_branch_exists_remote");
  }
  run("npm", ["run", "repo:identity:verify"]);
}

export function summarizeDocsTrain({ startedAtMs, endedAt, stages }) {
  if (!Number.isFinite(startedAtMs) || !Array.isArray(stages) || stages.length !== 3) {
    reject("docs_timing_invalid");
  }
  const endedAtMs = Date.parse(endedAt);
  if (!Number.isFinite(endedAtMs)) reject("docs_timing_invalid");
  const totalDurationMs = Math.max(0, Math.round(endedAtMs - startedAtMs));
  const stageDurationsMs = stages.map((stage) => {
    if (!Number.isFinite(stage.durationMs) || stage.durationMs < 0) {
      reject("docs_timing_invalid");
    }
    return Object.freeze({
      edge: `${stage.head}->${stage.base}`,
      durationMs: Math.round(stage.durationMs),
    });
  });
  return Object.freeze({
    ok: true,
    command: "docs-train",
    status: "release-branch-promoted",
    branch: docsBranch,
    totalDurationMs,
    efficiencyThresholdMs: docsEfficiencyThresholdMs,
    efficiencyWarning: totalDurationMs > docsEfficiencyThresholdMs,
    stageDurationsMs: Object.freeze(stageDurationsMs),
  });
}

async function docsTrain() {
  assertDetachedDocsCandidate();
  await verifyDocsFastCandidate({ base: "origin/nightly", head: "HEAD", root: repoRoot });
  const startedAtMs = Date.now();
  run("git", ["switch", "-c", docsBranch]);
  const stages = [
    advance(docsBranch, "nightly"),
    advance("nightly", "stable"),
    advance("stable", "release"),
  ];
  const finalStage = stages.at(-1);
  if (finalStage.status !== "merged") reject("docs_release_merge_missing");
  const receipt = summarizeDocsTrain({
    startedAtMs,
    endedAt: finalStage.mergedAt,
    stages,
  });
  printReceipt(receipt);
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

export function resolvePromotionHead(command, values, readCurrentBranch) {
  if (command === "docs-train") return null;
  return values.head || readCurrentBranch();
}

async function main() {
  const { command, values } = parseArgs(process.argv.slice(2));
  const head = resolvePromotionHead(command, values, currentBranch);
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
    advance(head, "nightly");
    advance("nightly", "stable");
    advance("stable", "release");
    printReceipt({ ok: true, command, status: "release-branch-promoted" });
    return;
  }
  if (command === "docs-train") {
    if (Object.keys(values).length !== 0) reject("promotion_arguments_invalid");
    await docsTrain();
    return;
  }
  reject("promotion_command_invalid");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => {
    const code = error instanceof PromotionError ? error.code : "promotion_failed";
    process.stderr.write(`${JSON.stringify({ ok: false, code, privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  });
}
