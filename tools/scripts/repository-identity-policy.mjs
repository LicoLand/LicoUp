#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  lstatSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = fileURLToPath(new URL("../../", import.meta.url));
const zeroObjectId = /^0+$/u;
const githubLoginPattern = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/u;
const managedPolicyPaths = Object.freeze([
  ".githooks/pre-commit",
  ".githooks/commit-msg",
  ".githooks/pre-push",
  "tools/scripts/repository-identity-policy.mjs",
]);
const prohibitedAttributionTrailer =
  /(?:^|\r?\n)[ \t]*(?:co-authored-by|co-committed-by|signed-off-by|authored-by|assisted-by|generated-by|written-by|pair-programmed-by|contributed-by|reviewed-by|suggested-by|reported-by)[ \t]*:/iu;
const agentIdentityLine =
  /(?:^|\r?\n)[ \t]*(?:claude(?: code)?|cursor(?: agent)?|github copilot|copilot|codex|chatgpt|gemini|anthropic|openai|[^\r\n<]*(?:agent|bot))[^\r\n]*<[^\r\n>]+>/iu;
const forbiddenStagedPrefixes = Object.freeze([
  ".agents/",
  ".claude/",
  ".codex/",
  ".cursor/",
  ".kilo/",
  "docs/plans/",
  "docs/reports/",
  "scripts/local/",
  "skills/",
  "tools/local/",
]);

export class IdentityPolicyError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "IdentityPolicyError";
    this.code = code;
  }
}

function reject(code, message) {
  throw new IdentityPolicyError(code, message);
}

function run(command, args, options = {}) {
  try {
    return execFileSync(command, args, {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: [options.input === undefined ? "ignore" : "pipe", "pipe", "pipe"],
      input: options.input,
    }).trim();
  } catch {
    reject(options.code || "COMMAND_FAILED", options.message || "A required command failed.");
  }
}

function runOptional(command, args) {
  try {
    return execFileSync(command, args, {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
}

export function canonicalGitHubEmail(identity) {
  return `${identity.id}+${identity.login}@users.noreply.github.com`;
}

export function parseGitHubIdentity(raw) {
  const [login, id, ...extra] = raw.trim().split("\t");
  if (
    extra.length > 0 ||
    !githubLoginPattern.test(login || "") ||
    !/^[1-9][0-9]*$/u.test(id || "")
  ) {
    reject("GH_IDENTITY_INVALID", "GitHub returned an unusable account identity.");
  }
  return Object.freeze({ login, id });
}

function currentGitHubIdentity() {
  run("gh", ["auth", "status", "--active", "--hostname", "github.com"], {
    code: "GH_AUTH_REQUIRED",
    message: "GitHub CLI authentication is required.",
  });
  return parseGitHubIdentity(
    run("gh", ["api", "user", "--jq", '[.login, (.id | tostring)] | @tsv'], {
      code: "GH_IDENTITY_UNAVAILABLE",
      message: "The authenticated GitHub account could not be resolved.",
    }),
  );
}

function localGitConfig(key) {
  return runOptional("git", ["config", "--local", "--get", key]);
}

export function assertCommitMessage(message) {
  if (prohibitedAttributionTrailer.test(message)) {
    reject(
      "ATTRIBUTION_TRAILER_FORBIDDEN",
      "Attribution trailers are forbidden; the commit must have exactly one developer identity.",
    );
  }
  if (agentIdentityLine.test(message)) {
    reject(
      "AGENT_IDENTITY_FORBIDDEN",
      "An Agent-shaped identity line is forbidden in the commit message.",
    );
  }
}

export function assertCommitRecord(record, identity) {
  const expectedEmail = canonicalGitHubEmail(identity);
  if (record.authorName !== identity.login || record.authorEmail !== expectedEmail) {
    reject(
      "AUTHOR_IDENTITY_MISMATCH",
      "The commit Author must be the authenticated GitHub CLI developer.",
    );
  }
  if (record.committerName !== identity.login || record.committerEmail !== expectedEmail) {
    reject(
      "COMMITTER_IDENTITY_MISMATCH",
      "The commit Committer must be the authenticated GitHub CLI developer.",
    );
  }
  assertCommitMessage(record.message);
}

function assertConfiguredIdentity(identity) {
  const expectedEmail = canonicalGitHubEmail(identity);
  if (
    localGitConfig("user.name") !== identity.login ||
    localGitConfig("user.email") !== expectedEmail
  ) {
    reject(
      "LOCAL_IDENTITY_MISMATCH",
      "Repository Git identity does not match the authenticated GitHub CLI account. Run npm run repo:identity:install.",
    );
  }
}

function hashFile(relativePath) {
  const absolutePath = path.join(repoRoot, relativePath);
  const metadata = lstatSync(absolutePath, { throwIfNoEntry: false });
  if (!metadata || !metadata.isFile() || metadata.isSymbolicLink()) {
    reject("POLICY_FILE_INVALID", "A managed identity policy file is missing or unsafe.");
  }
  if (relativePath.startsWith(".githooks/") && (metadata.mode & 0o111) === 0) {
    reject("HOOK_NOT_EXECUTABLE", "A managed Git hook is not executable.");
  }
  return createHash("sha256").update(readFileSync(absolutePath)).digest("hex");
}

function gitPrivatePath(name) {
  const value = run("git", ["rev-parse", "--git-path", name], {
    code: "GIT_REPOSITORY_REQUIRED",
    message: "A Git repository is required.",
  });
  return path.resolve(repoRoot, value);
}

function policyManifestPath() {
  return gitPrivatePath("licoup-identity-policy.json");
}

function stagedReceiptPath() {
  return gitPrivatePath("licoup-identity-receipt.json");
}

function installPolicyManifest() {
  for (const relativePath of managedPolicyPaths) {
    if (relativePath.startsWith(".githooks/")) {
      chmodSync(path.join(repoRoot, relativePath), 0o755);
    }
  }
  const files = Object.fromEntries(
    managedPolicyPaths.map((relativePath) => [relativePath, hashFile(relativePath)]),
  );
  writeFileSync(
    policyManifestPath(),
    `${JSON.stringify({ schemaVersion: 1, files })}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
}

function assertInstalledPolicy() {
  if (localGitConfig("core.hooksPath") !== ".githooks") {
    reject(
      "HOOKS_PATH_INVALID",
      "The repository-controlled Git hooks are not enabled. Run npm run repo:identity:install.",
    );
  }
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(policyManifestPath(), "utf8"));
  } catch {
    reject("POLICY_MANIFEST_INVALID", "The local identity policy manifest is missing or invalid.");
  }
  if (manifest.schemaVersion !== 1 || typeof manifest.files !== "object") {
    reject("POLICY_MANIFEST_INVALID", "The local identity policy manifest is invalid.");
  }
  for (const relativePath of managedPolicyPaths) {
    if (manifest.files[relativePath] !== hashFile(relativePath)) {
      reject(
        "POLICY_FILE_MODIFIED",
        "A managed identity policy file changed after installation. Review it, then reinstall the policy.",
      );
    }
  }
}

function stagedPaths() {
  const output = run("git", [
    "diff",
    "--cached",
    "--name-only",
    "-z",
    "--diff-filter=ACMRTUXB",
  ]);
  return output ? output.split("\0").filter(Boolean) : [];
}

function assertStagedCandidate() {
  const paths = stagedPaths();
  if (paths.length === 0) {
    reject("EMPTY_STAGED_CANDIDATE", "There are no staged source changes to commit.");
  }
  for (const relativePath of paths) {
    const normalized = relativePath.replaceAll("\\", "/");
    if (forbiddenStagedPrefixes.some((prefix) => normalized.startsWith(prefix))) {
      reject("LOCAL_ONLY_PATH_STAGED", "A local-only path is staged for publication.");
    }
    const indexEntry = runOptional("git", ["ls-files", "-s", "--", relativePath]);
    if (!indexEntry.startsWith("120000 ")) continue;
    const target = run("git", ["show", `:${relativePath}`], {
      code: "STAGED_SYMLINK_UNREADABLE",
      message: "A staged symbolic link cannot be inspected.",
    });
    const normalizedTarget = target.replaceAll("\\", "/");
    if (
      path.posix.isAbsolute(normalizedTarget) ||
      normalizedTarget.split("/").includes("..")
    ) {
      reject("STAGED_SYMLINK_UNSAFE", "A staged symbolic link escapes the repository.");
    }
  }
}

function writeStagedReceipt() {
  const tree = run("git", ["write-tree"], {
    code: "STAGED_TREE_UNAVAILABLE",
    message: "The staged tree could not be materialized.",
  });
  writeFileSync(
    stagedReceiptPath(),
    `${JSON.stringify({ schemaVersion: 1, tree })}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
}

function assertStagedReceipt() {
  let receipt;
  try {
    receipt = JSON.parse(readFileSync(stagedReceiptPath(), "utf8"));
  } catch {
    reject("STAGED_RECEIPT_MISSING", "The pre-commit identity receipt is missing.");
  }
  const tree = run("git", ["write-tree"], {
    code: "STAGED_TREE_UNAVAILABLE",
    message: "The staged tree could not be materialized.",
  });
  if (receipt.schemaVersion !== 1 || receipt.tree !== tree) {
    reject("STAGED_TREE_CHANGED", "The staged tree changed after the pre-commit gate.");
  }
}

function readCommitRecord(commit) {
  const output = run(
    "git",
    ["show", "-s", "--format=%an%x00%ae%x00%cn%x00%ce%x00%B%x00", commit],
    {
      code: "COMMIT_UNREADABLE",
      message: "An outgoing commit could not be inspected.",
    },
  );
  const [authorName, authorEmail, committerName, committerEmail, message] =
    output.split("\0");
  if ([authorName, authorEmail, committerName, committerEmail, message].some((v) => v === undefined)) {
    reject("COMMIT_METADATA_INVALID", "An outgoing commit has invalid metadata.");
  }
  return { authorName, authorEmail, committerName, committerEmail, message };
}

function outgoingCommits(input, remoteName) {
  const commits = new Set();
  for (const line of input.split(/\r?\n/u)) {
    if (!line.trim()) continue;
    const fields = line.trim().split(/\s+/u);
    if (fields.length !== 4) {
      reject("PUSH_UPDATE_INVALID", "Git supplied an invalid push update.");
    }
    const [, localObjectId, , remoteObjectId] = fields;
    if (zeroObjectId.test(localObjectId)) continue;
    const args = ["rev-list", localObjectId];
    if (zeroObjectId.test(remoteObjectId)) {
      args.push("--not", `--remotes=${remoteName}`);
    } else {
      args.push(`^${remoteObjectId}`);
    }
    const result = run("git", args, {
      code: "OUTGOING_RANGE_UNAVAILABLE",
      message: "The complete outgoing commit range could not be inspected.",
    });
    for (const commit of result.split(/\r?\n/u).filter(Boolean)) commits.add(commit);
  }
  return [...commits];
}

function verifyLocalIdentityAndPolicy() {
  const identity = currentGitHubIdentity();
  assertConfiguredIdentity(identity);
  assertInstalledPolicy();
  return identity;
}

function install() {
  const identity = currentGitHubIdentity();
  run("git", ["config", "--local", "user.name", identity.login]);
  run("git", ["config", "--local", "user.email", canonicalGitHubEmail(identity)]);
  run("git", ["config", "--local", "core.hooksPath", ".githooks"]);
  installPolicyManifest();
  assertConfiguredIdentity(identity);
  assertInstalledPolicy();
  process.stdout.write("identity_policy=installed\n");
}

function preCommit() {
  verifyLocalIdentityAndPolicy();
  assertStagedCandidate();
  writeStagedReceipt();
}

function commitMessage(messagePath) {
  verifyLocalIdentityAndPolicy();
  assertStagedReceipt();
  let message;
  try {
    message = readFileSync(messagePath, "utf8");
  } catch {
    reject("COMMIT_MESSAGE_UNREADABLE", "The proposed commit message cannot be inspected.");
  }
  assertCommitMessage(message);
}

function prePush(remoteName) {
  const identity = verifyLocalIdentityAndPolicy();
  const input = readFileSync(0, "utf8");
  const commits = outgoingCommits(input, remoteName);
  for (const commit of commits) {
    assertCommitRecord(readCommitRecord(commit), identity);
  }
  process.stdout.write(`identity_policy=passed commits=${commits.length}\n`);
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  switch (command) {
    case "install":
      install();
      break;
    case "verify":
      verifyLocalIdentityAndPolicy();
      process.stdout.write("identity_policy=passed\n");
      break;
    case "pre-commit":
      preCommit();
      break;
    case "commit-msg":
      if (args.length !== 1) reject("USAGE", "commit-msg requires one message path.");
      commitMessage(args[0]);
      break;
    case "pre-push":
      if (args.length < 1) reject("USAGE", "pre-push requires a remote name.");
      prePush(args[0]);
      break;
    default:
      reject("USAGE", "Use install, verify, pre-commit, commit-msg, or pre-push.");
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    const code = error instanceof IdentityPolicyError ? error.code : "UNEXPECTED_FAILURE";
    const message =
      error instanceof IdentityPolicyError ? error.message : "The identity policy failed closed.";
    process.stderr.write(`LicoUp identity gate: ${code}: ${message}\n`);
    process.exitCode = 1;
  }
}
