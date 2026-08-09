#!/usr/bin/env node

import { lstatSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { CLIENT_RELEASE_TARGETS } from "./client-gate-policy.mjs";
import { sha256File, stableReadFile } from "./lib/client-release-artifact-digest.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const versionAuthority = JSON.parse(stableReadFile(
  path.join(repoRoot, "tools/client-version.json"), { maxBytes: 64 * 1024 },
));

function fail(message) { throw new Error(message); }

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined || result[flag.slice(2)] !== undefined) {
      fail("release workflow binding arguments are invalid");
    }
    result[flag.slice(2)] = value;
  }
  return result;
}

export function validateReleaseWorkflowRequest(request) {
  const expectedTag = `v${versionAuthority.productVersion}`;
  if (request.ref !== "refs/heads/release" ||
    request.tag !== expectedTag || request.target !== versionAuthority.releaseTarget ||
    !/^[a-f0-9]{64}$/u.test(request.correlation || "") ||
    !/^[a-f0-9]{40}$/u.test(request.sha || "") ||
    !["prepare", "publish"].includes(request.phase)) {
    fail("release workflow request is not authority-bound");
  }
  if (request.phase === "prepare") {
    if (request.sourceRevision || request.prepareRunId || request.artifactDigest ||
      request.signedManifestPresent !== "false") {
      fail("prepare request contains publish-only inputs");
    }
  } else if (request.sourceRevision !== request.sha ||
    !/^[1-9][0-9]{0,19}$/u.test(request.prepareRunId || "") ||
    !/^sha256:[a-f0-9]{64}$/u.test(request.artifactDigest || "") ||
    request.signedManifestPresent !== "true") {
    fail("publish request is not bound to its prepared source and artifact");
  }
  return true;
}

export function validatePrepareRunBinding(run, expected) {
  const expectedTitle = `prepare ${expected.tag} ${expected.target} ${expected.correlation}`;
  if (!run || typeof run !== "object" ||
    String(run.id) !== expected.runId || run.event !== "workflow_dispatch" ||
    run.status !== "completed" || run.conclusion !== "success" ||
    run.head_branch !== "release" || run.head_sha !== expected.sourceRevision ||
    run.path !== ".github/workflows/client-release.yml" ||
    run.display_title !== expectedTitle) {
    fail("prepare run metadata does not match the publish request");
  }
  return true;
}

export function validatePreparedArtifact(directory, target, expectedDigest) {
  const resolved = path.resolve(repoRoot, directory || "");
  if (!resolved.startsWith(`${path.join(repoRoot, "build")}${path.sep}`) ||
    realpathSync(resolved) !== resolved) fail("prepared artifact directory is invalid");
  const entries = readdirSync(resolved, { withFileTypes: true });
  const expectedFiles = [...CLIENT_RELEASE_TARGETS[target].files].sort();
  if (entries.some((entry) => !entry.isFile() || entry.isSymbolicLink()) ||
    JSON.stringify(entries.map((entry) => entry.name).sort()) !== JSON.stringify(expectedFiles)) {
    fail("prepared artifact set is not exact");
  }
  for (const entry of entries) {
    const filePath = path.join(resolved, entry.name);
    const info = lstatSync(filePath);
    if (!info.isFile() || info.isSymbolicLink() || realpathSync(filePath) !== filePath) {
      fail("prepared artifact is not a canonical regular file");
    }
  }
  const installer = CLIENT_RELEASE_TARGETS[target].installerArtifact;
  if (!installer || sha256File(path.join(resolved, installer), {
    maxBytes: 8 * 1024 * 1024 * 1024,
  }) !== expectedDigest) fail("prepared artifact digest does not match");
}

function selfTest() {
  const correlation = "1".repeat(64);
  const sha = "2".repeat(40);
  validateReleaseWorkflowRequest({ phase: "prepare", tag: "v0.1.0",
    target: "macos-arm64", correlation, ref: "refs/heads/release", sha,
    sourceRevision: "", prepareRunId: "", artifactDigest: "",
    signedManifestPresent: "false" });
  validateReleaseWorkflowRequest({ phase: "publish", tag: "v0.1.0",
    target: "macos-arm64", correlation, ref: "refs/heads/release", sha,
    sourceRevision: sha, prepareRunId: "7", artifactDigest: `sha256:${"3".repeat(64)}`,
    signedManifestPresent: "true" });
  validatePrepareRunBinding({ id: 7, event: "workflow_dispatch", status: "completed",
    conclusion: "success", head_branch: "release", head_sha: sha,
    path: ".github/workflows/client-release.yml",
    display_title: `prepare v0.1.0 macos-arm64 ${correlation}` },
  { runId: "7", sourceRevision: sha, tag: "v0.1.0", target: "macos-arm64", correlation });
  process.stdout.write(`${JSON.stringify({ ok: true, caseCount: 3 })}\n`);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const mode = args.mode;
  if (mode === "self-test") return selfTest();
  if (mode === "request") {
    validateReleaseWorkflowRequest({
      phase: args.phase, tag: args.tag, target: args.target,
      correlation: args.correlation, ref: args.ref, sha: args.sha,
      sourceRevision: args["source-revision"], prepareRunId: args["prepare-run-id"],
      artifactDigest: args["artifact-digest"],
      signedManifestPresent: args["signed-manifest-present"],
    });
  } else if (mode === "prepare-run") {
    const run = JSON.parse(stableReadFile(path.resolve(args["run-json"] || ""), {
      maxBytes: 256 * 1024,
    }));
    validatePrepareRunBinding(run, {
      runId: args["prepare-run-id"], sourceRevision: args["source-revision"],
      tag: args.tag, target: args.target, correlation: args.correlation,
    });
    validatePreparedArtifact(args.artifacts, args.target, args["artifact-digest"]);
  } else {
    fail("release workflow binding mode is invalid");
  }
  process.stdout.write(`${JSON.stringify({ ok: true, mode })}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(); } catch {
    process.stderr.write(`${JSON.stringify({ ok: false,
      code: "release_workflow_binding_invalid", privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  }
}
