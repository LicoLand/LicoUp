#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

export const LONG_LIVED_BRANCHES = Object.freeze(["nightly", "stable", "release"]);
const LONG_LIVED = new Set(LONG_LIVED_BRANCHES);
const RETIRED = new Set(["main", "master"]);
const ZERO_OID = "0".repeat(40);
const DIRECT_UPSTREAM = Object.freeze({ stable: "nightly", release: "stable" });

function identity(payload) {
  return {
    base: payload?.repository?.full_name || "",
    head: payload?.pull_request?.head?.repo?.full_name || ""
  };
}

function sameRepository(payload) {
  const repositories = identity(payload);
  return repositories.base.length > 0
    && repositories.head.length > 0
    && repositories.base === repositories.head;
}

function hasRepositoryIdentity(payload) {
  const repositories = identity(payload);
  return repositories.base.length > 0 && repositories.head.length > 0;
}

export function evaluateBranchFlow({
  eventName = "",
  refName = "",
  baseRef = "",
  headRef = "",
  payload = {}
} = {}) {
  if (eventName === "push") {
    return LONG_LIVED.has(refName)
      ? { ok: true, code: "protected-push-event" }
      : { ok: false, code: "unexpected-push-ref" };
  }
  if (eventName !== "pull_request" && eventName !== "pull_request_target") {
    return { ok: true, code: "event-not-governed" };
  }

  const base = baseRef || payload.pull_request?.base?.ref || "";
  const head = headRef || payload.pull_request?.head?.ref || "";
  if (RETIRED.has(base)) return { ok: false, code: "retired-base" };
  if (!LONG_LIVED.has(base)) return { ok: true, code: "base-not-governed" };
  if (!hasRepositoryIdentity(payload)) {
    return { ok: false, code: "repository-identity-missing" };
  }
  if (base === "nightly") {
    return !LONG_LIVED.has(head) && !RETIRED.has(head) && head.length > 0
      ? { ok: true, code: sameRepository(payload) ? "temporary-to-nightly" : "fork-to-nightly" }
      : { ok: false, code: "nightly-source-invalid" };
  }
  if (!sameRepository(payload)) return { ok: false, code: "cross-repository-promotion" };
  const required = DIRECT_UPSTREAM[base];
  return head === required
    ? { ok: true, code: `${required}-to-${base}` }
    : { ok: false, code: `${base}-source-invalid` };
}

function git(args) {
  return execFileSync("git", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  }).trim();
}

function parents(commit) {
  return git(["show", "-s", "--format=%P", commit]).split(/\s+/u).filter(Boolean);
}

function resolveBranch(branch) {
  for (const ref of [`refs/remotes/origin/${branch}`, `refs/heads/${branch}`]) {
    try {
      return git(["rev-parse", "--verify", `${ref}^{commit}`]);
    } catch {
      // Try the canonical local fallback.
    }
  }
  return "";
}

function isAncestor(ancestor, descendant) {
  try {
    execFileSync("git", ["merge-base", "--is-ancestor", ancestor, descendant], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

export function verifyProtectedPushTopology({
  branch,
  before,
  after,
  commitParents = parents,
  branchTip = resolveBranch,
  ancestor = isAncestor
} = {}) {
  if (!LONG_LIVED.has(branch)) return { ok: false, code: "protected-branch-invalid" };
  if (!before || !after || after === ZERO_OID) {
    return { ok: false, code: "protected-branch-ref-invalid" };
  }
  if (before === ZERO_OID) {
    if (branch === "nightly") {
      return { ok: false, code: "nightly-bootstrap-forbidden" };
    }
    const upstream = DIRECT_UPSTREAM[branch];
    const tip = branchTip(upstream);
    return tip && after === tip
      ? { ok: true, code: `${upstream}-tip-bootstrapped-${branch}` }
      : { ok: false, code: "promotion-bootstrap-tip-mismatch" };
  }
  const afterParents = commitParents(after);
  if (afterParents.length !== 2 || afterParents[0] !== before) {
    return { ok: false, code: "protected-branch-not-single-merge" };
  }
  const mergedHead = afterParents[1];
  if (branch === "nightly") {
    for (const protectedBranch of LONG_LIVED_BRANCHES) {
      if (protectedBranch === branch) continue;
      const tip = branchTip(protectedBranch);
      if (tip && ancestor(mergedHead, tip)) {
        return { ok: false, code: "nightly-source-protected" };
      }
    }
    return { ok: true, code: "temporary-merge-advanced-nightly" };
  }
  const upstream = DIRECT_UPSTREAM[branch];
  const tip = branchTip(upstream);
  if (!tip) return { ok: false, code: "promotion-source-missing" };
  return mergedHead === tip
    ? { ok: true, code: `${upstream}-merge-advanced-${branch}` }
    : { ok: false, code: "promotion-source-tip-mismatch" };
}

function sameRepositoryPayload(base, head) {
  return {
    repository: { full_name: "example/repository" },
    pull_request: {
      base: { ref: base },
      head: { ref: head, repo: { full_name: "example/repository" } }
    }
  };
}

export function runSelfTest() {
  const policyCases = [
    ["temporary to nightly", true, "nightly", "feature/security-review"],
    ["nightly to stable", true, "stable", "nightly"],
    ["stable to release", true, "release", "stable"],
    ["stable to nightly", false, "nightly", "stable"],
    ["temporary to stable", false, "stable", "feature/security-review"],
    ["nightly to release", false, "release", "nightly"],
    ["temporary to retired main", false, "main", "feature/security-review"],
    ["retired main to nightly", false, "nightly", "main"]
  ];
  for (const [label, expected, base, head] of policyCases) {
    const result = evaluateBranchFlow({
      eventName: "pull_request",
      baseRef: base,
      headRef: head,
      payload: sameRepositoryPayload(base, head)
    });
    if (result.ok !== expected) throw new Error(`policy fixture failed: ${label}`);
  }
  const missingIdentity = evaluateBranchFlow({
    eventName: "pull_request",
    baseRef: "nightly",
    headRef: "agent/security-review",
    payload: {}
  });
  if (missingIdentity.ok) throw new Error("policy fixture failed: missing repository identity");
  const crossRepository = sameRepositoryPayload("nightly", "feature/security-review");
  crossRepository.pull_request.head.repo.full_name = "fork/repository";
  if (!evaluateBranchFlow({
    eventName: "pull_request",
    baseRef: "nightly",
    headRef: "feature/security-review",
    payload: crossRepository
  }).ok) throw new Error("policy fixture failed: fork source to nightly");
  crossRepository.pull_request.base.ref = "stable";
  crossRepository.pull_request.head.ref = "nightly";
  if (evaluateBranchFlow({
    eventName: "pull_request",
    baseRef: "stable",
    headRef: "nightly",
    payload: crossRepository
  }).ok) throw new Error("policy fixture failed: cross-repository promotion");
  const tips = { nightly: "nightly-tip", stable: "stable-tip", release: "release-tip" };
  const topologyCases = [
    ["temporary merge", true, "nightly", ["old-nightly", "feature-tip"]],
    ["nightly promotion", true, "stable", ["old-stable", "nightly-tip"]],
    ["stable promotion", true, "release", ["old-release", "stable-tip"]],
    ["direct commit", false, "nightly", ["old-nightly"]],
    ["wrong stable source", false, "stable", ["old-stable", "feature-tip"]],
    ["wrong release source", false, "release", ["old-release", "nightly-tip"]]
  ];
  for (const [label, expected, branch, commitParents] of topologyCases) {
    const result = verifyProtectedPushTopology({
      branch,
      before: commitParents[0],
      after: "after",
      commitParents: () => commitParents,
      branchTip: (name) => tips[name] || "",
      ancestor: (candidate, tip) => candidate === tip
    });
    if (result.ok !== expected) throw new Error(`topology fixture failed: ${label}`);
  }
  for (const [label, expected, branch, after] of [
    ["stable bootstrap", true, "stable", "nightly-tip"],
    ["release bootstrap", true, "release", "stable-tip"],
    ["wrong bootstrap", false, "release", "nightly-tip"],
    ["nightly bootstrap", false, "nightly", "nightly-tip"]
  ]) {
    const result = verifyProtectedPushTopology({
      branch,
      before: ZERO_OID,
      after,
      branchTip: (name) => tips[name] || ""
    });
    if (result.ok !== expected) throw new Error(`topology fixture failed: ${label}`);
  }
  return { fixtures: policyCases.length + topologyCases.length + 7 };
}

function readPayload(file) {
  if (!file) return {};
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function verifyCurrentEvent() {
  const payload = readPayload(process.env.GITHUB_EVENT_PATH);
  const result = evaluateBranchFlow({
    eventName: process.env.GITHUB_EVENT_NAME || "",
    refName: process.env.GITHUB_REF_NAME || "",
    baseRef: process.env.GITHUB_BASE_REF || "",
    headRef: process.env.GITHUB_HEAD_REF || "",
    payload
  });
  console[result.ok ? "log" : "error"](`[branch-flow] ${result.code}`);
  if (!result.ok) {
    process.exitCode = 1;
    return;
  }
  if (process.env.GITHUB_EVENT_NAME === "push") {
    const topology = verifyProtectedPushTopology({
      branch: process.env.GITHUB_REF_NAME || "",
      before: payload.before || "",
      after: payload.after || process.env.GITHUB_SHA || ""
    });
    console[topology.ok ? "log" : "error"](`[branch-flow] ${topology.code}`);
    if (!topology.ok) process.exitCode = 1;
  }
}

function main(argv) {
  if (argv.length === 0) return verifyCurrentEvent();
  if (argv.length === 1 && argv[0] === "--self-test") {
    const result = runSelfTest();
    console.log(`[branch-flow] ${result.fixtures} fixtures passed.`);
    return;
  }
  throw Object.assign(new Error("invalid invocation"), { code: "invalid-invocation" });
}

const invoked = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (invoked === import.meta.url) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(`[branch-flow] ${error?.code || "verification-failed"}`);
    process.exitCode = 1;
  }
}
