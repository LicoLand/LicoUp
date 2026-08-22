import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import test from "node:test";

import { evaluateBranchFlow, LONG_LIVED_BRANCHES } from "../../../tools/scripts/verify-branch-flow.mjs";

const readJson = (file) => JSON.parse(readFileSync(file, "utf8"));

test("LicoUp is one declarative Apple Release use case", () => {
  const config = readJson("tools/apple-release/macos-direct-arm64.json");
  assert.equal(config.schema, "apple-release.config.v1");
  assert.equal(config.source.branch, "release");
  assert.deepEqual(Object.keys(config.candidate).sort(), ["branch", "requiredChecks"]);
  assert.equal(config.candidate.branch, "macos-release-candidate");
  assert.deepEqual(Object.keys(config.version).sort(), ["buildField", "file", "versionField"]);
  assert.equal(config.apple.target, "macos-direct-arm64");
  assert.equal(config.github.repository, "LicoLand/LicoUp");
  assert.deepEqual(config.gates[0], ["npm", "ci"]);
  assert.deepEqual(config.gates.slice(1), [
    ["node", "tools/scripts/macos-release/gate-source.mjs"],
    ["node", "tools/scripts/macos-release/gate-release-policy.mjs"],
  ]);
  assert.deepEqual(config.build.command, ["node", "tools/scripts/macos-release/build.mjs"]);
  assert.deepEqual(config.update.command, [
    "node",
    "tools/scripts/macos-release/write-update-manifest.mjs",
    "--tag",
    "{tag}",
    "--repository",
    "{repository}",
    "--version",
    "{version}",
  ]);
  assert.deepEqual(config.artifacts.map(({ role, publicName }) => ({ role, publicName })), [
    { role: "installer", publicName: "LicoUp-macos-arm64.dmg" },
    { role: "installer-digest", publicName: "LicoUp-macos-arm64.dmg.sha256" },
    { role: "update-archive", publicName: "LicoUp-macos-arm64-update.zip" },
    { role: "update-digest", publicName: "LicoUp-macos-arm64-update.zip.sha256" },
    { role: "update-manifest", publicName: "LicoUp-update-manifest.json" },
  ]);
  assert.equal(JSON.stringify(config).includes("../"), false);
});

test("Apple Release consumes only the complete dedicated LicoUp adapter", () => {
  const config = readJson("tools/apple-release/macos-direct-arm64.json");
  const commands = [...config.gates, config.build.command, config.update.command];
  const productCommands = commands.filter(([command]) => command === "node");
  assert.ok(productCommands.length > 0);
  for (const command of productCommands) {
    assert.match(command[1], /^tools\/scripts\/macos-release\/[a-z-]+\.mjs$/u);
  }
  assert.deepEqual(
    readdirSync("tools/scripts/macos-release")
      .filter((name) => name.endsWith(".mjs"))
      .sort(),
    [
      "build.mjs",
      "gate-release-policy.mjs",
      "gate-source.mjs",
      "write-update-manifest.mjs",
    ],
  );
  const readme = readFileSync("tools/scripts/macos-release/README.md", "utf8");
  assert.match(readme, /Apple Release is the sole authority/u);
  assert.match(readme, /LicoUp owns only product preparation/u);
  assert.match(readme, /Five-artifact contract/u);
});

test("package commands expose one Apple Release publication entry point and no service shim", () => {
  const scripts = readJson("package.json").scripts;
  assert.equal(scripts["client:release:macos"],
    "apple-release release start --config tools/apple-release/macos-direct-arm64.json");
  assert.equal(scripts["client:release:status"], "apple-release release status");
  assert.equal(Object.hasOwn(scripts, "client:release:service:install"), false);
  assert.equal(Object.hasOwn(scripts, "client:release:service:configure"), false);
  assert.equal(Object.hasOwn(scripts, "client:release:service:status"), false);
  assert.equal(
    Object.values(scripts).filter((command) => command.includes("apple-release release start")).length,
    1,
  );
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
    headRef: "macos-release-candidate", payload }).ok, false);
});
