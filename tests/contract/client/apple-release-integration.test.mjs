import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { evaluateBranchFlow, LONG_LIVED_BRANCHES } from "../../../tools/scripts/verify-branch-flow.mjs";

const readJson = (file) => JSON.parse(readFileSync(file, "utf8"));

test("LicoUp is one declarative Apple Release use case", () => {
  const config = readJson("tools/apple-release/macos-direct-arm64.json");
  assert.equal(config.schema, "apple-release.config.v1");
  assert.equal(config.source.branch, "release");
  assert.equal(config.candidate?.branch, "macos-release-candidate");
  assert.equal(config.candidate?.template, undefined);
  assert.ok(config.candidate?.requiredChecks?.length > 0);
  assert.equal(config.candidate?.mergeMethod, undefined);
  assert.equal(config.version.prepare, undefined);
  assert.equal(config.version.allowedPaths, undefined);
  assert.equal(config.apple.target, "macos-direct-arm64");
  assert.equal(config.github.repository, "LicoLand/LicoUp");
  assert.deepEqual(config.gates, [
    ["node", "tools/scripts/macos-release/gate-source.mjs"],
    ["node", "tools/scripts/macos-release/gate-release-policy.mjs"],
  ]);
  assert.deepEqual(config.build.command, ["node", "tools/scripts/macos-release/build.mjs"]);
  assert.deepEqual(config.update.command, ["node", "tools/scripts/macos-release/write-update-manifest.mjs",
    "--tag", "{tag}", "--repository", "{repository}", "--version", "{version}"]);
  assert.deepEqual(config.artifacts.map(({ role, publicName }) => ({ role, publicName })), [
    { role: "installer", publicName: "LicoUp-macos-arm64.dmg" },
    { role: "installer-digest", publicName: "LicoUp-macos-arm64.dmg.sha256" },
    { role: "update-archive", publicName: "LicoUp-macos-arm64-update.zip" },
    { role: "update-digest", publicName: "LicoUp-macos-arm64-update.zip.sha256" },
    { role: "update-manifest", publicName: "LicoUp-update-manifest.json" },
    { role: "independent-tool", publicName: "LicoUp-migrate-macos-arm64" },
    { role: "independent-tool-digest", publicName: "LicoUp-migrate-macos-arm64.sha256" },
  ]);
  assert.equal(JSON.stringify(config).includes("Apple-Release"), false);
  assert.equal(JSON.stringify(config).includes("../"), false);
  const tool = config.artifacts.find((entry) => entry.role === "independent-tool");
  assert.equal(tool.source, "build/apps/desktop/release-tools/macos/LicoUp-migrate-macos-arm64");
  assert.equal(tool.path, "build/apple-release/LicoUp-migrate-macos-arm64");
  assert.equal(tool.source.startsWith(`${config.build.app}/`), false);
  assert.equal(config.build.materials.some((entry) => entry.path === tool.source), false);
  // The publication authority owns a closed draft asset contract. The
  // independently released package payloads and their signed index are declared
  // in the client release template beside that draft, never inside it, and the
  // package index tool produces them outside the application bundle.
  const template = readJson("tools/client-release-template.json");
  assert.deepEqual(template.publication.independentPackageAssets, {
    payloadRoles: ["mcp-package-payload", "package-payload"],
    indexRole: "package-index",
    producer: "tools/scripts/client-release-package-index.mjs",
    clientDraftCarries: false,
    signedIndexRequired: true,
  });
  assert.deepEqual(template.publication.assetRoles,
    config.artifacts.map((entry) => entry.role));
  const independentRoles = [...template.publication.independentPackageAssets.payloadRoles,
    template.publication.independentPackageAssets.indexRole];
  for (const role of independentRoles) {
    assert.equal(config.artifacts.some((entry) => entry.role === role), false,
      `the client draft must not carry the independent package asset: ${role}`);
  }
  const packageTarget = readJson("tools/client-release-targets.json").targets
    .find((target) => target.id === "macos-direct-arm64");
  for (const role of independentRoles) {
    const declared = packageTarget.artifacts.filter((artifact) => artifact.role === role);
    assert.equal(declared.length, 1, `${role} must be declared once for its target`);
    assert.equal(declared[0].source.startsWith("build/apps/desktop/native-release/"), true);
    assert.equal(declared[0].source.startsWith(`${config.build.app}/`), false);
    assert.equal(config.build.materials.some((material) =>
      material.path === declared[0].source), false);
  }
});

test("Nightly publication is a second track profile of the same app identity", () => {
  const stable = readJson("tools/apple-release/macos-direct-arm64.json");
  const nightly = readJson("tools/apple-release/macos-direct-arm64-nightly.json");
  const template = readJson("tools/client-release-template.json");

  assert.equal(nightly.schema, "apple-release.config.v1");
  assert.equal(nightly.source.branch, "nightly");
  assert.equal(nightly.candidate?.branch, "macos-nightly-release-candidate");
  assert.equal(nightly.candidate?.template, undefined);
  assert.deepEqual(nightly.gates, [["npm", "ci"], ["npm", "run", "client:gate:source"], ["npm", "run", "client:gate:release-policy"]]);
  assert.deepEqual(nightly.build.command, [
    "env",
    "LICO_CLIENT_RELEASE_TRACK=nightly",
    "npm",
    "run",
    "client:build",
    "--",
    "--platform",
    "macos",
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

test("package commands expose the authority and both track release entries", () => {
  const scripts = readJson("package.json").scripts;
  assert.equal(scripts["client:release:macos"],
    "apple-release release start --config tools/apple-release/macos-direct-arm64.json");
  assert.equal(scripts["client:release:macos:publish"],
    "apple-release release start --config tools/apple-release/macos-direct-arm64.json --authorize");
  assert.equal(scripts["client:release:macos:nightly"],
    "apple-release release start --config tools/apple-release/macos-direct-arm64-nightly.json");
  assert.equal(scripts["client:release:macos:nightly:publish"],
    "apple-release release start --config tools/apple-release/macos-direct-arm64-nightly.json --authorize");
  assert.equal(scripts["client:release:authority:configure"],
    "apple-release authority configure --config tools/apple-release/macos-direct-arm64.json");
  assert.equal(scripts["client:release:service:install"], undefined);
  assert.equal(scripts["client:release:service:configure"], undefined);
  assert.equal(scripts["client:release:service:status"], undefined);
  assert.equal(scripts["client:release:status"], "apple-release release status");
  assert.equal(scripts["client:promotion"], "node tools/scripts/client-promotion.mjs");
  const prePush = readFileSync(".githooks/pre-push", "utf8");
  assert.match(prePush, /repository-identity-policy\.mjs/u);
});

test("delegated publication leaves the protected release train unchanged", () => {
  assert.deepEqual(LONG_LIVED_BRANCHES, ["nightly", "stable", "release"]);
  const payload = { repository: { full_name: "LicoLand/LicoUp" },
    pull_request: { head: { repo: { full_name: "LicoLand/LicoUp" } } } };
  assert.equal(evaluateBranchFlow({ eventName: "pull_request", baseRef: "nightly",
    headRef: "codex/example", payload }).ok, true);
  assert.equal(evaluateBranchFlow({ eventName: "pull_request", baseRef: "stable",
    headRef: "nightly-cutoff/2026-09-05", payload }).ok, true);
  assert.equal(evaluateBranchFlow({ eventName: "pull_request", baseRef: "stable",
    headRef: "nightly", payload }).ok, false);
  assert.equal(evaluateBranchFlow({ eventName: "pull_request", baseRef: "release",
    headRef: "stable", payload }).ok, true);
  assert.equal(evaluateBranchFlow({ eventName: "pull_request", baseRef: "release",
    headRef: "macos-release-candidate", payload }).ok, false);
});
