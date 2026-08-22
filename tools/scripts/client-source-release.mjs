#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  appendFileSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const revisionPattern = /^[a-f0-9]{40,64}$/u;
const versionPattern = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u;
const repositoryPattern = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;

function fail(code) {
  throw new Error(code);
}

function run(command, args, { cwd = repoRoot, capture = true } = {}) {
  const result = spawnSync(command, args, {
    cwd,
    env: process.env,
    encoding: "utf8",
    shell: false,
    stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) fail("source_release_command_failed");
  return String(result.stdout || "").trim();
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined || Object.hasOwn(values, flag.slice(2))) {
      fail("source_release_arguments_invalid");
    }
    values[flag.slice(2)] = value;
  }
  return values;
}

function containedOutput(value, workspace = repoRoot) {
  const buildRoot = path.join(workspace, "build");
  const output = path.resolve(workspace, value || "");
  if (output === buildRoot || !output.startsWith(`${buildRoot}${path.sep}`)) {
    fail("source_release_output_invalid");
  }
  return output;
}

export function sourceReleaseIdentity({ version, build, revision }) {
  if (!versionPattern.test(version || "") || !Number.isSafeInteger(build) || build < 1 ||
      !revisionPattern.test(revision || "")) fail("source_release_identity_invalid");
  const archiveName = `LicoUp-source-v${version}.tar.gz`;
  return Object.freeze({
    version,
    build,
    revision,
    tag: `v${version}`,
    title: `LicoUp ${version}`,
    archiveName,
    digestName: `${archiveName}.sha256`,
  });
}

export function validateMergedStableEvent(event, { repository, revision }) {
  const pullRequest = event?.pull_request;
  if (!repositoryPattern.test(repository || "") || !revisionPattern.test(revision || "") ||
      event?.action !== "closed" || pullRequest?.merged !== true ||
      pullRequest?.base?.ref !== "release" || pullRequest?.head?.ref !== "stable" ||
      pullRequest?.head?.repo?.full_name !== repository ||
      pullRequest?.base?.repo?.full_name !== repository ||
      pullRequest?.merge_commit_sha !== revision) fail("source_release_event_invalid");
  return true;
}

function verifyMergeCommit(workspace, revision, headRevision) {
  const parts = run("git", ["rev-list", "--parents", "-n", "1", revision], { cwd: workspace }).split(" ");
  if (parts.length !== 3 || parts[0] !== revision || parts[2] !== headRevision) {
    fail("source_release_merge_invalid");
  }
}

function sha256(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function writeOutputs(record, outputFile = process.env.GITHUB_OUTPUT) {
  if (!outputFile) return;
  appendFileSync(outputFile, [
    `version=${record.version}`,
    `tag=${record.tag}`,
    `title=${record.title}`,
    `archive=${record.archive}`,
    `digest=${record.digest}`,
  ].join("\n") + "\n", { encoding: "utf8", mode: 0o600 });
}

export function prepareSourceRelease({ eventPath, repository, revision, output, workspace = repoRoot }) {
  const event = JSON.parse(readFileSync(eventPath, "utf8"));
  validateMergedStableEvent(event, { repository, revision });
  const head = run("git", ["rev-parse", "HEAD"], { cwd: workspace });
  const dirty = run("git", ["status", "--porcelain=v1", "--untracked-files=all"], { cwd: workspace });
  if (head !== revision || dirty) fail("source_release_workspace_invalid");
  verifyMergeCommit(workspace, revision, event.pull_request.head.sha);

  const versionDocument = JSON.parse(readFileSync(path.join(workspace, "tools", "client-version.json"), "utf8"));
  const identity = sourceReleaseIdentity({
    version: versionDocument.productVersion,
    build: versionDocument.buildNumber,
    revision,
  });
  const outputRoot = containedOutput(output, workspace);
  rmSync(outputRoot, { recursive: true, force: true });
  mkdirSync(outputRoot, { recursive: true, mode: 0o700 });
  const archive = path.join(outputRoot, identity.archiveName);
  const digest = path.join(outputRoot, identity.digestName);
  run("git", ["archive", "--format=tar.gz", "-9", `--prefix=LicoUp-${identity.version}/`,
    `--output=${archive}`, revision], { cwd: workspace });
  const facts = lstatSync(archive);
  if (!facts.isFile() || facts.isSymbolicLink() || facts.size <= 0) fail("source_release_archive_invalid");
  writeFileSync(digest, `${sha256(archive)}  ${identity.archiveName}\n`, {
    encoding: "utf8",
    mode: 0o644,
    flag: "wx",
  });
  const record = Object.freeze({
    ok: true,
    version: identity.version,
    build: identity.build,
    revision,
    tag: identity.tag,
    title: identity.title,
    archive: path.relative(workspace, archive).split(path.sep).join("/"),
    digest: path.relative(workspace, digest).split(path.sep).join("/"),
    privateDataIncluded: false,
  });
  writeOutputs(record);
  return record;
}

export function publishSourceRelease({ repository, revision, tag, title, archive, digest,
  workspace = repoRoot }) {
  const versionDocument = JSON.parse(
    readFileSync(path.join(workspace, "tools", "client-version.json"), "utf8"),
  );
  const expected = sourceReleaseIdentity({
    version: versionDocument.productVersion,
    build: versionDocument.buildNumber,
    revision,
  });
  if (repository !== "LicoLand/LicoUp" || tag !== expected.tag || title !== expected.title ||
      path.basename(archive || "") !== expected.archiveName ||
      path.basename(digest || "") !== expected.digestName) fail("source_release_publication_invalid");
  for (const file of [archive, digest]) {
    const resolved = path.resolve(workspace, file);
    const facts = lstatSync(resolved, { throwIfNoEntry: false });
    if (!resolved.startsWith(`${path.join(workspace, "build", "source-release")}${path.sep}`) ||
        !facts?.isFile() || facts.isSymbolicLink() || facts.size <= 0) {
      fail("source_release_publication_invalid");
    }
  }
  if (run("git", ["rev-parse", "HEAD"], { cwd: workspace }) !== revision ||
      readFileSync(path.resolve(workspace, digest), "utf8") !==
        `${sha256(path.resolve(workspace, archive))}  ${expected.archiveName}\n`) {
    fail("source_release_publication_invalid");
  }
  run("gh", ["release", "create", tag, archive, digest, "--repo", repository, "--target", revision,
    "--title", title, "--notes", `apple-release-source:v1:${revision}`,
    "--latest=false"], { cwd: workspace, capture: false });
  return Object.freeze({ ok: true, tag, revision, assetCount: 2, privateDataIncluded: false });
}

export function main(argv = process.argv.slice(2)) {
  const [command, ...rest] = argv;
  const args = parseArgs(rest);
  if (command === "prepare") {
    return prepareSourceRelease({ eventPath: args.event, repository: args.repository,
      revision: args.revision, output: args.output });
  }
  if (command === "publish") {
    return publishSourceRelease({ repository: args.repository, revision: args.revision, tag: args.tag,
      title: args.title, archive: args.archive, digest: args.digest });
  }
  fail("source_release_command_invalid");
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.stdout.write(`${JSON.stringify(main())}\n`);
  } catch (error) {
    process.stderr.write(`${error?.message || "source_release_failed"}\n`);
    process.exitCode = 1;
  }
}
