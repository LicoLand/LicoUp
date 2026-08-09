#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { sanitizeError } from "./lib/sanitize-error.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const templatePath = path.join(repoRoot, "tools/client-release-template.json");
const versionPath = path.join(repoRoot, "tools/client-version.json");
const receiptPath = path.join(repoRoot, "build/reports/release-pre-pr-receipt.json");
const receiptSchema = "licoup.release-pre-pr-receipt.v1";
const objectIdPattern = /^[a-f0-9]{40}(?:[a-f0-9]{24})?$/u;
const digestPattern = /^sha256:[a-f0-9]{64}$/u;
const targetPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;
const zeroObjectId = /^0+$/u;
const longLivedRefs = new Set([
  "refs/heads/nightly", "refs/heads/stable", "refs/heads/release",
]);
const requiredChecks = Object.freeze([
  "Branch flow", "Commit identity", "Client required", "Auditor",
]);
const checkNames = Object.freeze([
  "candidateTreeClean",
  "workingDirectoryReady",
  "dependencyBootstrapReady",
  "commitIdentityReady",
  "githubIdentityReady",
  "branchFlowReady",
  "ancestryReady",
  "workflowBindingReady",
  "authoritativeStatusReady",
  "rulesetReady",
  "requiredChecksReady",
  "auditorReady",
  "sourceGatesReady",
  "selectedTargetGatesReady",
  "selectedTargetBuilt",
  "archiveLayoutReady",
  "archiveDigestVerified",
  "stableReleaseIdentity",
  "nestedCodeIdentityUniform",
  "installedFromExactArtifact",
  "updatePathVerified",
  "launchStable",
  "draftReleaseContractReady",
  "releaseAssetSetReady",
  "remoteMutationFree",
]);
const receiptKeys = Object.freeze([
  "artifactDigest", "checks", "privacy", "releaseTemplateDigest",
  "requiredPullRequestChecks", "schemaVersion", "sourceRevision",
  "sourceTree", "target", "version",
]);
let lastFailureDetail = "";

class PreflightError extends Error {
  constructor(code) { super(code); this.code = code; }
}
function reject(code) { throw new PreflightError(code); }
function requireValue(value, code) { if (!value) reject(code); }

function exactKeys(value, keys) {
  return value && typeof value === "object" && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
}

function readJson(filePath, code = "audit_template_preflight_invalid") {
  try { return JSON.parse(readFileSync(filePath, "utf8")); } catch { reject(code); }
}

function sha256Bytes(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function run(command, args, code, timeout = 120_000, { input } = {}) {
  const environment = { ...process.env, GH_PROMPT_DISABLED: "1",
    LICO_RELEASE_PREFLIGHT_REMOTE_MUTATION: "forbidden" };
  if (command === "npm" && args[0] === "ci") {
    delete environment.npm_config_allow_scripts;
    delete environment.NPM_CONFIG_ALLOW_SCRIPTS;
  }
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env: environment,
    encoding: "utf8",
    stdio: [input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
    input,
    timeout,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    lastFailureDetail = sanitizeError(String(result.stderr || result.error?.message || ""))
      .replace(/\s+/gu, " ").trim().slice(0, 512);
    reject(code);
  }
  return String(result.stdout || "").trim();
}

function git(args, code = "audit_command_failed", options = {}) {
  return run("git", args, code, 180_000, options);
}

function stage(id, command, args, code, timeout = 2 * 60 * 60 * 1000) {
  process.stdout.write(`release_pre_pr_stage=running id=${id}\n`);
  run(command, args, code, timeout);
  process.stdout.write(`release_pre_pr_stage=passed id=${id}\n`);
}

function npmStage(id, script, code, timeout) {
  stage(id, "npm", ["run", script], code, timeout);
}

export function validateTemplate(template, packageJson) {
  requireValue(template?.schemaVersion === "licoup.client-release-template.v1",
    "audit_template_schema_invalid");
  const preflight = template.pullRequestPreflight;
  requireValue(preflight?.receiptSchema === receiptSchema &&
    preflight.receiptPath === "build/reports/release-pre-pr-receipt.json" &&
    preflight.remoteMutation === "forbidden" && preflight.prePushMode === "receipt-only",
  "audit_template_remote_mutation_policy_invalid");
  requireValue(JSON.stringify(template.requiredPullRequestChecks) === JSON.stringify(requiredChecks),
    "audit_template_required_checks_invalid");
  requireValue(JSON.stringify(template.promotion?.branches) ===
    JSON.stringify(["nightly", "stable", "release"]) &&
    template.promotion?.mergeMethod === "merge" &&
    template.promotion?.linearHistory === false &&
    template.promotion?.rulesetMutation === "forbidden",
  "audit_template_ruleset_policy_invalid");
  requireValue(packageJson?.scripts?.["client:pr:preflight"] ===
    "node tools/scripts/client-pr-preflight.mjs run",
  "audit_template_package_binding_invalid");
  return true;
}

function loadContract() {
  const bytes = readFileSync(templatePath);
  const template = JSON.parse(bytes.toString("utf8"));
  validateTemplate(template, readJson(path.join(repoRoot, "package.json")));
  return { template, digest: sha256Bytes(bytes) };
}

function candidateContext(target, contract) {
  requireValue(targetPattern.test(target) &&
    Object.hasOwn(contract.template.candidatePreflight.targets, target),
  "audit_target_unsupported");
  requireValue(git(["status", "--porcelain", "--untracked-files=all"]) === "",
    "audit_candidate_tree_not_clean");
  const sourceRevision = git(["rev-parse", "HEAD^{commit}"]);
  const sourceTree = git(["rev-parse", "HEAD^{tree}"]);
  requireValue(objectIdPattern.test(sourceRevision) && objectIdPattern.test(sourceTree),
    "audit_source_identity_invalid");
  const versionAuthority = readJson(versionPath, "audit_version_authority_invalid");
  const version = versionAuthority.productVersion;
  requireValue(versionAuthority.releaseTarget === target &&
    typeof version === "string" && version.length > 0,
  "audit_receipt_version_mismatch");
  const branch = git(["branch", "--show-current"]);
  requireValue(branch === `release-candidate/v${version.replace(/^v/u, "")}-${target}`,
    "audit_branch_flow_invalid");
  return { sourceRevision, sourceTree, version, target, branch };
}

function parseRunOptions(argv) {
  const options = { base: "origin/nightly", target: "", fullTarget: false };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--full-target") options.fullTarget = true;
    else if (value === "--base" || value === "--target") {
      requireValue(argv[index + 1], "audit_argument_invalid");
      options[value.slice(2)] = argv[index + 1];
      index += 1;
    } else reject("audit_argument_invalid");
  }
  requireValue(options.fullTarget && targetPattern.test(options.target),
    "audit_argument_invalid");
  return options;
}

function assertHost(target) {
  const allowed = {
    "macos-arm64": "darwin-arm64",
    "linux-glibc-arm64": "linux-arm64",
    "android-arm64": "darwin-arm64",
  };
  requireValue(allowed[target] === `${process.platform}-${process.arch}`,
    "audit_selected_target_build_failed");
}

function assertAncestry(base, sourceRevision) {
  const baseRevision = git(["rev-parse", "--verify", `${base}^{commit}`],
    "audit_ancestry_invalid");
  const result = spawnSync("git", ["merge-base", "--is-ancestor", baseRevision, sourceRevision], {
    cwd: repoRoot, stdio: "ignore", timeout: 30_000,
  });
  requireValue(result.status === 0, "audit_ancestry_invalid");
}

export function targetStages(target) {
  if (target === "macos-arm64") return Object.freeze([
    ["selected-target-build", "client:build:macos", "audit_selected_target_build_failed"],
    ["stable-release-identity", "client:install:macos:identity", "audit_release_identity_unstable"],
    ["final-archive", "client:archive:macos-github-release", "audit_archive_layout_invalid"],
    ["exact-install-launch", "client:verify:macos-release-artifact",
      "audit_installed_artifact_mismatch"],
    ["real-updater", "client:verify:macos-update-preflight", "audit_update_path_missing"],
  ]);
  if (target === "linux-glibc-arm64") return Object.freeze([
    ["selected-target-build", "client:build:linux", "audit_selected_target_build_failed"],
    ["final-archive", "client:archive:linux-arm64", "audit_archive_layout_invalid"],
    ["exact-install-launch", "client:linux:smoke", "audit_launch_unstable"],
  ]);
  if (target === "android-arm64") return Object.freeze([
    ["selected-target-build", "client:build:android", "audit_selected_target_build_failed"],
    ["final-artifact", "client:verify:android-apk", "audit_archive_layout_invalid"],
    ["exact-install-launch", "client:verify:android-physical-install-launch",
      "audit_launch_unstable"],
  ]);
  reject("audit_target_unsupported");
}

function artifactFacts(target) {
  if (target === "macos-arm64") {
    const report = readJson(path.join(repoRoot,
      "build/reports/client-macos-release-artifact-preflight.json"),
    "audit_installed_artifact_mismatch");
    requireValue(report.target === target && digestPattern.test(report.artifactDigest) &&
      report.archiveLayoutReady === true && report.archiveDigestVerified === true &&
      report.stableReleaseIdentity === true && report.nestedCodeIdentityUniform === true &&
      report.installedFromExactArtifact === true && report.launchStable === true,
    "audit_installed_artifact_mismatch");
    const update = readJson(path.join(repoRoot,
      "build/reports/client-macos-update-preflight.json"), "audit_update_path_missing");
    requireValue(update.target === target && update.updaterExecuted === true &&
      update.candidateApplied === true && update.failureRecoveryVerified === true &&
      ["bootstrap", "published-stable"].includes(update.baselineKind) &&
      update.baselineIdentityVerified === true && update.baselineLaunchVerified === true &&
      update.baselineRestored === true &&
      (update.baselineKind !== "bootstrap" || update.publishedStableClaimed === false),
    "audit_update_path_missing");
    return report.artifactDigest;
  }
  const targetFile = target === "android-arm64"
    ? "build/apps/desktop/android/release/LicoUp-android-arm64.apk"
    : "build/apps/desktop/distribution/linux-arm64/LicoUp-linux-arm64.tar.gz";
  return sha256Bytes(readFileSync(path.join(repoRoot, targetFile)));
}

function receiptFor(context, contract, artifactDigest) {
  return {
    schemaVersion: receiptSchema,
    sourceRevision: context.sourceRevision,
    sourceTree: context.sourceTree,
    version: context.version,
    target: context.target,
    releaseTemplateDigest: contract.digest,
    artifactDigest,
    requiredPullRequestChecks: [...requiredChecks],
    checks: Object.fromEntries(checkNames.map((name) => [name, true])),
    privacy: {
      redacted: true,
      absolutePathsIncluded: false,
      accountDataIncluded: false,
      credentialsIncluded: false,
      identityMaterialIncluded: false,
      rawOutputIncluded: false,
    },
  };
}

export function validateReceipt(receipt, expected) {
  requireValue(exactKeys(receipt, receiptKeys) && receipt.schemaVersion === receiptSchema,
    "audit_receipt_fields_invalid");
  const bindings = [
    ["sourceRevision", "audit_receipt_source_stale"],
    ["sourceTree", "audit_receipt_tree_stale"],
    ["version", "audit_receipt_version_mismatch"],
    ["target", "audit_receipt_target_mismatch"],
    ["releaseTemplateDigest", "audit_receipt_template_stale"],
  ];
  for (const [key, code] of bindings) requireValue(receipt[key] === expected[key], code);
  requireValue(digestPattern.test(receipt.artifactDigest), "audit_artifact_digest_invalid");
  if (expected.artifactDigest) {
    requireValue(receipt.artifactDigest === expected.artifactDigest,
      "audit_archive_digest_mismatch");
  }
  requireValue(JSON.stringify(receipt.requiredPullRequestChecks) === JSON.stringify(requiredChecks),
    "audit_required_checks_mismatch");
  requireValue(exactKeys(receipt.checks, checkNames) &&
    checkNames.every((name) => receipt.checks[name] === true),
  "audit_receipt_checks_invalid");
  requireValue(exactKeys(receipt.privacy, ["redacted", "absolutePathsIncluded",
    "accountDataIncluded", "credentialsIncluded", "identityMaterialIncluded",
    "rawOutputIncluded"]) && receipt.privacy.redacted === true &&
    Object.entries(receipt.privacy).every(([key, value]) => key === "redacted" || value === false),
  "audit_receipt_privacy_invalid");
  return true;
}

function writeReceipt(receipt) {
  mkdirSync(path.dirname(receiptPath), { recursive: true, mode: 0o700 });
  writeFileSync(receiptPath, `${JSON.stringify(receipt)}\n`, { mode: 0o600 });
}

function expectedReceiptContext(context, contract) {
  return {
    sourceRevision: context.sourceRevision,
    sourceTree: context.sourceTree,
    version: context.version,
    target: context.target,
    releaseTemplateDigest: contract.digest,
  };
}

function verifyExistingReceipt(target) {
  const contract = loadContract();
  const context = candidateContext(target, contract);
  validateReceipt(readJson(receiptPath, "audit_receipt_missing_or_invalid"), {
    ...expectedReceiptContext(context, contract),
    artifactDigest: artifactFacts(target),
  });
  process.stdout.write(`release_pre_pr_receipt=valid target=${target}\n`);
}

function execute(options) {
  const contract = loadContract();
  const context = candidateContext(options.target, contract);
  assertHost(options.target);
  assertAncestry(options.base, context.sourceRevision);
  npmStage("identity", "repo:identity:verify", "audit_commit_identity_mismatch");
  npmStage("ruleset-parity", "repo:rulesets:verify", "audit_ruleset_conflict");
  npmStage("auditor-contract", "client:pr:auditor", "audit_auditor_failed");
  stage("dependency-bootstrap", "npm", ["ci", "--no-audit", "--fund=false"],
    "audit_dependency_bootstrap_failed",
    20 * 60 * 1000);
  for (const lane of contract.template.candidatePreflight.targets[options.target]) {
    npmStage(`gate-${lane}`, `client:gate:${lane}`,
      lane === "source" ? "audit_source_gates_failed" : "audit_selected_target_gates_failed");
  }
  for (const [id, script, code] of targetStages(options.target)) npmStage(id, script, code);
  npmStage("release-api-contract", "client:verify:remote-release-assets:self-test",
    "audit_release_asset_set_invalid");
  const artifactDigest = artifactFacts(options.target);
  const receipt = receiptFor(context, contract, artifactDigest);
  writeReceipt(receipt);
  validateReceipt(receipt, expectedReceiptContext(context, contract));
  process.stdout.write(`${JSON.stringify({ ok: true, target: options.target,
    sourceBound: true, artifactBound: true, remoteMutationExecuted: false,
    privateDataIncluded: false })}\n`);
}

export function parsePushUpdates(input) {
  const updates = [];
  for (const line of String(input || "").split(/\r?\n/u)) {
    if (!line.trim()) continue;
    const fields = line.trim().split(/\s+/u);
    requireValue(fields.length === 4, "audit_branch_flow_invalid");
    const [localRef, localSha, remoteRef, remoteSha] = fields;
    requireValue(/^refs\/(?:heads|tags)\//u.test(localRef) &&
      /^refs\/(?:heads|tags)\//u.test(remoteRef) &&
      (objectIdPattern.test(localSha) || zeroObjectId.test(localSha)) &&
      (objectIdPattern.test(remoteSha) || zeroObjectId.test(remoteSha)),
    "audit_branch_flow_invalid");
    updates.push({ localRef, localSha, remoteRef, remoteSha });
  }
  return updates;
}

function hook(args) {
  requireValue(args.length >= 1 && args.length <= 2 && args[0] === "origin",
    "audit_branch_flow_invalid");
  for (const update of parsePushUpdates(readFileSync(0, "utf8"))) {
    if (zeroObjectId.test(update.localSha)) continue;
    requireValue(!longLivedRefs.has(update.remoteRef), "audit_branch_flow_invalid");
    if (!update.remoteRef.startsWith("refs/heads/release-candidate/")) continue;
    const version = JSON.parse(git(["show", `${update.localSha}:tools/client-version.json`],
      "audit_version_authority_invalid"));
    requireValue(version.releaseTarget, "audit_target_unsupported");
    verifyExistingReceipt(version.releaseTarget);
  }
}

function main() {
  const [mode, ...argv] = process.argv.slice(2);
  if (mode === "run") return execute(parseRunOptions(argv));
  if (mode === "receipt") {
    const options = parseRunOptions(argv);
    return verifyExistingReceipt(options.target);
  }
  if (mode === "check") {
    requireValue(argv.length === 0, "audit_argument_invalid");
    loadContract();
    process.stdout.write("release_pre_pr_contract=valid\n");
    return;
  }
  if (mode === "hook") return hook(argv);
  reject("audit_argument_invalid");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(); } catch (error) {
    const code = error instanceof PreflightError ? error.code : "audit_preflight_command_failed";
    process.stderr.write(`${JSON.stringify({ ok: false, code,
      detail: lastFailureDetail || undefined,
      remoteMutationExecuted: false, privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  }
}
