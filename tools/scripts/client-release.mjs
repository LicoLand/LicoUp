#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const repository = "LicoLand/LicoUp";
const longLivedBranches = Object.freeze(["nightly", "stable", "release"]);
const upstream = Object.freeze({ nightly: "release-candidate", stable: "nightly", release: "stable" });
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
  return { ok: !result.error && result.status === 0, stdout: result.stdout?.trim() || "" };
}

function git(args, options) {
  return run("git", args, { capture: true, ...options });
}

function gh(args, options) {
  return run("gh", args, { capture: true, ...options });
}

function parseArgs(argv) {
  if (argv.length === 1 && argv[0] === "--self-test") return { selfTest: true };
  const [action, destination, ...rest] = argv;
  assert(action === "push" || action === "publish", "release_action_invalid");
  if (action === "push") assert(longLivedBranches.includes(destination), "release_destination_invalid");
  if (action === "publish") assert(destination === undefined || destination.startsWith("--"), "release_publish_argument_invalid");
  const args = action === "publish" ? [destination, ...rest].filter(Boolean) : rest;
  const options = { action, destination: action === "push" ? destination : "", version: "", target: "", publish: true };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    if (flag === "--draft") {
      options.publish = false;
    } else if (flag === "--version" || flag === "--target") {
      assert(index + 1 < args.length, "release_argument_missing");
      options[flag.slice(2)] = args[index + 1];
      index += 1;
    } else {
      fail("release_argument_invalid");
    }
  }
  assert(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(options.version), "release_version_invalid");
  assert(/^[a-z0-9-]+$/u.test(options.target), "release_target_invalid");
  if (action === "push") assert(!args.includes("--draft"), "release_push_argument_invalid");
  return options;
}

function loadJson(relativePath) {
  return JSON.parse(readFileSync(path.join(repoRoot, relativePath), "utf8"));
}

function validateContract() {
  const template = loadJson("tools/client-release-template.json");
  assert(template.schemaVersion === "licoup.client-release-template.v1", "release_template_invalid");
  assert(
    JSON.stringify(template.entryCommands) === JSON.stringify({
      nightly: "npm run client:release -- push nightly --version <version> --target <target>",
      stable: "npm run client:release -- push stable --version <version> --target <target>",
      release: "npm run client:release -- push release --version <version> --target <target>",
      publish: "npm run client:release -- publish --version <version> --target <target>",
    }),
    "release_entry_commands_invalid",
  );
  assert(
    JSON.stringify(template.promotion?.branches) === JSON.stringify(longLivedBranches),
    "release_promotion_order_invalid",
  );
  assert(template.promotion?.mergeMethod === "merge", "release_promotion_method_invalid");
  assert(template.promotion?.rulesetMutation === "forbidden", "release_ruleset_mutation_invalid");
  assert(template.publication?.operatorMonitoringTimeoutMinutes === null, "release_monitor_timeout_invalid");
  assert(typeof template.candidatePreflight?.targets === "object", "release_candidate_preflight_missing");
  assert(Array.isArray(template.candidatePreflight.targets["macos-arm64"]), "release_macos_preflight_missing");
  const supportedTargets = Object.keys(template.candidatePreflight.targets);
  assert(supportedTargets.length > 0, "release_targets_missing");
  assert(
    JSON.stringify(template.requiredPullRequestChecks) === JSON.stringify([
      "Branch flow policy", "Commit identity", "Client required",
    ]),
    "release_required_checks_invalid",
  );
  return template;
}

function assertRepository() {
  assert(gh(["api", "user", "--jq", ".login"]).stdout.length > 0, "release_github_auth_invalid");
  const origin = git(["remote", "get-url", "origin"]).stdout;
  assert(
    origin === "https://github.com/LicoLand/LicoUp.git" || origin === "git@github.com:LicoLand/LicoUp.git",
    "release_origin_invalid",
  );
}

function parseArray(value) {
  const parsed = JSON.parse(value || "[]");
  assert(Array.isArray(parsed), "release_github_response_invalid");
  return parsed;
}

function hasReleaseCommit(ref, version) {
  const subject = git(["log", "-1", "--format=%s", ref, "--", "tools/client-version.json"], { allowFailure: true });
  return subject.ok && subject.stdout === `Release v${version}`;
}

function releaseTargetAt(ref) {
  const manifest = git(["show", `${ref}:tools/client-version.json`], { allowFailure: true });
  if (!manifest.ok) return "";
  try { return JSON.parse(manifest.stdout).releaseTarget || ""; } catch { return ""; }
}

function hasTargetedRelease(ref, version, target) {
  return hasReleaseCommit(ref, version) && releaseTargetAt(ref) === target;
}

function changedFiles() {
  const unstaged = git(["diff", "--name-only", "-z"]).stdout;
  const staged = git(["diff", "--cached", "--name-only", "-z"]).stdout;
  return [...new Set(`${unstaged}\0${staged}`.split("\0").filter(Boolean))].sort();
}

function candidateBranch(version, target) {
  return `release-candidate/v${version}-${target}`;
}

function switchToCandidate(version, target) {
  const branch = candidateBranch(version, target);
  const initialBranch = git(["branch", "--show-current"]).stdout;
  const pending = changedFiles();
  const untracked = git(["ls-files", "--others", "--exclude-standard", "-z"]).stdout;
  assert(untracked === "", "release_worktree_untracked_files");
  if (pending.length > 0) {
    assert(initialBranch === branch, "release_worktree_not_clean");
    assert(pending.every((file) => versionFiles.includes(file)), "release_worktree_not_clean");
  }
  run("git", ["fetch", "origin", "nightly", "stable", "release"]);
  git(["fetch", "origin", branch], { allowFailure: true });
  const localExists = git(["show-ref", "--verify", `refs/heads/${branch}`], { allowFailure: true }).ok;
  const remoteExists = git(["show-ref", "--verify", `refs/remotes/origin/${branch}`], { allowFailure: true }).ok;
  if (localExists) {
    if (!remoteExists && !hasTargetedRelease(branch, version, target)) {
      if (pending.length > 0) {
        assert(git(["rev-parse", branch]).stdout === git(["rev-parse", "origin/nightly"]).stdout, "release_candidate_stale_branch_invalid");
      } else {
        assert(
          git(["merge-base", "--is-ancestor", branch, "origin/nightly"], { allowFailure: true }).ok,
          "release_candidate_stale_branch_invalid",
        );
        if (git(["branch", "--show-current"]).stdout === branch) {
          run("git", ["switch", "--detach", "origin/nightly"]);
        }
        run("git", ["branch", "--force", branch, "origin/nightly"]);
      }
    }
    run("git", ["switch", branch]);
  } else if (remoteExists) {
    run("git", ["switch", "--track", "-c", branch, `origin/${branch}`]);
  } else {
    run("git", ["switch", "-c", branch, "origin/nightly"]);
  }
  return branch;
}

function createReleaseCommit(options) {
  const manifest = loadJson("tools/client-version.json");
  if (changedFiles().length === 0) {
    run("npm", ["run", "client:version:set", "--", "--version", options.version, "--build-number", String(manifest.buildNumber + 1), "--target", options.target]);
  } else {
    assert(manifest.productVersion === options.version && manifest.releaseTarget === options.target, "release_prepared_candidate_invalid");
  }
  const allowed = new Set(versionFiles);
  const actual = changedFiles().sort();
  assert(actual.length > 0 && actual.every((file) => allowed.has(file)), "release_change_scope_invalid");
  run("npm", ["run", "repo:identity:install"]);
  run("git", ["add", "--", ...versionFiles]);
  run("git", ["commit", "-m", `Release v${options.version}`]);
}

function prepareCandidate(options) {
  const branch = switchToCandidate(options.version, options.target);
  if (!hasTargetedRelease("HEAD", options.version, options.target)) {
    assert(git(["rev-parse", "HEAD"]).stdout === git(["rev-parse", "origin/nightly"]).stdout, "release_candidate_base_invalid");
    createReleaseCommit(options);
  }
  assert(git(["status", "--porcelain"]).stdout === "", "release_candidate_not_clean");
  assert(git(["rev-list", "--count", "origin/nightly..HEAD"]).stdout === "1", "release_commit_count_invalid");
  run("npm", ["run", "client:release:preflight", "--", "--target", options.target, "--tag", `v${options.version}`]);
  run("git", ["push", "-u", "origin", `HEAD:refs/heads/${branch}`]);
  return branch;
}

async function waitForChecks(prNumber, requiredNames) {
  const required = new Set(requiredNames);
  const runEvents = new Map();
  while (true) {
    const checks = parseArray(gh([
      "pr", "checks", String(prNumber), "--repo", repository, "--json", "name,state,link",
    ], { allowFailure: true }).stdout || "[]");
    const selected = [];
    for (const check of checks) {
      if (!required.has(check.name)) continue;
      const runId = check.link?.match(/\/actions\/runs\/(\d+)(?:\/|$)/u)?.[1] || "";
      if (!runId) continue;
      if (!runEvents.has(runId)) {
        const response = gh([
          "run", "view", runId, "--repo", repository, "--json", "event", "--jq", ".event",
        ], { allowFailure: true });
        runEvents.set(runId, response.ok ? response.stdout : "");
      }
      if (["pull_request", "pull_request_target"].includes(runEvents.get(runId))) selected.push(check);
    }
    const grouped = new Map([...required].map((name) => [name, selected.filter((check) => check.name === name)]));
    if ([...grouped.values()].every((checksForName) => checksForName.length > 0)) {
      const states = [...grouped.values()].flat().map(({ state }) => state);
      const pending = states.some((state) => ["PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"].includes(state));
      const failed = states.some((state) => !["SUCCESS", "PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"].includes(state));
      if (failed) fail("release_pull_request_check_failed");
      if (!pending) return;
    }
    await new Promise((resolve) => setTimeout(resolve, 10000));
  }
}

function findPullRequest({ base, head, headSha = "" }) {
  const prs = parseArray(gh([
    "pr", "list", "--repo", repository, "--base", base, "--head", head,
    "--state", "all", "--json", "number,state,mergedAt,headRefOid",
  ]).stdout);
  return prs.find((candidate) => (!headSha || candidate.headRefOid === headSha) && (candidate.state === "OPEN" || candidate.mergedAt));
}

async function pushNightly(options, template) {
  run("git", ["fetch", "origin", "nightly"]);
  if (hasTargetedRelease("origin/nightly", options.version, options.target)) {
    process.stdout.write(`client_release=already_advanced destination=nightly version=${options.version}\n`);
    return;
  }
  const branch = prepareCandidate(options);
  let pr = findPullRequest({ base: "nightly", head: branch });
  if (!pr) {
    const url = gh([
      "pr", "create", "--repo", repository, "--base", "nightly", "--head", branch,
      "--title", `Release v${options.version} for ${options.target}`, "--body", `Automated ${options.target} release candidate. Only the selected target's local gates passed before this branch was pushed.`,
    ]).stdout;
    pr = { number: Number(url.split("/").at(-1)), mergedAt: null };
  }
  if (!pr.mergedAt) {
    await waitForChecks(pr.number, template.requiredPullRequestChecks);
    run("gh", ["pr", "merge", String(pr.number), "--repo", repository, "--merge", "--delete-branch"]);
  }
  process.stdout.write(`client_release=advanced destination=nightly version=${options.version}\n`);
}

async function pushPromotion(options, template) {
  const base = options.destination;
  const head = upstream[base];
  run("git", ["fetch", "origin", head, base]);
  if (hasTargetedRelease(`origin/${base}`, options.version, options.target)) {
    process.stdout.write(`client_release=already_advanced destination=${base} version=${options.version}\n`);
    return;
  }
  assert(hasTargetedRelease(`origin/${head}`, options.version, options.target), "release_promotion_source_version_mismatch");
  const headSha = git(["rev-parse", `origin/${head}`]).stdout;
  let pr = findPullRequest({ base, head, headSha });
  if (!pr) {
    const url = gh([
      "pr", "create", "--repo", repository, "--base", base, "--head", head,
      "--title", `Promote v${options.version} (${options.target}): ${head} to ${base}`,
      "--body", `Automated direct-branch promotion of the previously validated ${options.target} release candidate.`,
    ]).stdout;
    pr = { number: Number(url.split("/").at(-1)), mergedAt: null };
  }
  if (!pr.mergedAt) {
    await waitForChecks(pr.number, template.requiredPullRequestChecks);
    run("gh", ["pr", "merge", String(pr.number), "--repo", repository, "--merge"]);
  }
  process.stdout.write(`client_release=advanced destination=${base} version=${options.version}\n`);
}

async function publish(options, template) {
  if (gh(["release", "view", `v${options.version}`, "--repo", repository], { allowFailure: true }).ok) {
    process.stdout.write(`client_release=already_published version=${options.version} target=${options.target}\n`);
    return;
  }
  run("git", ["fetch", "origin", "release"]);
  assert(hasTargetedRelease("origin/release", options.version, options.target), "release_publication_source_version_mismatch");
  const releaseSha = git(["rev-parse", "origin/release"]).stdout;
  const existing = parseArray(gh([
    "run", "list", "--repo", repository, "--workflow", template.publication.workflow,
    "--event", "workflow_dispatch", "--branch", template.publication.ref,
    "--limit", "20", "--json", "databaseId,headSha,status",
  ]).stdout);
  let runId = existing.find(({ headSha, status }) => headSha === releaseSha && status !== "completed")?.databaseId || 0;
  if (!runId) {
    const before = new Set(existing.map(({ databaseId }) => databaseId));
    run("gh", [
      "workflow", "run", template.publication.workflow, "--repo", repository, "--ref", template.publication.ref,
      "-f", `release_tag=v${options.version}`, "-f", `target=${options.target}`,
      "-f", `publish_release=${options.publish}`,
    ]);
    while (!runId) {
      const runs = parseArray(gh([
        "run", "list", "--repo", repository, "--workflow", template.publication.workflow,
        "--event", "workflow_dispatch", "--branch", template.publication.ref,
        "--limit", "20", "--json", "databaseId,headSha",
      ]).stdout);
      runId = runs.find(({ databaseId, headSha }) => headSha === releaseSha && !before.has(databaseId))?.databaseId || 0;
      if (!runId) await new Promise((resolve) => setTimeout(resolve, 5000));
    }
  }
  run("gh", ["run", "watch", String(runId), "--repo", repository, "--exit-status", "--interval", "10"]);
  run("gh", ["release", "view", `v${options.version}`, "--repo", repository]);
  process.stdout.write(`client_release=published version=${options.version} target=${options.target}\n`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const template = validateContract();
  if (options.selfTest) {
    assert(upstream.stable === "nightly" && upstream.release === "stable", "release_upstream_map_invalid");
    assert(parseArgs(["push", "nightly", "--version", "1.2.3", "--target", "macos-arm64"]).destination === "nightly", "release_nightly_action_invalid");
    assert(parseArgs(["push", "stable", "--version", "1.2.3", "--target", "macos-arm64"]).destination === "stable", "release_stable_action_invalid");
    assert(parseArgs(["push", "release", "--version", "1.2.3", "--target", "macos-arm64"]).destination === "release", "release_release_action_invalid");
    assert(parseArgs(["publish", "--version", "1.2.3", "--target", "macos-arm64"]).action === "publish", "release_publish_action_invalid");
    process.stdout.write("client_release=self_test_passed\n");
    return;
  }
  assert(Object.hasOwn(template.candidatePreflight.targets, options.target), "release_target_unsupported");
  assertRepository();
  if (options.action === "publish") return publish(options, template);
  if (options.destination === "nightly") return pushNightly(options, template);
  return pushPromotion(options, template);
}

main().catch((error) => {
  process.stderr.write(`LicoUp release: ${error?.code || "release_failed"}\n`);
  process.exitCode = 1;
});
