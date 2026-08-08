#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { buildRulesets } from "./repository-rulesets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const templatePath = path.join(repoRoot, "tools", "client-release-template.json");

function fail(code) {
  throw Object.assign(new Error(code), { code });
}

function readJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function assert(condition, code) {
  if (!condition) fail(code);
}

function parseArgs(argv) {
  const options = { mode: "check", tag: "", target: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "check" || value === "run") {
      options.mode = value;
    } else if (value === "--tag" || value === "--target") {
      assert(index + 1 < argv.length, "release_preflight_argument_missing");
      options[value.slice(2)] = argv[index + 1];
      index += 1;
    } else {
      fail("release_preflight_argument_invalid");
    }
  }
  return options;
}

function currentBranch() {
  const result = spawnSync("git", ["branch", "--show-current"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  return result.status === 0 ? result.stdout.trim() : "";
}

function validateTemplate() {
  const template = readJson(templatePath);
  const version = readJson(path.join(repoRoot, "tools", "client-version.json"));
  assert(template.schemaVersion === "licoup.client-release-template.v1", "release_template_schema_invalid");
  assert(typeof template.entryCommands === "object", "release_entry_commands_invalid");
  assert(
    JSON.stringify(template.promotion?.branches) === JSON.stringify(["nightly", "stable", "release"]),
    "release_promotion_order_invalid",
  );
  assert(template.promotion?.mergeMethod === "merge", "release_promotion_merge_method_invalid");
  assert(template.promotion?.rulesetMutation === "forbidden", "release_ruleset_mutation_policy_invalid");
  assert(template.publication?.ref === "release", "release_publication_ref_invalid");
  assert(template.candidatePreflight?.refPrefix === "release-candidate/", "release_preflight_ref_prefix_invalid");
  assert(template.publication?.jobTimeoutPolicy === "github-default", "release_job_timeout_policy_invalid");
  assert(
    template.publication?.operatorMonitoringTimeoutMinutes === null,
    "release_monitoring_timeout_invalid",
  );
  assert(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(version.productVersion), "release_version_invalid");

  const workflowPath = path.join(repoRoot, template.publication.workflow || "");
  assert(existsSync(workflowPath), "release_workflow_missing");
  const workflow = readFileSync(workflowPath, "utf8");
  assert(!workflow.includes("timeout-minutes:"), "release_workflow_timeout_forbidden");
  assert(workflow.includes("npm run client:release:preflight:check"), "release_remote_preflight_missing");

  const [, , defaultRuleset, promotionRuleset] = buildRulesets(1);
  assert(
    !defaultRuleset.rules.some(({ type }) => type === "required_linear_history"),
    "release_nightly_linear_history_conflict",
  );
  const nightlyPullRequest = defaultRuleset.rules.find(({ type }) => type === "pull_request");
  assert(
    JSON.stringify(nightlyPullRequest?.parameters?.allowed_merge_methods) === JSON.stringify(["merge"]),
    "release_nightly_ruleset_merge_method_invalid",
  );
  assert(
    !promotionRuleset.rules.some(({ type }) => type === "required_linear_history"),
    "release_promotion_linear_history_conflict",
  );
  const pullRequest = promotionRuleset.rules.find(({ type }) => type === "pull_request");
  assert(
    JSON.stringify(pullRequest?.parameters?.allowed_merge_methods) === JSON.stringify(["merge"]),
    "release_promotion_ruleset_merge_method_invalid",
  );

  const targets = template.candidatePreflight?.targets;
  assert(targets && typeof targets === "object", "release_candidate_targets_missing");
  for (const [target, lanes] of Object.entries(targets)) {
    assert(/^[a-z0-9-]+$/u.test(target), "release_target_invalid");
    assert(Array.isArray(lanes) && lanes.length > 0, "release_candidate_lanes_missing");
    assert(new Set(lanes).size === lanes.length, "release_candidate_lanes_duplicated");
    assert(lanes[0] === "source" && lanes.at(-1) === "release-policy", "release_candidate_lane_order_invalid");
  }
  return { template, version };
}

function runStep(step) {
  const cwd = path.join(repoRoot, step.cwd || ".");
  const result = spawnSync(step.command, step.args, {
    cwd,
    env: process.env,
    encoding: step.stdoutFile ? "utf8" : undefined,
    stdio: step.stdoutFile ? ["ignore", "pipe", "inherit"] : "inherit",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) fail("release_preflight_command_failed");
  if (step.stdoutFile) {
    writeFileSync(path.join(cwd, step.stdoutFile), result.stdout, { encoding: "utf8", mode: 0o600 });
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const { template, version } = validateTemplate();
  if (options.mode === "check") {
    process.stdout.write("release_preflight=valid\n");
    return;
  }
  assert(options.tag === `v${version.productVersion}`, "release_preflight_tag_mismatch");
  assert(options.target === version.releaseTarget, "release_preflight_target_mismatch");
  assert(
    currentBranch().startsWith(template.candidatePreflight.refPrefix),
    "release_preflight_branch_invalid",
  );
  const lanes = template.candidatePreflight.targets[options.target];
  assert(lanes, "release_preflight_target_unsupported");
  for (const lane of lanes) runStep({ command: "npm", args: ["run", `client:gate:${lane}`] });
  process.stdout.write(`release_preflight=passed target=${options.target} tag=${options.tag}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`LicoUp release preflight: ${error?.code || "release_preflight_failed"}\n`);
  process.exitCode = 1;
}
