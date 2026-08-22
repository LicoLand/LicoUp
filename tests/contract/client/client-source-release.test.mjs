import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import {
  prepareSourceRelease,
  sourceReleaseIdentity,
  validateMergedStableEvent,
} from "../../../tools/scripts/client-source-release.mjs";

const revision = "a".repeat(40);
const repository = "LicoLand/LicoUp";

function event(overrides = {}) {
  return {
    action: "closed",
    pull_request: {
      merged: true,
      merge_commit_sha: revision,
      base: { ref: "release", repo: { full_name: repository } },
      head: { ref: "stable", sha: "b".repeat(40), repo: { full_name: repository } },
      ...overrides,
    },
  };
}

function git(workspace, args) {
  const result = spawnSync("git", args, {
    cwd: workspace,
    encoding: "utf8",
    shell: false,
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

test("source and later client binaries share one version tag and Release", () => {
  assert.deepEqual(sourceReleaseIdentity({ version: "1.2.3", build: 7, revision }), {
    version: "1.2.3",
    build: 7,
    revision,
    tag: "v1.2.3",
    title: "LicoUp 1.2.3",
    archiveName: "LicoUp-source-v1.2.3.tar.gz",
    digestName: "LicoUp-source-v1.2.3.tar.gz.sha256",
  });
});

test("only a merged same-repository stable-to-release pull request can publish source", () => {
  assert.equal(validateMergedStableEvent(event(), { repository, revision }), true);
  for (const invalid of [
    event({ merged: false }),
    event({ head: { ...event().pull_request.head, ref: "nightly" } }),
    event({ base: { ...event().pull_request.base, ref: "stable" } }),
    event({ merge_commit_sha: "c".repeat(40) }),
  ]) {
    assert.throws(() => validateMergedStableEvent(invalid, { repository, revision }),
      /source_release_event_invalid/u);
  }
});

test("workflow binds the package to the exact merged release commit and publishes two source assets", () => {
  const workflow = readFileSync(".github/workflows/client-source-release.yml", "utf8");
  assert.match(workflow, /types: \[closed\]/u);
  assert.match(workflow, /branches: \[release\]/u);
  assert.match(workflow, /head\.ref == 'stable'/u);
  assert.match(workflow, /pull_request\.merged == true/u);
  assert.match(workflow, /pull_request\.merge_commit_sha/u);
  assert.match(workflow, /permissions:\n  contents: write/u);
  assert.match(workflow, /client-source-release\.mjs prepare/u);
  assert.match(workflow, /client-source-release\.mjs publish/u);
  assert.doesNotMatch(workflow, /client:release:macos|apple-release|notarytool|codesign/u);
  assert.doesNotMatch(workflow, /source-v/u);
});

test("prepare archives the exact merge commit with the declared version and digest", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "licoup-source-release-"));
  const workspace = path.join(root, "repository");
  const eventPath = path.join(root, "event.json");
  try {
    mkdirSync(path.join(workspace, "tools"), { recursive: true });
    git(workspace, ["init", "--initial-branch=release"]);
    git(workspace, ["config", "user.name", "Source Release Test"]);
    git(workspace, ["config", "user.email", "source-release@example.invalid"]);
    writeFileSync(path.join(workspace, "tools", "client-version.json"),
      '{"productVersion":"1.2.3","buildNumber":7}\n');
    writeFileSync(path.join(workspace, "README.md"), "release base\n");
    git(workspace, ["add", "."]);
    git(workspace, ["commit", "-m", "release base"]);
    git(workspace, ["switch", "-c", "stable"]);
    writeFileSync(path.join(workspace, "SOURCE.txt"), "accepted source\n");
    git(workspace, ["add", "SOURCE.txt"]);
    git(workspace, ["commit", "-m", "accepted stable source"]);
    const stableRevision = git(workspace, ["rev-parse", "HEAD"]);
    git(workspace, ["switch", "release"]);
    git(workspace, ["merge", "--no-ff", "stable", "-m", "Merge stable into release"]);
    const mergeRevision = git(workspace, ["rev-parse", "HEAD"]);
    writeFileSync(eventPath, JSON.stringify(event({
      merge_commit_sha: mergeRevision,
      head: { ref: "stable", sha: stableRevision, repo: { full_name: repository } },
    })));

    const prepared = prepareSourceRelease({
      eventPath,
      repository,
      revision: mergeRevision,
      output: "build/source-release",
      workspace,
    });
    const archive = path.join(workspace, prepared.archive);
    const digest = path.join(workspace, prepared.digest);
    assert.equal(prepared.tag, "v1.2.3");
    assert.ok(readFileSync(archive).byteLength > 0);
    assert.match(readFileSync(digest, "utf8"),
      /^[a-f0-9]{64}  LicoUp-source-v1\.2\.3\.tar\.gz\n$/u);
    const listing = spawnSync("tar", ["-tzf", archive], {
      cwd: workspace,
      encoding: "utf8",
      shell: false,
    });
    assert.equal(listing.status, 0, listing.stderr);
    assert.match(listing.stdout, /LicoUp-1\.2\.3\/SOURCE\.txt/u);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
