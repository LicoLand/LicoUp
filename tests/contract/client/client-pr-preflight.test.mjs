import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  deviceDemoPlatformsForTargets,
  parsePushUpdates,
  targetStages,
  validateReceipt,
  validateTemplate,
} from "../../../tools/scripts/client-pr-preflight.mjs";
import {
  stableLaunchSnapshots,
  validateMacosDmgLayout,
} from "../../../tools/scripts/client-macos-release-artifact-preflight.mjs";
import { updateCommandArgs } from "../../../tools/scripts/client-macos-update-preflight.mjs";
import {
  buildRulesets,
  requiredStatusContexts,
  rulesetPayloadMatches,
} from "../../../tools/scripts/repository-rulesets.mjs";
import {
  generatedAssetDecision,
  releaseStateDecision,
} from "../../../tools/scripts/client-github-release-publish.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const digest = `sha256:${"a".repeat(64)}`;
const sourceRevision = "b".repeat(40);
const sourceTree = "c".repeat(40);
const expected = {
  sourceRevision,
  sourceTree,
  version: "1.2.3",
  targets: ["macos-direct-arm64"],
  releaseTemplateDigest: digest,
};
const checkNames = [
  "candidateTreeClean", "workingDirectoryReady", "dependencyBootstrapReady",
  "commitIdentityReady", "githubIdentityReady", "branchFlowReady", "ancestryReady",
  "workflowBindingReady", "authoritativeStatusReady", "rulesetReady",
  "requiredChecksReady", "auditorReady", "sourceGatesReady",
  "selectedTargetGatesReady", "deviceDemoPassed", "selectedTargetBuilt", "archiveLayoutReady",
  "archiveDigestVerified", "stableReleaseIdentity", "nestedCodeIdentityUniform",
  "installedFromExactArtifact", "updatePathVerified", "launchStable",
  "draftReleaseContractReady", "releaseAssetSetReady", "remoteMutationFree",
];

function receipt() {
  return {
    schemaVersion: "licoup.release-pre-pr-receipt.v3",
    sourceRevision,
    sourceTree,
    version: "1.2.3",
    targets: ["macos-direct-arm64"],
    releaseTemplateDigest: digest,
    artifactDigests: { "macos-direct-arm64": digest },
    requiredPullRequestChecks: [
      "Branch flow", "Commit identity", "Client required", "Auditor",
    ],
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

test("release template binds one or more exact package targets", () => {
  const template = JSON.parse(readFileSync(
    path.join(repoRoot, "tools/client-release-template.json"), "utf8"));
  const packageJson = JSON.parse(readFileSync(path.join(repoRoot, "package.json"), "utf8"));
  assert.equal(validateTemplate(template, packageJson), true);
  const catalog = JSON.parse(readFileSync(
    path.join(repoRoot, "tools/client-release-targets.json"), "utf8"));
  assert.deepEqual(
    Object.keys(template.candidatePreflight.targets).sort(),
    catalog.targets.filter((target) => target.packageBuildSupported)
      .map((target) => target.id).sort(),
  );
  assert.equal(Object.keys(template.candidatePreflight.targets).length, 18);
});

test("dependency bootstrap is lockfile-exact without duplicate network audit", () => {
  const source = readFileSync(
    path.join(repoRoot, "tools/scripts/client-pr-preflight.mjs"),
    "utf8",
  );
  assert.match(source, /\["ci", "--no-audit", "--fund=false"\]/u);
  assert.match(source, /delete environment\.npm_config_allow_scripts/u);
});

test("receipt is strict, source-bound, and privacy-safe", () => {
  assert.equal(validateReceipt(receipt(), expected), true);
  for (const mutate of [
    (value) => { value.sourceRevision = "d".repeat(40); },
    (value) => { value.sourceTree = "e".repeat(40); },
    (value) => { value.version = "9.9.9"; },
    (value) => { value.targets = ["android-direct-arm64-v8a"]; },
    (value) => { value.releaseTemplateDigest = `sha256:${"f".repeat(64)}`; },
    (value) => { value.checks.updatePathVerified = false; },
    (value) => { value.privacy.identityMaterialIncluded = true; },
    (value) => { value.signerFingerprint = digest; },
  ]) {
    const candidate = structuredClone(receipt());
    mutate(candidate);
    assert.throws(() => validateReceipt(candidate, expected));
  }
});

test("pre-push parser is bounded and target stages include real closure", () => {
  const line = `refs/heads/release-candidate/v1.2.3-macos-arm64 ${sourceRevision} ` +
    `refs/heads/release-candidate/v1.2.3-macos-arm64 ${"0".repeat(40)}\n`;
  assert.equal(parsePushUpdates(line).length, 1);
  assert.throws(() => parsePushUpdates("malformed"));
  assert.deepEqual(
    targetStages("macos-direct-arm64").map(([id]) => id),
    [
      "distribution-preflight",
      "selected-target-build",
      "final-artifact",
      "update-path",
      "stage-package",
      "verify-package",
    ],
  );
});

test("release preflight runs each selected platform demo exactly once", () => {
  assert.deepEqual(deviceDemoPlatformsForTargets([
    "macos-direct-arm64",
    "macos-direct-x64",
    "android-direct-arm64-v8a",
    "windows-direct-x64",
    "android-play-arm64-v8a",
  ]), ["macos", "android", "windows"]);
  const source = readFileSync(
    path.join(repoRoot, "tools/scripts/client-pr-preflight.mjs"),
    "utf8",
  );
  assert.equal(
    source.match(/npmStage\(`device-demo-\$\{platform\}`, `client:demo:device:\$\{platform\}`/gu)
      ?.length,
    1,
  );
});

test("DMG and launch oracles reject extra entries and process replacement", () => {
  const canonicalLayout = [
    "Applications",
    "LicoUp License.txt",
    "LicoUp Open Source Notice.txt",
    "LicoUp Privacy Policy.html",
    "LicoUp.app",
    "Third-Party Notices.txt",
  ];
  assert.equal(validateMacosDmgLayout(
    canonicalLayout, "/Applications"), true);
  assert.throws(() => validateMacosDmgLayout(
    [...canonicalLayout, "outside.txt"], "/Applications"));
  assert.equal(stableLaunchSnapshots([[7], [7], [7, 8]]), true);
  assert.equal(stableLaunchSnapshots([[7], [8]]), false);
});

test("updater applies and rolls back through the real CLI surface", () => {
  const options = {
    manifestPath: "/fixture/manifest.json",
    publicKeysPath: "/fixture/keys.json",
    stagingRoot: "/fixture/staging",
    installRoot: "/fixture/install",
    currentVersion: "1.0.0",
    sourcePath: "/fixture/LicoUp.zip",
    guiPid: 7,
  };
  assert.equal(updateCommandArgs("download", options).includes("--source-path"), true);
  assert.equal(updateCommandArgs("apply", options).includes("--wait-for-script"), true);
  assert.equal(updateCommandArgs("rollback", options).includes("--wait-for-script"), true);
});

test("Rulesets require merge commits and the exact four checks", () => {
  assert.deepEqual(requiredStatusContexts,
    ["Branch flow", "Commit identity", "Client required", "Auditor"]);
  const rulesets = buildRulesets(1);
  assert.equal(rulesets.filter((ruleset) => ruleset.rules.some((rule) =>
    rule.type === "required_status_checks")).length, 1);
  assert.equal(rulesetPayloadMatches({ name: "x", extra: true }, { name: "x" }), true);
});

test("publication is idempotent and never overwrites conflicting assets", () => {
  assert.deepEqual(releaseStateDecision(null, sourceRevision, false),
    { createDraft: true, publish: false });
  assert.deepEqual(releaseStateDecision({
    targetCommitish: sourceRevision, isDraft: true,
  }, sourceRevision, true), { createDraft: false, publish: true });
  assert.deepEqual(releaseStateDecision({
    targetCommitish: sourceRevision, isDraft: false,
  }, sourceRevision, true), { createDraft: false, publish: false });
  assert.throws(() => releaseStateDecision({
    targetCommitish: sourceTree, isDraft: true,
  }, sourceRevision, false));
  assert.equal(generatedAssetDecision(null, digest), "upload");
  assert.equal(generatedAssetDecision(digest, digest), "reuse");
  assert.equal(generatedAssetDecision(digest, `sha256:${"d".repeat(64)}`), "reject");
});
