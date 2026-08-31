import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { evaluateBranchFlow, LONG_LIVED_BRANCHES } from "../../../tools/scripts/verify-branch-flow.mjs";

const readJson = (file) => JSON.parse(readFileSync(file, "utf8"));

test("LicoUp is one declarative Apple Release use case", () => {
  const config = readJson("tools/apple-release/macos-direct-arm64.json");
  assert.equal(config.schema, "apple-release.config.v1");
  assert.equal(config.source.branch, "release");
  assert.equal(config.candidate?.template, "release-candidate/v{version}");
  assert.ok(config.candidate?.requiredChecks?.length > 0);
  assert.equal(config.candidate?.mergeMethod, undefined);
  assert.equal(config.version.prepare, undefined);
  assert.equal(config.version.allowedPaths, undefined);
  assert.equal(config.apple.target, "macos-direct-arm64");
  assert.equal(config.github.repository, "LicoLand/LicoUp");
  assert.deepEqual(config.gates[0], ["npm", "ci"]);
  assert.deepEqual(config.build.command, [
    "env",
    "LICO_CLIENT_RELEASE_TRACK=stable",
    "npm",
    "run",
    "client:build:macos",
  ]);
  assert.deepEqual(config.update?.command, [
    "node",
    "tools/scripts/client-update-manifest.mjs",
    "--assets",
    "build/apple-release",
    "--tag",
    "{tag}",
    "--repo",
    "{repository}",
    "--targets",
    "macos-direct-arm64",
    "--release-track",
    "stable",
    "--minimum-supported-version",
    "0.0.0",
  ]);
  assert.deepEqual(config.artifacts.map(({ role, publicName }) => ({ role, publicName })), [
    { role: "installer", publicName: "LicoUp-macos-arm64.dmg" },
    { role: "installer-digest", publicName: "LicoUp-macos-arm64.dmg.sha256" },
    { role: "update-archive", publicName: "LicoUp-macos-arm64-update.zip" },
    { role: "update-digest", publicName: "LicoUp-macos-arm64-update.zip.sha256" },
    { role: "update-manifest", publicName: "LicoUp-update-manifest.json" },
  ]);
  assert.equal(JSON.stringify(config).includes("Apple-Release"), false);
  assert.equal(JSON.stringify(config).includes("../"), false);
});

test("Nightly publication is a second track profile of the same app identity", () => {
  const stable = readJson("tools/apple-release/macos-direct-arm64.json");
  const nightly = readJson("tools/apple-release/macos-direct-arm64-nightly.json");
  const template = readJson("tools/client-release-template.json");

  assert.equal(nightly.schema, "apple-release.config.v1");
  assert.equal(nightly.source.branch, "nightly");
  assert.equal(nightly.candidate?.template, "feature/nightly-publication-{version}");
  assert.deepEqual(nightly.gates, stable.gates);
  assert.deepEqual(nightly.build.command, [
    "env",
    "LICO_CLIENT_RELEASE_TRACK=nightly",
    "npm",
    "run",
    "client:build:macos",
  ]);
  assert.equal(nightly.apple.bundleIdentifier, stable.apple.bundleIdentifier);
  assert.equal(nightly.build.app, stable.build.app);
  assert.equal(nightly.github.tagTemplate, "nightly");
  assert.deepEqual(nightly.update?.command, [
    "node",
    "tools/scripts/client-update-manifest.mjs",
    "--assets",
    "build/apple-release",
    "--tag",
    "nightly",
    "--repo",
    "{repository}",
    "--targets",
    "macos-direct-arm64",
    "--release-track",
    "nightly",
    "--minimum-supported-version",
    "0.0.0",
  ]);
  assert.deepEqual(nightly.artifacts, stable.artifacts);
  assert.deepEqual(template.publication.profiles.nightly, {
    config: "tools/apple-release/macos-direct-arm64-nightly.json",
    sourceBranch: "nightly",
    releaseTrack: "nightly",
    tag: "nightly",
    mutablePrerelease: true,
  });
});

test("package commands expose the authority and stable release entries", () => {
  const scripts = readJson("package.json").scripts;
  assert.equal(scripts["client:release:macos"],
    "apple-release release start --config tools/apple-release/macos-direct-arm64.json");
  assert.equal(scripts["client:release:macos:publish"],
    "apple-release release start --config tools/apple-release/macos-direct-arm64.json --authorize");
  assert.equal(scripts["client:release:authority:configure"],
    "apple-release authority configure --config tools/apple-release/macos-direct-arm64.json");
  assert.equal(scripts["client:release:service:install"], undefined);
  assert.equal(scripts["client:release:service:configure"], undefined);
  assert.equal(scripts["client:release:service:status"], undefined);
  assert.equal(scripts["client:release:status"], "apple-release release status");
  assert.equal(scripts["client:promotion"], "node tools/scripts/client-promotion.mjs");
  const prePush = readFileSync(".githooks/pre-push", "utf8");
  assert.match(prePush, /repository-identity-policy\.mjs/u);
  assert.doesNotMatch(prePush, /client-pr-preflight\.mjs/u);
});

test("delegated publication leaves the protected release train unchanged", () => {
  assert.deepEqual(LONG_LIVED_BRANCHES, ["nightly", "stable", "release"]);
  const payload = { repository: { full_name: "LicoLand/LicoUp" },
    pull_request: { head: { repo: { full_name: "LicoLand/LicoUp" } } } };
  assert.equal(evaluateBranchFlow({ eventName: "pull_request", baseRef: "nightly",
    headRef: "codex/example", payload }).ok, true);
  assert.equal(evaluateBranchFlow({ eventName: "pull_request", baseRef: "stable",
    headRef: "nightly", payload }).ok, true);
  assert.equal(evaluateBranchFlow({ eventName: "pull_request", baseRef: "release",
    headRef: "stable", payload }).ok, true);
  assert.equal(evaluateBranchFlow({ eventName: "pull_request", baseRef: "release",
    headRef: "release-candidate/v1.2.3", payload }).ok, false);
});
