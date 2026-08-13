#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { classifyClientGatePaths } from "./client-gate-policy.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const templatePath = path.join(repoRoot, "tools/client-release-template.json");
const receiptSchema = "licoup.client-pr-preflight-receipt.v1";
const zeroObjectId = /^0+$/u;
const commitPattern = /^[a-f0-9]{40}$/u;
const targetPattern = /^[a-z0-9-]+$/u;
const allowedBranchPattern = /^(?:feature|fix|docs|refactor|test|chore|release-candidate)\//u;
const longLivedRefs = new Set([
  "refs/heads/nightly",
  "refs/heads/stable",
  "refs/heads/release",
]);
const maximumOutputBytes = 32 * 1024 * 1024;
const policyFiles = Object.freeze([
  ".githooks/pre-push",
  ".github/workflows/branch-flow.yml",
  ".github/workflows/client-ci.yml",
  ".github/workflows/client-release.yml",
  ".github/workflows/commit-identity.yml",
  ".github/workflows/lico-auditor-gate.yml",
  "package-lock.json",
  "package.json",
  "tools/client-release-template.json",
  "tools/scripts/client-auditor-preflight.mjs",
  "tools/scripts/client-gate-policy.mjs",
  "tools/scripts/client-gate.mjs",
  "tools/scripts/client-macos-local-identity-install.mjs",
  "tools/scripts/client-macos-release-artifact-preflight.mjs",
  "tools/scripts/client-pr-preflight.mjs",
  "tools/scripts/lib/macos-app-install.mjs",
  "tools/scripts/lib/macos-code-signature.mjs",
  "tools/scripts/lib/macos-release-identity.mjs",
  "tools/scripts/repository-identity-policy.mjs",
  "tools/scripts/repository-rulesets.mjs",
]);

class PreflightError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function reject(code) {
  throw new PreflightError(code);
}

function requireValue(condition, code) {
  if (!condition) reject(code);
}

function readJson(filePath) {
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    reject("preflight_contract_invalid");
  }
}

function runCaptured(command, args, {
  timeout = 120_000,
  input,
  allowFailure = false,
} = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
    input,
    timeout,
    maxBuffer: maximumOutputBytes,
  });
  if (!allowFailure && (result.error || result.status !== 0)) {
    reject("preflight_command_failed");
  }
  return {
    ok: !result.error && result.status === 0,
    stdout: String(result.stdout || "").trim(),
  };
}

function git(args, options = {}) {
  return runCaptured("git", args, options);
}

function runStage(id, command, args, timeout) {
  process.stdout.write(`preflight_stage=running id=${id}\n`);
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout,
    maxBuffer: maximumOutputBytes,
  });
  if (result.error || result.status !== 0) reject(`preflight_stage_${id}_failed`);
  process.stdout.write(`preflight_stage=passed id=${id}\n`);
}

function runPackageStage(id, script, timeout = 2 * 60 * 60 * 1000) {
  runStage(id, "npm", ["run", script], timeout);
}

function gitPath(relativePath) {
  const raw = git(["rev-parse", "--git-path", relativePath]).stdout;
  return path.resolve(repoRoot, raw);
}

function resolveCommit(ref, code) {
  const result = git(["rev-parse", "--verify", `${ref}^{commit}`], { allowFailure: true });
  if (!result.ok || !commitPattern.test(result.stdout)) reject(code);
  return result.stdout;
}

function headTree(headSha) {
  const tree = git(["rev-parse", `${headSha}^{tree}`]).stdout;
  if (!commitPattern.test(tree)) reject("preflight_head_tree_invalid");
  return tree;
}

function splitZeroSeparated(output) {
  return output ? output.split("\0").filter(Boolean) : [];
}

function committedChangedFiles(baseSha, headSha) {
  return splitZeroSeparated(git([
    "diff",
    "--name-only",
    "--diff-filter=ACMRTUXB",
    "-z",
    baseSha,
    headSha,
  ]).stdout);
}

function workingTreeChangedFiles(baseSha) {
  const tracked = splitZeroSeparated(git([
    "diff",
    "--name-only",
    "--diff-filter=ACMRTUXB",
    "-z",
    baseSha,
  ]).stdout);
  const untracked = splitZeroSeparated(git([
    "ls-files",
    "--others",
    "--exclude-standard",
    "-z",
  ]).stdout);
  return [...new Set([...tracked, ...untracked])].sort();
}

function versionAt({ headSha, workingTree }) {
  if (workingTree) return readJson(path.join(repoRoot, "tools/client-version.json"));
  const result = git(["show", `${headSha}:tools/client-version.json`], { allowFailure: true });
  if (!result.ok) reject("preflight_release_version_missing");
  try {
    return JSON.parse(result.stdout);
  } catch {
    reject("preflight_release_version_invalid");
  }
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function policyDigest() {
  const hash = createHash("sha256");
  for (const relativePath of policyFiles) {
    const absolutePath = path.join(repoRoot, relativePath);
    requireValue(existsSync(absolutePath), "preflight_policy_file_missing");
    hash.update(relativePath).update("\0").update(readFileSync(absolutePath)).update("\0");
  }
  return hash.digest("hex");
}

export function validatePreflightContract(template, packageJson) {
  const expectedGeneralChecks = [
    "candidate-tree-clean",
    "identity-policy",
    "workflow-paths-and-runner-bootstrap",
    "remote-ruleset-parity",
    "changed-source-and-platform-gates",
    "lico-auditor-profile",
    "selected-target-build",
    "stable-macos-release-identity",
    "nested-code-identity-uniformity",
    "exact-release-archive-install",
    "installed-artifact-launch-stability",
  ];
  requireValue(template?.schemaVersion === "licoup.client-release-template.v1",
    "preflight_template_schema_invalid");
  requireValue(template.pullRequestPreflight?.receiptSchema === receiptSchema &&
    template.pullRequestPreflight?.maximumReceiptAgeMinutes === 30 &&
    template.pullRequestPreflight?.command ===
      "npm run client:pr:preflight -- --base origin/nightly --target <target> --full-target" &&
    canonicalJson(template.pullRequestPreflight?.checks) === canonicalJson(expectedGeneralChecks),
  "preflight_check_contract_invalid");
  requireValue(canonicalJson(template.requiredPullRequestChecks) === canonicalJson([
    "Branch flow policy",
    "Commit identity",
    "Client required",
    "lico-auditor-gate",
  ]), "preflight_required_remote_checks_invalid");
  const scripts = packageJson?.scripts || {};
  const expectedScripts = {
    "client:pr:preflight": "node tools/scripts/client-pr-preflight.mjs run",
    "client:pr:preflight:check": "node tools/scripts/client-pr-preflight.mjs check",
    "client:pr:auditor": "node tools/scripts/client-auditor-preflight.mjs",
    "repo:rulesets:verify": "node tools/scripts/repository-rulesets.mjs verify",
    "client:verify:macos-release-artifact":
      "node tools/scripts/client-macos-release-artifact-preflight.mjs",
  };
  requireValue(Object.entries(expectedScripts).every(([name, command]) => scripts[name] === command),
    "preflight_package_binding_invalid");
  return true;
}

function loadContract() {
  const template = readJson(templatePath);
  const packageJson = readJson(path.join(repoRoot, "package.json"));
  validatePreflightContract(template, packageJson);
  return { template, packageJson };
}

function parseRunOptions(argv) {
  const options = {
    base: "origin/nightly",
    head: "HEAD",
    target: "",
    fullTarget: false,
    workingTree: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--full-target") {
      options.fullTarget = true;
    } else if (value === "--working-tree") {
      options.workingTree = true;
    } else if (["--base", "--head", "--target"].includes(value)) {
      if (index + 1 >= argv.length) reject("preflight_argument_missing");
      options[value.slice(2)] = argv[index + 1];
      index += 1;
    } else {
      reject("preflight_argument_invalid");
    }
  }
  requireValue(!options.target || targetPattern.test(options.target),
    "preflight_target_invalid");
  if (options.workingTree) {
    requireValue(options.head === "HEAD", "preflight_working_tree_head_invalid");
  }
  return options;
}

export function parsePushUpdates(input) {
  const updates = [];
  for (const line of String(input || "").split(/\r?\n/u)) {
    if (!line.trim()) continue;
    const fields = line.trim().split(/\s+/u);
    if (fields.length !== 4) reject("preflight_push_update_invalid");
    const [localRef, localSha, remoteRef, remoteSha] = fields;
    if (!/^refs\/(?:heads|tags)\//u.test(localRef) ||
      !/^refs\/(?:heads|tags)\//u.test(remoteRef) ||
      !commitPattern.test(localSha) && !zeroObjectId.test(localSha) ||
      !commitPattern.test(remoteSha) && !zeroObjectId.test(remoteSha)) {
      reject("preflight_push_update_invalid");
    }
    updates.push(Object.freeze({ localRef, localSha, remoteRef, remoteSha }));
  }
  return Object.freeze(updates);
}

function assertHostForTarget(target) {
  const host = `${process.platform}-${process.arch}`;
  const accepted = {
    "macos-arm64": ["darwin-arm64"],
    "linux-glibc-arm64": ["linux-arm64"],
    "android-arm64": ["darwin-arm64"],
  };
  requireValue(Array.isArray(accepted[target]) && accepted[target].includes(host),
    "preflight_target_host_invalid");
}

export function targetBuildStages(target) {
  if (target === "macos-arm64") {
    return Object.freeze([
      ["selected-target-build", "client:build:macos"],
      ["stable-macos-release-identity", "client:install:macos:identity"],
      ["selected-target-archive", "client:archive:macos-github-release"],
      ["exact-release-archive-install", "client:verify:macos-release-artifact"],
    ]);
  }
  if (target === "linux-glibc-arm64") {
    return Object.freeze([
      ["selected-target-build", "client:build:linux"],
      ["selected-target-archive", "client:archive:linux-arm64"],
      ["installed-artifact-launch-stability", "client:linux:smoke"],
    ]);
  }
  if (target === "android-arm64") {
    return Object.freeze([
      ["selected-target-build", "client:build:android"],
      ["selected-target-artifact-verification", "client:verify:android-apk"],
      ["installed-artifact-launch-stability", "client:verify:android-physical-install-launch"],
    ]);
  }
  reject("preflight_target_unsupported");
}

function receiptPath(headSha) {
  return gitPath(`licoup-pr-preflight-receipts/${headSha}.json`);
}

function receiptFacts({
  template,
  baseSha,
  headSha,
  target,
  fullTarget,
  lanes,
  checks,
}) {
  return {
    schemaVersion: receiptSchema,
    generatedAt: new Date().toISOString(),
    baseSha,
    headSha,
    headTree: headTree(headSha),
    target,
    fullTarget,
    lanes,
    checks,
    policyDigest: policyDigest(),
    maximumAgeMinutes: template.pullRequestPreflight.maximumReceiptAgeMinutes,
    privacy: {
      redacted: true,
      absolutePathsIncluded: false,
      rawLogsIncluded: false,
      credentialsIncluded: false,
    },
  };
}

function writeReceipt(facts) {
  const destination = receiptPath(facts.headSha);
  mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  writeFileSync(destination, `${JSON.stringify(facts)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
}

export function receiptMatches(receipt, expected, now = Date.now()) {
  const generatedAt = Date.parse(String(receipt?.generatedAt || ""));
  const maximumAgeMs = Number(expected.maximumAgeMinutes) * 60 * 1000;
  return receipt?.schemaVersion === receiptSchema &&
    Number.isFinite(generatedAt) && generatedAt <= now &&
    now - generatedAt <= maximumAgeMs &&
    receipt.baseSha === expected.baseSha &&
    receipt.headSha === expected.headSha &&
    receipt.headTree === expected.headTree &&
    receipt.target === expected.target &&
    receipt.fullTarget === expected.fullTarget &&
    canonicalJson(receipt.lanes) === canonicalJson(expected.lanes) &&
    canonicalJson(receipt.checks) === canonicalJson(expected.checks) &&
    receipt.policyDigest === expected.policyDigest &&
    receipt.privacy?.redacted === true &&
    receipt.privacy?.absolutePathsIncluded === false &&
    receipt.privacy?.rawLogsIncluded === false &&
    receipt.privacy?.credentialsIncluded === false;
}

function assertReceipt(expected) {
  let receipt;
  try {
    receipt = readJson(receiptPath(expected.headSha));
  } catch {
    reject("preflight_receipt_missing");
  }
  requireValue(receiptMatches(receipt, expected), "preflight_receipt_stale_or_mismatched");
}

function resolvedCandidate(options, template) {
  runCaptured("git", ["fetch", "--quiet", "origin", "nightly"], {
    timeout: 180_000,
  });
  const baseSha = resolveCommit(options.base, "preflight_base_invalid");
  const headSha = resolveCommit(options.head, "preflight_head_invalid");
  requireValue(git(["merge-base", "--is-ancestor", baseSha, headSha], {
    allowFailure: true,
  }).ok, "preflight_candidate_not_rebased");
  if (!options.workingTree) {
    requireValue(git(["status", "--porcelain", "-z"]).stdout === "",
      "preflight_candidate_tree_not_clean");
    requireValue(resolveCommit("HEAD", "preflight_head_invalid") === headSha,
      "preflight_head_not_checked_out");
  }
  const changedFiles = options.workingTree
    ? workingTreeChangedFiles(baseSha)
    : committedChangedFiles(baseSha, headSha);
  requireValue(changedFiles.length > 0, "preflight_candidate_empty");
  const branch = git(["branch", "--show-current"]).stdout;
  const releaseCandidate = branch.startsWith(template.candidatePreflight.refPrefix) ||
    changedFiles.includes("tools/client-version.json");
  const fullTarget = options.fullTarget || releaseCandidate;
  let target = options.target;
  if (fullTarget) {
    const version = versionAt({ headSha, workingTree: options.workingTree });
    target ||= String(version.releaseTarget || "");
    requireValue(target === version.releaseTarget, "preflight_release_target_mismatch");
    requireValue(Object.hasOwn(template.candidatePreflight.targets, target),
      "preflight_target_unsupported");
    assertHostForTarget(target);
    requireValue(branch.startsWith(template.candidatePreflight.refPrefix) || options.workingTree,
      "preflight_release_candidate_branch_invalid");
  }
  const plan = classifyClientGatePaths(changedFiles, { releaseTarget: target || null });
  const lanes = fullTarget
    ? [...template.candidatePreflight.targets[target]]
    : Object.entries(plan.lanes).filter(([, selected]) => selected).map(([lane]) => lane);
  const checks = [...template.pullRequestPreflight.checks];
  return { baseSha, headSha, changedFiles, fullTarget, target, lanes, checks };
}

function expectedReceipt(candidate, template) {
  return {
    ...candidate,
    headTree: headTree(candidate.headSha),
    policyDigest: policyDigest(),
    maximumAgeMinutes: template.pullRequestPreflight.maximumReceiptAgeMinutes,
  };
}

function runPreflight(options, { receiptOnly = false } = {}) {
  const { template } = loadContract();
  const candidate = resolvedCandidate(options, template);
  const expected = expectedReceipt(candidate, template);
  if (receiptOnly) {
    assertReceipt(expected);
    process.stdout.write(`client_pr_preflight=receipt-valid head=${candidate.headSha.slice(0, 12)}\n`);
    return candidate;
  }
  process.stdout.write("preflight_stage=passed id=candidate-tree-clean\n");
  runPackageStage("identity-policy", "repo:identity:verify", 180_000);
  runPackageStage("remote-ruleset-parity", "repo:rulesets:verify", 300_000);
  runStage(
    "lico-auditor-profile",
    process.execPath,
    candidate.fullTarget || !options.workingTree
      ? [
          "tools/scripts/client-auditor-preflight.mjs",
          "--base-sha",
          candidate.baseSha,
          "--head-sha",
          candidate.headSha,
        ]
      : ["tools/scripts/client-auditor-preflight.mjs", "--working-tree"],
    35 * 60 * 1000,
  );
  runStage("runner-bootstrap", "npm", ["ci"], 20 * 60 * 1000);
  for (const lane of candidate.lanes) {
    runPackageStage(
      lane === "source" ? "workflow-paths-and-runner-bootstrap" : `gate-${lane}`,
      `client:gate:${lane}`,
    );
  }
  process.stdout.write("preflight_stage=passed id=changed-source-and-platform-gates\n");
  if (candidate.fullTarget) {
    for (const [id, script] of targetBuildStages(candidate.target)) {
      runPackageStage(id, script);
      if (id === "stable-macos-release-identity") {
        process.stdout.write("preflight_stage=passed id=nested-code-identity-uniformity\n");
      }
      if (id === "exact-release-archive-install") {
        process.stdout.write("preflight_stage=passed id=installed-artifact-launch-stability\n");
      }
    }
  } else {
    process.stdout.write("preflight_stage=skipped id=selected-target-build reason=not-release-candidate\n");
  }
  if (!options.workingTree) {
    writeReceipt(receiptFacts({
      template,
      baseSha: candidate.baseSha,
      headSha: candidate.headSha,
      target: candidate.target,
      fullTarget: candidate.fullTarget,
      lanes: candidate.lanes,
      checks: candidate.checks,
    }));
  }
  process.stdout.write(
    `client_pr_preflight=passed mode=${options.workingTree ? "working-tree" : "committed"}` +
      ` changed_count=${candidate.changedFiles.length} policy_digest=${expected.policyDigest}\n`,
  );
  return candidate;
}

function hook(argv) {
  requireValue(argv.length >= 1 && argv.length <= 2, "preflight_hook_argument_invalid");
  const remoteName = argv[0];
  requireValue(remoteName === "origin", "preflight_push_remote_invalid");
  const updates = parsePushUpdates(readFileSync(0, "utf8"));
  for (const update of updates) {
    if (zeroObjectId.test(update.localSha)) continue;
    requireValue(!longLivedRefs.has(update.remoteRef), "preflight_direct_long_lived_push_forbidden");
    requireValue(update.remoteRef.startsWith("refs/heads/"), "preflight_push_ref_invalid");
    const branchName = update.remoteRef.slice("refs/heads/".length);
    requireValue(allowedBranchPattern.test(branchName), "preflight_push_branch_invalid");
    const target = branchName.startsWith("release-candidate/")
      ? String(versionAt({ headSha: update.localSha, workingTree: false }).releaseTarget || "")
      : "";
    const options = {
      base: "origin/nightly",
      head: update.localSha,
      target,
      fullTarget: Boolean(target),
      workingTree: false,
    };
    try {
      runPreflight(options, { receiptOnly: true });
    } catch (error) {
      if (!(error instanceof PreflightError) ||
        !["preflight_receipt_missing", "preflight_receipt_stale_or_mismatched"]
          .includes(error.code)) {
        throw error;
      }
      runPreflight(options);
    }
  }
}

function main() {
  const [mode, ...argv] = process.argv.slice(2);
  if (mode === "check") {
    requireValue(argv.length === 0, "preflight_argument_invalid");
    loadContract();
    process.stdout.write(`client_pr_preflight=valid policy_digest=${policyDigest()}\n`);
    return;
  }
  if (mode === "run") {
    runPreflight(parseRunOptions(argv));
    return;
  }
  if (mode === "receipt") {
    runPreflight(parseRunOptions(argv), { receiptOnly: true });
    return;
  }
  if (mode === "hook") {
    hook(argv);
    return;
  }
  reject("preflight_mode_invalid");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    const code = error instanceof PreflightError ? error.code : "preflight_failed";
    process.stderr.write(`LicoUp PR preflight: ${code}\n`);
    process.exitCode = 1;
  }
}
