#!/usr/bin/env node

import { lstatSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { CLIENT_RELEASE_TARGETS } from "./client-gate-policy.mjs";
import { sha256File, stableReadFile } from "./lib/client-release-artifact-digest.mjs";
import {
  loadCatalog,
  validateCatalog,
  validateReleaseFreshness,
} from "./model-pricing-facts.mjs";
import {
  loadClientReleaseTargetCatalog,
  selectClientReleaseTargets,
} from "./lib/client-release-targets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const versionAuthority = JSON.parse(stableReadFile(
  path.join(repoRoot, "tools/client-version.json"), { maxBytes: 64 * 1024 },
));

function fail(message) { throw new Error(message); }

function validateReleasePricing() {
  const catalog = validateCatalog(loadCatalog(repoRoot));
  validateReleaseFreshness(catalog);
  return true;
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined ||
      result[flag.slice(2)] !== undefined) {
      fail("release workflow binding arguments are invalid");
    }
    result[flag.slice(2)] = value;
  }
  return result;
}

function selectedTargets(value, phase = "publish") {
  const targetIds = String(value || "").split(",");
  if (targetIds.length === 0 || targetIds.some((id) => !id || id !== id.trim()) ||
    new Set(targetIds).size !== targetIds.length) {
    fail("release workflow target selection is invalid");
  }
  const selected = selectClientReleaseTargets(
    loadClientReleaseTargetCatalog(), targetIds,
    {
      requireBuildSupported: phase === "prepare",
      requireReleaseSupported: phase === "publish",
    },
  );
  if (phase === "publish" && selected.some((target) => !CLIENT_RELEASE_TARGETS[target.id])) {
    fail("release workflow target selection is not publishable");
  }
  return selected;
}

function artifactDigests(value, targets) {
  let parsed;
  try { parsed = JSON.parse(String(value || "")); } catch { fail("artifact digests are invalid"); }
  const targetIds = targets.map((target) => target.id).sort();
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) ||
    JSON.stringify(Object.keys(parsed).sort()) !== JSON.stringify(targetIds) ||
    !Object.values(parsed).every((digest) => /^sha256:[a-f0-9]{64}$/u.test(digest))) {
    fail("artifact digests are not exact");
  }
  return parsed;
}

export function validateReleaseWorkflowRequest(request) {
  validateReleasePricing();
  const targets = selectedTargets(request.targets, request.phase);
  const expectedTag = `v${versionAuthority.productVersion}`;
  if (request.ref !== "refs/heads/release" || request.tag !== expectedTag ||
    !/^[a-f0-9]{64}$/u.test(request.correlation || "") ||
    !/^[a-f0-9]{40}$/u.test(request.sha || "") ||
    !["prepare", "publish"].includes(request.phase)) {
    fail("release workflow request is not authority-bound");
  }
  if (request.phase === "prepare") {
    if (request.sourceRevision || request.prepareRunId || request.artifactDigests ||
      request.signedManifestPresent !== "false") {
      fail("prepare request contains publish-only inputs");
    }
  } else {
    if (request.sourceRevision !== request.sha ||
      !/^[1-9][0-9]{0,19}$/u.test(request.prepareRunId || "")) {
      fail("publish request is not bound to its prepared source");
    }
    artifactDigests(request.artifactDigests, targets);
    const requiresSignedManifest = targets.some((target) =>
      target.update.kind === "signed-http-manifest");
    if (request.signedManifestPresent !== String(requiresSignedManifest)) {
      fail("publish request update manifest binding is invalid");
    }
  }
  return true;
}

export function validatePrepareRunBinding(run, expected) {
  const expectedTitle =
    `prepare ${expected.tag} ${expected.targets} ${expected.correlation}`;
  if (!run || typeof run !== "object" || String(run.id) !== expected.runId ||
    run.event !== "workflow_dispatch" || run.status !== "completed" ||
    run.conclusion !== "success" || run.head_branch !== "release" ||
    run.head_sha !== expected.sourceRevision ||
    run.path !== ".github/workflows/client-release.yml" ||
    run.display_title !== expectedTitle) {
    fail("prepare run metadata does not match the publish request");
  }
  return true;
}

function canonicalBuildDirectory(directory) {
  const resolved = path.resolve(repoRoot, directory || "");
  if (!resolved.startsWith(`${path.join(repoRoot, "build")}${path.sep}`) ||
    realpathSync(resolved) !== resolved) {
    fail("prepared artifact directory is invalid");
  }
  return resolved;
}

export function validatePreparedArtifacts(directory, targetValue, digestValue) {
  const root = canonicalBuildDirectory(directory);
  const targets = selectedTargets(targetValue, "prepare");
  const digests = artifactDigests(digestValue, targets);
  const rootEntries = readdirSync(root, { withFileTypes: true });
  if (rootEntries.some((entry) => !entry.isDirectory() || entry.isSymbolicLink()) ||
    JSON.stringify(rootEntries.map((entry) => entry.name).sort()) !==
      JSON.stringify(targets.map((target) => target.id).sort())) {
    fail("prepared target directory set is not exact");
  }
  for (const target of targets) {
    const targetRoot = canonicalBuildDirectory(path.join(root, target.id));
    const entries = readdirSync(targetRoot, { withFileTypes: true });
    const expectedFiles = [
      ...targets.find((candidate) => candidate.id === target.id).artifacts
        .map((artifact) => artifact.file),
      `LicoUp-${target.id}.package.json`,
    ].sort();
    if (entries.some((entry) => !entry.isFile() || entry.isSymbolicLink()) ||
      JSON.stringify(entries.map((entry) => entry.name).sort()) !==
        JSON.stringify(expectedFiles)) {
      fail("prepared artifact set is not exact");
    }
    for (const entry of entries) {
      const filePath = path.join(targetRoot, entry.name);
      const info = lstatSync(filePath);
      if (!info.isFile() || info.isSymbolicLink() || realpathSync(filePath) !== filePath) {
        fail("prepared artifact is not a canonical regular file");
      }
    }
    const installer = target.artifacts.find((artifact) =>
      artifact.role === "installer" || artifact.role === "submission")?.file;
    if (!installer || sha256File(path.join(targetRoot, installer), {
      maxBytes: 8 * 1024 * 1024 * 1024,
    }) !== digests[target.id]) {
      fail("prepared artifact digest does not match");
    }
  }
  return true;
}

export function releaseWorkflowMatrix(targetValue) {
  const targets = selectedTargets(targetValue, "prepare");
  return Object.freeze({
    include: Object.freeze(targets.map((target) => Object.freeze({
      target: target.id,
      artifactName: `licoup-${target.id}`,
      runner: [...target.builder.ciRunner],
      platform: target.platform,
      buildHost: target.buildHost,
      distributionFamily: target.distributionFamily,
      packageFormat: target.packageFormat,
      arch: target.arch,
    }))),
  });
}

function selfTest() {
  const correlation = "1".repeat(64);
  const sha = "2".repeat(40);
  const prepareTargets = "macos-direct-arm64,android-direct-arm64-v8a";
  const publishTargets = "android-direct-arm64-v8a";
  const digests = JSON.stringify({
    "android-direct-arm64-v8a": `sha256:${"4".repeat(64)}`,
  });
  validateReleaseWorkflowRequest({ phase: "prepare", tag: "v0.1.0", targets: prepareTargets,
    correlation, ref: "refs/heads/release", sha, sourceRevision: "",
    prepareRunId: "", artifactDigests: "", signedManifestPresent: "false" });
  validateReleaseWorkflowRequest({ phase: "publish", tag: "v0.1.0", targets: publishTargets,
    correlation, ref: "refs/heads/release", sha, sourceRevision: sha,
    prepareRunId: "7", artifactDigests: digests, signedManifestPresent: "false" });
  validatePrepareRunBinding({ id: 7, event: "workflow_dispatch", status: "completed",
    conclusion: "success", head_branch: "release", head_sha: sha,
    path: ".github/workflows/client-release.yml",
    display_title: `prepare v0.1.0 ${prepareTargets} ${correlation}` },
  { runId: "7", sourceRevision: sha, tag: "v0.1.0", targets: prepareTargets, correlation });
  const matrix = releaseWorkflowMatrix(prepareTargets);
  if (matrix.include.length !== 2) fail("release workflow matrix is not exact");
  process.stdout.write(`${JSON.stringify({ ok: true, caseCount: 4 })}\n`);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const mode = args.mode;
  if (mode === "self-test") return selfTest();
  if (mode === "matrix") {
    process.stdout.write(`${JSON.stringify(releaseWorkflowMatrix(args.targets))}\n`);
    return;
  }
  if (mode === "request") {
    validateReleaseWorkflowRequest({
      phase: args.phase, tag: args.tag, targets: args.targets,
      correlation: args.correlation, ref: args.ref, sha: args.sha,
      sourceRevision: args["source-revision"], prepareRunId: args["prepare-run-id"],
      artifactDigests: args["artifact-digests"],
      signedManifestPresent: args["signed-manifest-present"],
    });
  } else if (mode === "prepare-run") {
    const run = JSON.parse(stableReadFile(path.resolve(args["run-json"] || ""), {
      maxBytes: 256 * 1024,
    }));
    validatePrepareRunBinding(run, {
      runId: args["prepare-run-id"], sourceRevision: args["source-revision"],
      tag: args.tag, targets: args.targets, correlation: args.correlation,
    });
    validatePreparedArtifacts(args.artifacts, args.targets, args["artifact-digests"]);
  } else {
    fail("release workflow binding mode is invalid");
  }
  process.stdout.write(`${JSON.stringify({ ok: true, mode })}\n`);
}

if (process.argv[1] && import.meta.url ===
  pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(); } catch {
    process.stderr.write(`${JSON.stringify({ ok: false,
      code: "release_workflow_binding_invalid", privateDataIncluded: false })}\n`);
    process.exitCode = 1;
  }
}
