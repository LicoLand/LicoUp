#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  readFileSync,
  rmSync,
  writeSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { CLIENT_MODULE_CATALOG } from "../regression/client-module-catalog.mjs";
import { executeClientModules } from "../regression/client-module-execution.mjs";
import {
  selectModulesForChangedPaths,
  selectModulesById,
  validateClientModuleCatalog,
} from "../regression/client-module-selection.mjs";
import {
  createClientRegressionReport,
  writeClientRegressionReport,
} from "../regression/client-regression-report.mjs";
import {
  CLIENT_CI_JOBS,
  CLIENT_GATE_LANES,
  CLIENT_GATE_SCHEMA_VERSION,
  CLIENT_RELEASE_TARGETS,
  classifyClientGatePaths,
} from "./client-gate-policy.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const verificationReportPath = path.join(
  repoRoot,
  "build/reports/client-module-regression.json",
);
const taskEventPrefix = "::lico-dev-task-event::";
const taskEventSchemaVersion = "v0.0.1:lico-dev:task-event-1";
const safeTaskEventValue = /^[a-z0-9][a-z0-9:._-]{0,127}$/u;
const forbiddenSourceTokens = Object.freeze([
  "dtolnay/rust-toolchain",
  "subosito/flutter-action",
  "sdkmanager",
  "apt-get",
  "gradlew",
  "cargo install",
  "npm run client:build",
  "client:package:",
  "client:install:",
  "client:run:",
  "client:verify:product-line-security",
  "gh release",
]);

function fail(message) {
  throw new Error(message);
}

export function clientGateTaskEvent({ type, stage, code, exitCode, retryable, recovery }) {
  if (!["step-start", "step-failure"].includes(type) || !safeTaskEventValue.test(stage ?? "")) {
    fail("client gate task event is invalid");
  }
  const event = {
    schemaVersion: taskEventSchemaVersion,
    type,
    stage,
    component: "client-gate",
  };
  if (type === "step-failure") {
    if (!safeTaskEventValue.test(code ?? "") || !Number.isInteger(exitCode) ||
        exitCode < -1 || exitCode > 255 || typeof retryable !== "boolean" ||
        !safeTaskEventValue.test(recovery ?? "")) {
      fail("client gate failure event is invalid");
    }
    Object.assign(event, { code, exitCode, retryable, recovery });
  }
  return `${taskEventPrefix}${JSON.stringify(event)}`;
}

function emitClientGateTaskEvent(event) {
  writeSync(2, `${clientGateTaskEvent(event)}\n`);
}

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), "utf8");
}

function readJson(relativePath) {
  return JSON.parse(readText(relativePath));
}

function assertIncludes(source, token, message) {
  if (!source.includes(token)) fail(message);
}

function assertExcludes(source, token, message) {
  if (source.includes(token)) fail(message);
}

function jobBlock(workflow, jobId) {
  const match = new RegExp(`^  ${jobId}:\\s*$`, "mu").exec(workflow);
  if (!match) fail(`workflow job is missing: ${jobId}`);
  const start = match.index;
  const remainder = workflow.slice(start + match[0].length);
  const next = remainder.search(/\n  [a-z0-9][a-z0-9-]*:\s*(?:\n|$)/u);
  return next < 0
    ? workflow.slice(start)
    : workflow.slice(start, start + match[0].length + next);
}

function inputBlock(workflow, inputId) {
  const match = new RegExp(`^      ${inputId}:\\s*$`, "mu").exec(workflow);
  if (!match) fail(`workflow input is missing: ${inputId}`);
  const start = match.index;
  const remainder = workflow.slice(start + match[0].length);
  const next = remainder.search(/\n      [a-z][a-z0-9_]*:\s*(?:\n|$)/u);
  return next < 0
    ? workflow.slice(start)
    : workflow.slice(start, start + match[0].length + next);
}

function validatePackageTopology() {
  const packageJson = readJson("package.json");
  const scripts = packageJson.scripts || {};
  const expectedGateCommands = {
    "client:gate:topology": "node tools/scripts/client-gate.mjs topology",
    "client:gate:self-test": "node --test tests/contract/client/client-gate-policy.test.mjs",
    "client:gate:plan": "node tools/scripts/client-gate.mjs plan",
    "client:gate:source": "node tools/scripts/client-gate.mjs run source",
    "client:gate:flutter": "node tools/scripts/client-gate.mjs run flutter",
    "client:gate:rust": "node tools/scripts/client-gate.mjs run rust",
    "client:gate:android": "node tools/scripts/client-gate.mjs run android",
    "client:gate:dependencies": "node tools/scripts/client-gate.mjs run dependencies",
    "client:gate:release-policy": "node tools/scripts/client-gate.mjs run release-policy",
    "client:gate:verify": "node tools/scripts/client-gate.mjs verify",
    "client:gate:step": "node tools/scripts/client-gate.mjs step",
  };
  for (const [script, expected] of Object.entries(expectedGateCommands)) {
    if (scripts[script] !== expected) {
      fail(`package.json must bind ${script} to its canonical gate command`);
    }
  }
  if (
    scripts["client:verify:agent-conversations:release-ready"] !==
    "node tests/product-e2e/cli/agent-conversations/support/reducer-facade.mjs --check --require-ready"
  ) {
    fail("package.json must bind the canonical conversation release-readiness gate");
  }
  const releaseCatalog = readJson("tools/client-release-targets.json");
  const deviceDemoPlatforms = [...new Set(releaseCatalog.targets
    .filter((target) => target.packageBuildSupported === true)
    .map((target) => target.platform))];
  if (scripts["client:demo:device:self-test"] !==
    "node tools/scripts/client-device-demo.mjs --self-test") {
    fail("package.json must bind the canonical real-device demo self-test");
  }
  for (const platform of deviceDemoPlatforms) {
    if (scripts[`client:demo:device:${platform}`] !==
      `node tools/scripts/client-device-demo.mjs --platform ${platform}`) {
      fail(`package.json must bind the canonical ${platform} real-device demo group`);
    }
  }
  const platformNamespace = new RegExp(
    `^client:demo:device:(?:${deviceDemoPlatforms.join("|")})(?::[a-z0-9-]+)*$`,
    "u",
  );
  for (const script of Object.keys(scripts).filter((name) =>
    name.startsWith("client:demo:device:") && name !== "client:demo:device:self-test")) {
    if (!platformNamespace.test(script)) {
      fail(`real-device demo command has no supported platform namespace: ${script}`);
    }
  }
  const realConversationToolTokens = [
    "client-agent-conversation-verify.mjs --release-ui",
    "client-agent-conversation-verify.mjs --live",
    "agent-conversations/cursor/conversation.test.mjs",
    "agent-conversations/codex/conversation.test.mjs",
    "agent-conversations/opencode/conversation.test.mjs",
    "agent-conversations/kimi-code/conversation.test.mjs",
    "agent-conversations/claude-code/conversation.test.mjs",
    "agent-conversations/antigravity/conversation.test.mjs",
    "agent-conversations/support/gates/codex-parity.mjs",
  ];
  for (const [script, command] of Object.entries(scripts)) {
    const runsRealConversation = realConversationToolTokens.some((token) =>
      command.includes(token)) ||
      (command.includes("client-agent-conversation-product-e2e.mjs") &&
        !command.includes("--self-test"));
    if (runsRealConversation && !platformNamespace.test(script)) {
      fail(`real conversation tool must stay inside a platform device demo group: ${script}`);
    }
  }
  for (const [lane, laneScripts] of Object.entries(CLIENT_GATE_LANES)) {
    for (const script of laneScripts) {
      if (!scripts[script]) {
        fail(`client gate lane ${lane} references missing package script ${script}`);
      }
      if (
        script.startsWith("client:demo:device:") &&
        script !== "client:demo:device:self-test"
      ) {
        fail(`ordinary client gate lane ${lane} must not run a real-device demo`);
      }
    }
  }
  const sourceCommands = CLIENT_GATE_LANES.source
    .map((script) => scripts[script])
    .join("\n");
  for (const token of forbiddenSourceTokens) {
    assertExcludes(
      sourceCommands,
      token,
      `source gate must not invoke platform toolchain or release token: ${token}`,
    );
  }
}

function validateCiTopology() {
  const workflow = readText(".github/workflows/client-ci.yml");
  for (const job of CLIENT_CI_JOBS) jobBlock(workflow, job);
  const plan = jobBlock(workflow, "plan");
  const engineering = jobBlock(workflow, "engineering");
  for (const token of [
    "github.event.pull_request.base.sha",
    "github.event.pull_request.head.sha",
    "readme-fast-path.mjs classify",
    "readme_fast: ${{ steps.readme.outputs.readme_fast }}",
    "target_darwin: ${{ steps.plan.outputs.target_darwin }}",
    "target_win32: ${{ steps.plan.outputs.target_win32 }}",
  ]) {
    assertIncludes(plan, token, `CI README classifier is missing: ${token}`);
  }
  assertIncludes(plan, "steps.readme.outputs.readme_fast != 'true'",
    "ordinary client planning must be inverse to README fast selection");
  assertExcludes(plan, "readme-fast-path.mjs verify",
    "Client required must not repeat the Auditor privacy scan");
  for (const token of forbiddenSourceTokens) {
    assertExcludes(plan, token, `CI plan job must not contain ${token}`);
  }
  for (const token of [
    "npm run client:gate:verify",
    "--execution direct --host linux",
    "ref: ${{ github.event.pull_request.head.sha || github.sha }}",
    "LICO_AUDITOR_GATE_DELEGATED",
    "cargo install cargo-audit --version 0.22.2 --locked",
    "node tools/scripts/client-android-sdk-bootstrap.mjs",
  ]) {
    assertIncludes(engineering, token, `complete CI engineering profile is missing: ${token}`);
  }
  for (const [job, host] of [["target-darwin", "darwin"], ["target-win32", "win32"]]) {
    const block = jobBlock(workflow, job);
    assertIncludes(block, `needs.plan.outputs.target_${host}`,
      `${job} must be selected from the catalog target ownership`);
    assertIncludes(block, "npm run client:gate:verify",
      `${job} must invoke the canonical client gate`);
    assertIncludes(block, `--execution target --host ${host}`,
      `${job} must bind evidence to its actual target host`);
    assertIncludes(block, "ref: ${{ github.event.pull_request.head.sha || github.sha }}",
      `${job} must check out the exact candidate head`);
  }
  const required = jobBlock(workflow, "client-required");
  assertIncludes(
    required,
    "needs: [plan, engineering, target-darwin, target-win32]",
    "required CI reducer must observe the complete profile and affected targets",
  );
  assertIncludes(required, "if: always()", "required CI reducer must always report lane failures");
  for (const token of [
    "PLAN_RESULT",
    "README_FAST_SELECTED",
    "ENGINEERING_RESULT",
    "TARGET_DARWIN_RESULT",
    "TARGET_WIN32_RESULT",
    "An ordinary client gate ran for an author README update",
    "README path selection was ambiguous",
  ]) {
    assertIncludes(required, token, `required CI reducer is missing: ${token}`);
  }
  for (const forbidden of [
    "npm run client:build",
    "client:archive:",
    "client:package:",
    "client:install:",
    "client:run:",
      "client:verify:product-line-security",
    "gh release",
  ]) {
    assertExcludes(workflow, forbidden, `client CI must not perform release target work: ${forbidden}`);
  }
}

function validatePromotionTopology() {
  const stable = readText(".github/workflows/client-stable.yml");
  const stablePlan = jobBlock(stable, "readme-plan");
  const stableRequired = jobBlock(stable, "stable-client");
  if (JSON.stringify(workflowJobIds(stable)) !==
    JSON.stringify(["readme-plan", "stable-client"])) {
    fail("stable promotion workflow must keep one classifier and one required check");
  }
  assertIncludes(stable, "branches:\n      - stable",
    "stable promotion workflow must target stable");
  for (const token of [
    "name: Stable client",
    "needs: readme-plan",
    "macos-15",
    "ubuntu-24.04",
    "HEAD_REPOSITORY: ${{ github.event.pull_request.head.repo.full_name }}",
    "TARGET_REPOSITORY: ${{ github.repository }}",
    'test "$HEAD_REPOSITORY" = "$TARGET_REPOSITORY"',
    'case "$HEAD_BRANCH" in nightly-cutoff/????-??-??) ;; *) exit 1 ;; esac',
    'test "$(uname -m)" = arm64',
    "LICO_CLIENT_RELEASE_TARGETS: macos-arm64",
    "npm run client:build -- --platform macos",
    "npm run client:install:macos -- --launch-installed --verify-stable",
  ]) {
    assertIncludes(stable, token, `stable promotion is missing: ${token}`);
  }
  for (const token of [
    "readme-fast-path.mjs classify",
    "readme_fast: ${{ steps.readme.outputs.readme_fast }}",
  ]) {
    assertIncludes(stablePlan, token, `stable README classifier is missing: ${token}`);
  }
  assertIncludes(stableRequired, "name: Stable client",
    "stable workflow must preserve its required context name");
  assertIncludes(stableRequired, "if: always()",
    "stable required check must always return a result");
  assertIncludes(stableRequired, "README_FAST_SELECTED",
    "stable required check must route on the README classifier");
  assertExcludes(stable, "readme-fast-path.mjs verify",
    "Stable client must not repeat the Auditor privacy scan");
  if ((stableRequired.match(/npm run client:build -- --platform macos/gmu) || []).length !== 1) {
    fail("stable promotion must build exactly once");
  }
  if ((stableRequired.match(/npm run client:install:macos/gmu) || []).length !== 1) {
    fail("stable promotion must install, launch, and prove survival exactly once");
  }
  const stableOrder = [
    "uses: actions/checkout@",
    "run: npm run client:build -- --platform macos",
    "run: npm run client:install:macos -- --launch-installed --verify-stable",
  ].map((token) => stableRequired.indexOf(token));
  if (stableOrder.some((index) => index < 0) ||
    stableOrder.some((index, position) => position > 0 && index <= stableOrder[position - 1])) {
    fail("stable promotion must build once, then install, launch, and prove survival");
  }
  for (const token of [
    "\n  push:", "workflow_dispatch:", "client:package:",
    "client:archive:", "actions/upload-artifact", "actions/download-artifact",
    "gh release", "client-github-release-publish", "npm publish", "GH_TOKEN:",
    "secrets.", "LICO_MACOS_SIGNING_IDENTITY", "LICO_MACOS_NOTARY_",
    "LICO_MACOS_LOCAL_SIGNING_IDENTITY", "LICO_MACOS_LOCAL_SIGNING_KEYCHAIN",
  ]) {
    assertExcludes(stable, token, `stable promotion must not publish or use release credentials: ${token}`);
  }

  const ready = readText(".github/workflows/client-release-ready.yml");
  const readyRequired = jobBlock(ready, "release-ready");
  if (JSON.stringify(workflowJobIds(ready)) !==
    JSON.stringify(["release-ready"])) {
    fail("release promotion workflow must keep one required check");
  }
  assertIncludes(ready, "branches:\n      - release",
    "release promotion workflow must target release");
  for (const token of [
    "name: Release ready",
    "runs-on: ubuntu-24.04",
    "HEAD_REPOSITORY: ${{ github.event.pull_request.head.repo.full_name }}",
    "TARGET_REPOSITORY: ${{ github.repository }}",
    'test "$HEAD_REPOSITORY" = "$TARGET_REPOSITORY"',
    'test "$HEAD_BRANCH" = stable',
    "npm run client:gate:topology",
    "npm run client:gate:release-policy",
  ]) {
    assertIncludes(readyRequired, token, `release readiness is missing: ${token}`);
  }
  for (const token of [
    "readme-fast-path.mjs classify",
    "steps.readme.outputs.readme_fast != 'true'",
  ]) {
    assertIncludes(readyRequired, token, `release README routing is missing: ${token}`);
  }
  assertExcludes(readyRequired, "readme-fast-path.mjs verify",
    "Release ready must not repeat the Auditor privacy scan");
  assertIncludes(ready, "push:\n    branches: [macos-release-candidate]", "release readiness must admit only the fixed candidate push");
  assertIncludes(readyRequired, "if: github.event.deleted != true", "candidate deletion cannot report readiness");
  assertIncludes(readyRequired, "run: node tools/scripts/verify-branch-flow.mjs", "candidate must equal the release source");
  assertIncludes(readyRequired, "if: github.event_name == 'pull_request'\n        id: readme", "candidate cannot skip release policy via README routing");
  const readyOrder = [
    "name: Verify promotion source",
    "uses: actions/checkout@",
    "run: npm run client:gate:topology",
    "run: npm run client:gate:release-policy",
  ].map((token) => readyRequired.indexOf(token));
  if (readyOrder.some((index) => index < 0) ||
    readyOrder.some((index, position) => position > 0 && index <= readyOrder[position - 1])) {
    fail("release promotion must guard before its ordered Node-only policy checks");
  }
  for (const token of [
    "workflow_dispatch:", "npm run client:build", "client:package:",
    "client:archive:", "client:install:", "client:run:", "client:verify:",
    "client:release:", "flutter-action", "rust-toolchain", "actions/setup-java",
    "actions/upload-artifact", "actions/download-artifact", "npm publish", "gh release",
    "client-github-release-publish", "contents: write", "id-token: write", "GH_TOKEN:",
    "secrets.",
  ]) {
    assertExcludes(ready, token, `release readiness must be build-free: ${token}`);
  }
}

function validateWeeklyReleaseTopology() {
  const weekly = readText(".github/workflows/client-weekly-release.yml");
  for (const token of [
    "name: Weekly release coordinator",
    "if: vars.LICOUP_RELEASE_AUTOMATION_ENABLED == 'true'",
    "types: [client-release-result]",
    "node tools/scripts/client-weekly-release.mjs",
  ]) {
    assertIncludes(weekly, token, `weekly release coordinator is missing: ${token}`);
  }
  // The coordinator mutates release state, so no job may run without the
  // repository explicitly enabling it.
  const gated = weekly.split("if: vars.LICOUP_RELEASE_AUTOMATION_ENABLED == 'true'").length - 1;
  const jobs = workflowJobIds(weekly).length;
  if (gated !== jobs) {
    fail("every weekly release coordinator job must be gated on LICOUP_RELEASE_AUTOMATION_ENABLED");
  }
}

function validateReadmeFastPathTopology() {
  const clientWorkflows = [
    ".github/workflows/client-ci.yml",
    ".github/workflows/client-stable.yml",
    ".github/workflows/client-release-ready.yml",
  ];
  for (const relativePath of clientWorkflows) {
    const workflow = readText(relativePath);
    assertIncludes(workflow, "readme-fast-path.mjs classify",
      `${relativePath} must classify the author README path`);
    assertExcludes(workflow, "readme-fast-path.mjs verify",
      `${relativePath} must leave the privacy scan to Auditor`);
  }
  const auditor = readText(".github/workflows/lico-auditor-gate.yml");
  assertIncludes(auditor, "readme-fast-path.mjs classify",
    "Auditor must classify the author README path");
  assertExcludes(auditor, "readme-fast-path.mjs verify",
    "Auditor must not use a repository-owned README privacy scanner");
  if ((auditor.match(/lico-auditor\/bin\/lico-auditor gate/gmu) || []).length !== 1) {
    fail("Auditor must run the canonical Lico-Auditor gate exactly once");
  }
  assertIncludes(auditor, "--no-contribution",
    "Auditor must reduce README fast-path scanning to content privacy");
}

function workflowJobIds(workflow) {
  const start = workflow.indexOf("\njobs:\n");
  if (start < 0) fail("workflow jobs mapping is missing");
  return [...workflow.slice(start).matchAll(/^\s{2}([a-z0-9][a-z0-9-]*):\s*$/gmu)]
    .map((match) => match[1]);
}

function validateDelegatedApplePublicationTopology() {
  const packageJson = readJson("package.json");
  const scripts = packageJson.scripts || {};
  const expected = {
    "client:release:authority:configure": "apple-release authority configure --config tools/apple-release/macos-direct-arm64.json",
    "client:release:macos": "apple-release release start --config tools/apple-release/macos-direct-arm64.json",
    "client:release:macos:publish": "apple-release release start --config tools/apple-release/macos-direct-arm64.json --authorize",
    "client:release:macos:nightly": "apple-release release start --config tools/apple-release/macos-direct-arm64-nightly.json",
    "client:release:macos:nightly:publish": "apple-release release start --config tools/apple-release/macos-direct-arm64-nightly.json --authorize",
    "client:release:status": "apple-release release status",
  };
  for (const [name, command] of Object.entries(expected)) {
    if (scripts[name] !== command) fail(`package.json must bind ${name} to Apple Release`);
  }
  for (const retired of [
    "client:release:service:install",
    "client:release:service:configure",
    "client:release:service:status",
  ]) {
    if (Object.hasOwn(scripts, retired)) fail(`retired Apple Release command remains: ${retired}`);
  }
  const roles = ["installer", "installer-digest", "update-archive", "update-digest", "update-manifest", "independent-tool", "independent-tool-digest"];
  const publication = readJson("tools/client-release-template.json").publication;
  if (JSON.stringify(publication?.assetRoles) !== JSON.stringify(roles) ||
      publication.independentToolSignatureNotaryAndPublicDigestRequired !== true) fail("LicoUp independent-tool publication contract is incomplete");
  for (const [file, sourceBranch, candidateBranch, releaseTrack] of [
    ["tools/apple-release/macos-direct-arm64.json", "release",
      "macos-release-candidate", "stable"],
    ["tools/apple-release/macos-direct-arm64-nightly.json", "nightly",
      "macos-nightly-release-candidate", "nightly"],
  ]) {
    const config = readJson(file);
    const candidate = config.candidate;
    const artifacts = Array.isArray(config.artifacts) ? config.artifacts : [];
    if (config.schema !== "apple-release.config.v1" ||
        config.source?.branch !== sourceBranch ||
        !candidate || candidate.branch !== candidateBranch || candidate.template !== undefined ||
        !Array.isArray(candidate.requiredChecks) || candidate.requiredChecks.length === 0 ||
        config.apple?.target !== "macos-direct-arm64" ||
        config.github?.repository !== "LicoLand/LicoUp" ||
        JSON.stringify(config.build?.command) !== JSON.stringify(sourceBranch === "release"
          ? ["node", "tools/scripts/macos-release/build.mjs"]
          : ["env", `LICO_CLIENT_RELEASE_TRACK=${releaseTrack}`, "npm", "run", "client:build", "--", "--platform", "macos"]) ||
        (sourceBranch === "release"
          ? JSON.stringify(config.update?.command) !== JSON.stringify(["node", "tools/scripts/macos-release/write-update-manifest.mjs",
            "--tag", "{tag}", "--repository", "{repository}", "--version", "{version}"]) ||
            JSON.stringify(config.gates) !== JSON.stringify([["node", "tools/scripts/macos-release/gate-source.mjs"],
              ["node", "tools/scripts/macos-release/gate-release-policy.mjs"]])
          : !Array.isArray(config.update?.command) || !config.update.command.includes("--release-track") ||
            !config.update.command.includes(releaseTrack)) ||
         artifacts.length !== roles.length ||
        roles.some((role) => artifacts.filter((entry) => entry.role === role).length !== 1) ||
        artifacts.find((entry) => entry.role === "update-manifest")?.publicName !==
           "LicoUp-update-manifest.json" ||
         artifacts.find((entry) => entry.role === "independent-tool")?.source !==
           "build/apps/desktop/release-tools/macos/LicoUp-migrate-macos-arm64" ||
         artifacts.find((entry) => entry.role === "independent-tool")?.publicName !== "LicoUp-migrate-macos-arm64" ||
         artifacts.find((entry) => entry.role === "independent-tool")?.path !== "build/apple-release/LicoUp-migrate-macos-arm64" ||
         artifacts.find((entry) => entry.role === "independent-tool-digest")?.publicName !== "LicoUp-migrate-macos-arm64.sha256" ||
         artifacts.find((entry) => entry.role === "independent-tool-digest")?.path !== "build/apple-release/LicoUp-migrate-macos-arm64.sha256") {
      fail(`LicoUp delegated Apple publication configuration is invalid: ${file}`);
    }
  }
}

function validateSourcePublicationTopology() {
  const source = readText(".github/workflows/client-source-release.yml");
  for (const token of ["types: [closed]", "branches: [release]", "github.event.pull_request.merged == true",
    "github.event.pull_request.head.ref == 'stable'", "github.event.pull_request.head.repo.full_name == github.repository",
    "github.event.pull_request.base.repo.full_name == github.repository", "ref: ${{ github.event.pull_request.merge_commit_sha }}",
    "fetch-depth: 0", "cancel-in-progress: false", "run: node tools/scripts/client-source-release.mjs"]) {
    assertIncludes(source, token, `source publication is missing: ${token}`);
  }
  for (const token of ["\n  push:", "workflow_dispatch:", "schedule:", "npm ci", "client:build", "apple-release release", "notarytool", "codesign"]) {
    assertExcludes(source, token, `source publication cannot invoke: ${token}`);
  }
}

export function validateClientGateTopology() {
  validatePackageTopology();
  validateCiTopology();
  validatePromotionTopology();
  validateWeeklyReleaseTopology();
  validateReadmeFastPathTopology();
  validateDelegatedApplePublicationTopology();
  validateSourcePublicationTopology();
  return Object.freeze({
    ok: true,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    laneCount: Object.keys(CLIENT_GATE_LANES).length,
    releaseTargetCount: Object.keys(CLIENT_RELEASE_TARGETS).length,
  });
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env: process.env,
    encoding: options.encoding,
    shell: false,
    stdio: options.stdio || "inherit",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    if (options.capture) fail(options.errorMessage);
    options.onFailure?.(result);
    process.exit(result.status ?? 1);
  }
  return result.stdout;
}

function validateRevision(value, label) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > 256 ||
    value.startsWith("-") ||
    /[\0-\x20\x7f]/u.test(value)
  ) {
    fail(`${label} revision is invalid`);
  }
  return value;
}

export function changedPaths({ base, head, target = "commit" }) {
  const safeHead = validateRevision(head || "HEAD", "head");
  const zeroRevision = /^0+$/u.test(base || "");
  if (!base || zeroRevision) {
    const parent = spawnSync("git", ["rev-parse", `${safeHead}^`], {
      cwd: repoRoot,
      encoding: "utf8",
      shell: false,
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (parent.status === 0) {
      base = parent.stdout.trim();
    } else {
      const rootDiff = run(
        "git",
        ["diff-tree", "--root", "--no-commit-id", "--name-only", "-z", "-r", safeHead],
        {
          capture: true,
          encoding: "buffer",
          stdio: ["ignore", "pipe", "pipe"],
          errorMessage: "unable to inspect initial client revision",
        },
      );
      const rootPaths = rootDiff.toString("utf8").split("\0").filter(Boolean);
      return ["commit", "delivery"].includes(target)
        ? [...new Set([...rootPaths, ...workingTreePaths(safeHead)])]
        : rootPaths;
    }
  }
  const safeBase = validateRevision(base, "base");
  const diff = run(
    "git",
    ["diff", "--name-only", "-z", safeBase, safeHead, "--"],
    {
      capture: true,
      encoding: "buffer",
      stdio: ["ignore", "pipe", "pipe"],
      errorMessage: "unable to inspect client changes",
    },
  );
  const committed = diff.toString("utf8").split("\0").filter(Boolean);
  return ["commit", "delivery"].includes(target)
    ? [...new Set([...committed, ...workingTreePaths(safeHead)])]
    : committed;
}

function workingTreePaths(head) {
  const tracked = run(
    "git",
    ["diff", "--no-renames", "--name-only", "-z", head, "--"],
    {
      capture: true,
      encoding: "buffer",
      stdio: ["ignore", "pipe", "pipe"],
      errorMessage: "unable to inspect local client changes",
    },
  );
  const untracked = run(
    "git",
    ["ls-files", "--others", "--exclude-standard", "-z", "--"],
    {
      capture: true,
      encoding: "buffer",
      stdio: ["ignore", "pipe", "pipe"],
      errorMessage: "unable to inspect untracked client changes",
    },
  );
  return Buffer.concat([tracked, untracked])
    .toString("utf8")
    .split("\0")
    .filter(Boolean);
}

function writePlanOutput(plan, digest, targetHosts = []) {
  const lines = [
    ...Object.entries(plan.lanes).map(
      ([lane, selected]) => `${lane.replaceAll("-", "_")}=${selected}`,
    ),
    `changed_count=${plan.changedCount}`,
    `change_digest=${digest}`,
    ...["darwin", "linux", "win32"].map(
      (host) => `target_${host}=${targetHosts.includes(host)}`,
    ),
  ];
  const outputPath = process.env.GITHUB_OUTPUT;
  if (outputPath) {
    appendFileSync(outputPath, `${lines.join("\n")}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
  }
  process.stdout.write(`${JSON.stringify({
    ok: true,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    changedCount: plan.changedCount,
    lanes: plan.lanes,
    changeDigest: digest,
    targetHosts,
  })}\n`);
}

function parsePlanArgs(args) {
  const values = { base: "", head: "HEAD", target: "commit" };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    if (!["--base", "--head", "--target"].includes(flag)) {
      fail(`unknown plan argument: ${flag}`);
    }
    if (index + 1 >= args.length) fail(`missing value for ${flag}`);
    values[flag.slice(2)] = args[index + 1];
    index += 1;
  }
  if (!["commit", "pr", "release"].includes(values.target)) {
    fail("client gate target must be commit, pr, or release");
  }
  return values;
}

function planGate(args) {
  const revisions = parsePlanArgs(args);
  const paths = changedPaths(revisions);
  const plan = classifyClientGatePaths(paths);
  const targetHosts = [...new Set(selectModulesForChangedPaths(paths)
    .flatMap((module) => module.regression.targetEvidenceHosts || []))].sort();
  const digest = createHash("sha256")
    .update([...new Set(paths)].sort().join("\0"))
    .digest("hex");
  writePlanOutput(plan, digest, targetHosts);
}

function parseVerifyArgs(args) {
  const values = {
    base: "", execution: "local", head: "HEAD", host: "", target: "", moduleIds: [],
  };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    if (!["--base", "--execution", "--head", "--host", "--target", "--module"].includes(flag)) {
      fail(`unknown verify argument: ${flag}`);
    }
    if (index + 1 >= args.length) fail(`missing value for ${flag}`);
    if (flag === "--module") values.moduleIds.push(args[index + 1]);
    else values[flag.slice(2)] = args[index + 1];
    index += 1;
  }
  if (!values.base) fail("client gate verify requires --base");
  if (!["commit", "pr", "release", "delivery"].includes(values.target)) {
    fail("client gate verify requires --target commit, pr, release, or delivery");
  }
  if (!["direct", "local", "target"].includes(values.execution)) {
    fail("client gate verify execution must be direct, local, or target");
  }
  if (["direct", "target"].includes(values.execution) &&
      !["darwin", "linux", "win32"].includes(values.host)) {
    fail("direct and target client gate verification require --host darwin, linux, or win32");
  }
  if (["direct", "target"].includes(values.execution) && values.host !== process.platform) {
    fail("client gate verification host must match the actual runtime host");
  }
  if (values.target === "delivery" && values.execution !== "local") {
    fail("client delivery requires local execution");
  }
  if (values.moduleIds.length > 0 && values.execution !== "direct") {
    fail("client gate module selection requires direct execution");
  }
  return Object.freeze({ ...values, moduleIds: Object.freeze([...values.moduleIds]) });
}

function reportIsMergeReady(report) {
  return report?.complete === true &&
    report?.status === "passed" &&
    Array.isArray(report.results) &&
    report.results.length > 0 &&
    report.results.every((result) => result.status === "passed") &&
    Array.isArray(report.compatibility) &&
    report.compatibility.every((result) => result.status === "passed");
}

const localDeliveryAdapters = Object.freeze({
  macos: Object.freeze({
    install: Object.freeze([
      "npm", "run", "client:install:macos", "--", "--launch-installed",
    ]),
  }),
});

export function runLocalClientDelivery({
  host = process.platform,
  architecture = process.arch,
  releaseCatalog = readJson("tools/client-release-targets.json"),
  releaseTargets = CLIENT_RELEASE_TARGETS,
  spawnImpl = spawnSync,
  output = process.stdout,
} = {}) {
  const hostId = `${host}-${architecture}`;
  const target = releaseCatalog.targets?.find((candidate) =>
    releaseTargets[candidate.id]?.localOnly === true &&
    candidate.packageBuildSupported === true &&
    candidate.releaseSupported === true && candidate.buildHost === hostId);
  const adapter = target ? localDeliveryAdapters[target.platform] : null;
  if (!target || !adapter) fail("local client delivery target is unsupported on this host");
  const stages = [
    Object.freeze({
      id: "build",
      argv: Object.freeze(["npm", "run", "client:build", "--", "--platform", target.platform]),
    }),
    Object.freeze({ id: "install-and-launch", argv: adapter.install }),
  ];
  for (const stage of stages) {
    const [command, ...args] = stage.argv;
    const result = spawnImpl(command, args, {
      cwd: repoRoot,
      env: process.env,
      shell: false,
      stdio: "inherit",
    });
    if (result.error || result.status !== 0) {
      output.write(`${JSON.stringify({
        ok: false,
        schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
        target: "delivery",
        stage: stage.id,
        reason: `delivery_${stage.id.replaceAll("-", "_")}_failed`,
      })}\n`);
      return 1;
    }
  }
  output.write(`${JSON.stringify({
    ok: true,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    target: "delivery",
    deliveryTargetId: target.id,
    platform: target.platform,
    built: true,
    installed: true,
    launchRequested: true,
    uiInspected: false,
    published: false,
  })}\n`);
  return 0;
}

export function withExecutionPrerequisites(selected, catalog) {
  const requiresFlutterDependencies = selected.some((module) =>
    ["flutter", "gradle"].includes(module.regression.toolchain));
  if (!requiresFlutterDependencies || selected.some((module) =>
    module.id === "regression.flutter-dependencies")) return selected;
  const prerequisite = catalog.find((module) => module.id === "regression.flutter-dependencies");
  if (!prerequisite) fail("Flutter dependency prerequisite is not registered");
  return [prerequisite, ...selected];
}

export function createTargetEvidenceReceipt({ revisions, selected, result }) {
  const report = result.report || null;
  const passed = result.exitCode === 0 &&
    targetResultsCoverSelection(selected, report?.results || []);
  return Object.freeze({
    ok: passed,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    target: revisions.target,
    execution: revisions.execution,
    host: revisions.host,
    head: revisions.head,
    stepIds: selected.map((module) => module.id),
    selectedStepCount: selected.length,
    complete: false,
    mergeReady: false,
    report,
  });
}

export async function verifyClientGate(args, {
  catalog = CLIENT_MODULE_CATALOG,
  executor = executeClientModules,
  output = process.stdout,
  reportPath = verificationReportPath,
} = {}) {
  const revisions = parseVerifyArgs(args);
  const paths = changedPaths(revisions);
  const plan = classifyClientGatePaths(paths);
  validateClientModuleCatalog(catalog);
  const directSelection = revisions.moduleIds.length > 0
    ? withExecutionPrerequisites(selectModulesById(revisions.moduleIds, catalog), catalog)
    : catalog;
  const modules = revisions.execution === "direct"
    ? directSelection.filter((module) =>
      (module.regression.runnableHosts || ["darwin", "linux", "win32"])
        .includes(revisions.host))
    : catalog;
  if (revisions.execution === "local") {
    const verification = await verifyLocalClientGate({
      revisions, paths, plan, catalog, executor, output, reportPath,
    });
    if (verification !== 0 || revisions.target !== "delivery") return verification;
    return runLocalClientDelivery({ output });
  }
  if (revisions.execution === "target") {
    if (!["pr", "release"].includes(revisions.target)) {
      fail("target evidence requires an immutable PR or release candidate");
    }
    if (!/^[a-f0-9]{40}$/u.test(revisions.head)) {
      fail("target evidence requires an immutable candidate head SHA");
    }
    const actualHead = run("git", ["rev-parse", "HEAD"], {
      capture: true,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      errorMessage: "unable to verify target candidate revision",
    }).trim().toLowerCase();
    const worktreeState = run("git", ["status", "--porcelain=v1", "--untracked-files=all"], {
      capture: true,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      errorMessage: "unable to verify target candidate worktree",
    });
    if (actualHead !== revisions.head.toLowerCase() || worktreeState.length !== 0) {
      fail("target evidence candidate does not match the clean checked-out head");
    }
    const selected = withExecutionPrerequisites(
      selectModulesForChangedPaths(paths, catalog).filter((module) =>
        (module.regression.targetEvidenceHosts || []).includes(revisions.host)),
      catalog,
    );
    const result = selected.length === 0
      ? { exitCode: 0, report: { results: [] } }
      : await executor(selected, {
        repoRoot,
        catalog,
        output,
        reportPath,
        runKind: "focused",
        compatibilityRunner: async () => [],
      });
    const receipt = createTargetEvidenceReceipt({ revisions, selected, result });
    output.write(`${JSON.stringify(receipt)}\n`);
    return receipt.ok ? 0 : 1;
  }
  const result = await executor(modules, {
    repoRoot,
    catalog,
    output,
    reportPath,
    runKind: revisions.moduleIds.length > 0 ? "focused" : "complete",
    compatibilityRunner: async () => [],
  });
  const mergeReady = result.exitCode === 0 && reportIsMergeReady(result.report);
  output.write(`${JSON.stringify({
    ok: mergeReady,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    target: revisions.target,
    execution: revisions.execution,
    scope: "host-engineering-profile",
    changedCount: plan.changedCount,
    lanes: plan.lanes,
    selectedStepCount: modules.length,
    complete: result.report?.complete === true,
    mergeReady: false,
  })}\n`);
  return mergeReady ? 0 : 1;
}

function localHost() {
  if (!["darwin", "linux", "win32"].includes(process.platform)) {
    fail("local client gate host is unsupported");
  }
  return process.platform;
}

function resultMembers(result) {
  return Array.isArray(result?.members) ? result.members : [];
}

export function targetResultsCoverSelection(selected, results) {
  if (!Array.isArray(results) || results.some((entry) => entry.status !== "passed")) return false;
  const covered = new Set(results.flatMap(resultMembers));
  return selected.every((module) => covered.has(module.id));
}

function labelResultHost(result, host) {
  return Object.freeze({ ...result, id: `host.${host}.${result.id}` });
}

export function combineLocalRegressionResults(linuxResults, hostResults, host) {
  const retainedLinux = linuxResults.filter((result) => {
    const members = resultMembers(result);
    return !(members.length === 1 && members[0] === "regression.repository-local-info-hygiene");
  });
  return [
    ...retainedLinux.map((result) => labelResultHost(result, "linux")),
    ...hostResults.map((result) => labelResultHost(result, host)),
  ];
}

function blockedTargetResult(module, host) {
  return Object.freeze({
    id: `target-evidence.${host}.${module.id}`,
    stage: module.regression.stage,
    lane: module.regression.lane,
    toolchain: module.regression.toolchain,
    status: "blocked",
    reason: "target_host_unavailable",
    durationMs: 0,
    members: Object.freeze([module.id]),
    metrics: null,
  });
}

export function targetReceiptResults(receipt, modules, host, { head, processStatus } = {}) {
  const expected = modules.map((module) => module.id).sort();
  const actual = Array.isArray(receipt?.stepIds) ? [...receipt.stepIds].sort() : [];
  const bound = receipt?.schemaVersion === CLIENT_GATE_SCHEMA_VERSION &&
    receipt?.execution === "target" && receipt?.host === host &&
    receipt?.head === head && JSON.stringify(actual) === JSON.stringify(expected);
  if (bound && Array.isArray(receipt?.report?.results) && receipt.report.results.length > 0) {
    const results = receipt.report.results.map((result) => labelResultHost(result, host));
    const covered = new Set(results.flatMap(resultMembers));
    for (const module of modules) {
      if (!covered.has(module.id)) {
        results.push(Object.freeze({
          ...blockedTargetResult(module, host),
          reason: "target_result_missing",
        }));
      }
    }
    if ((processStatus !== 0 || receipt.ok !== true) &&
        results.every((result) => result.status === "passed")) {
      results.push(Object.freeze({
        id: `target-runner.${host}`,
        stage: "foundation",
        lane: "foundation",
        toolchain: "node",
        status: "failed",
        reason: "target_runner_failed",
        durationMs: 0,
        members: Object.freeze([]),
        metrics: null,
      }));
    }
    return results;
  }
  const reason = bound
    ? (typeof receipt?.reason === "string" ? receipt.reason : "target_result_missing")
    : (receipt ? "target_receipt_binding_invalid" : "target_host_unavailable");
  return modules.map((module) => Object.freeze({
    ...blockedTargetResult(module, host),
    reason,
  }));
}

function readTargetRunnerReceipt(stdout) {
  for (const line of String(stdout || "").trim().split(/\r?\n/u).reverse()) {
    try {
      const receipt = JSON.parse(line);
      if (receipt?.schemaVersion === CLIENT_GATE_SCHEMA_VERSION &&
          receipt?.execution === "target") return receipt;
    } catch {}
  }
  return null;
}

function spawnClientGateProcess(command, args, { capture = false, output } = {}) {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      cwd: repoRoot,
      env: process.env,
      shell: false,
      stdio: capture ? ["ignore", "pipe", "ignore"] : "inherit",
    });
    let stdout = "";
    if (capture) {
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        stdout += chunk;
        output?.write(chunk);
      });
    }
    child.once("error", (error) => resolve({ status: null, error, stdout }));
    child.once("close", (status) => resolve({ status, error: null, stdout }));
  });
}

async function runWindowsTargetEvidence({ revisions, modules, output }) {
  if (modules.length === 0) return [];
  const base = run("git", ["rev-parse", revisions.base], {
    capture: true,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    errorMessage: "unable to resolve Windows target base revision",
  }).trim().toLowerCase();
  const head = run("git", ["rev-parse", revisions.head], {
    capture: true,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    errorMessage: "unable to resolve Windows target head revision",
  }).trim().toLowerCase();
  const args = [
    "tools/scripts/client-windows-target-runner.mjs",
    "run",
    "--base", base,
    "--head", head,
    "--target", revisions.target === "release" ? "release" : "pr",
    ...modules.flatMap((module) => ["--module", module.id]),
  ];
  const execution = await spawnClientGateProcess(process.execPath, args, { capture: true, output });
  return targetReceiptResults(readTargetRunnerReceipt(execution.stdout), modules, "win32", {
    head,
    processStatus: execution.status,
  });
}

export function reusableLinuxResults(previousReport, {
  currentHead,
  changedPaths: evidenceChangedPaths,
  catalog,
  validEvidenceHeads = new Set([previousReport?.candidateHead]),
}) {
  if (previousReport?.schemaVersion !== "licoup.client-regression-report.v1" ||
      previousReport?.complete !== true ||
      !/^[a-f0-9]{40}$/u.test(previousReport?.candidateHead || "") ||
      !/^sha256:[a-f0-9]{64}$/u.test(previousReport?.sourceStateDigest || "") ||
      !Array.isArray(previousReport.results)) return [];
  if (evidenceChangedPaths.some((candidate) =>
    candidate === "tools/scripts/client-gate.mjs" ||
    candidate.startsWith("tools/scripts/client-local-linux-runner/") ||
    candidate === "tools/scripts/client-local-linux-runner.mjs" ||
    candidate === "tools/regression/client-module-execution.mjs" ||
    candidate === "tools/regression/client-regression-batching.mjs" ||
    candidate === "tools/regression/client-regression-metadata.mjs" ||
    candidate.startsWith("tools/regression/client-module-catalog/"))) return [];
  const affected = new Set(selectModulesForChangedPaths(evidenceChangedPaths, catalog)
    .map((module) => module.id));
  const known = new Set(catalog
    .filter((module) => (module.regression.runnableHosts || ["darwin", "linux", "win32"])
      .includes("linux"))
    .map((module) => module.id));
  const reused = [];
  for (const result of previousReport.results) {
    if (result?.status !== "passed" ||
        !/^(?:reused\.)*host\.linux\./u.test(String(result.id || "")) ||
        !/^[a-f0-9]{40}$/u.test(result.evidenceHead || "") ||
        !validEvidenceHeads.has(result.evidenceHead) ||
        !Array.isArray(result.members)) continue;
    const members = result.members.filter((id) => known.has(id) && !affected.has(id));
    if (members.length === 0) continue;
    reused.push(Object.freeze({
      ...result,
      id: result.id.startsWith("reused.") ? result.id : `reused.${result.id}`,
      members: Object.freeze(members),
      evidenceHead: result.evidenceHead,
    }));
  }
  return Object.freeze(reused);
}

function readLinuxRunnerReceipt(stdout) {
  for (const line of String(stdout || "").trim().split(/\r?\n/u).reverse()) {
    try {
      const receipt = JSON.parse(line);
      if (receipt?.schemaVersion === "licoup.client-local-linux-ci.v1" &&
          receipt?.profile === "engineering") return receipt;
    } catch {}
  }
  return null;
}

async function verifyLocalClientGate({
  revisions,
  paths,
  plan,
  catalog,
  executor,
  output,
  reportPath,
}) {
  const host = localHost();
  const affected = selectModulesForChangedPaths(paths, catalog);
  const linuxIds = new Set(catalog
    .filter((module) => (module.regression.runnableHosts || ["darwin", "linux", "win32"])
      .includes("linux"))
    .map((module) => module.id));
  const supplemental = withExecutionPrerequisites(catalog.filter((module) => {
    const runnable = module.regression.runnableHosts || ["darwin", "linux", "win32"];
    const targets = module.regression.targetEvidenceHosts || [];
    return module.id === "regression.repository-local-info-hygiene" ||
      (runnable.includes(host) && !linuxIds.has(module.id)) ||
      (affected.includes(module) && targets.includes(host));
  }), catalog);
  const hostResult = await executor(supplemental, {
    repoRoot,
    catalog,
    output,
    reportPath: null,
    runKind: "focused",
    compatibilityRunner: async () => [],
  });
  const missingTargets = [];
  const windowsTargets = [];
  for (const module of affected) {
    for (const targetHost of module.regression.targetEvidenceHosts || []) {
      if (targetHost !== "linux" && targetHost !== host) {
        if (targetHost === "win32") windowsTargets.push(module);
        else missingTargets.push(blockedTargetResult(module, targetHost));
      }
    }
  }
  const uniqueWindowsTargets = withExecutionPrerequisites([
    ...new Map(windowsTargets.map((module) => [module.id, module])).values(),
  ], catalog);
  const currentHead = run("git", ["rev-parse", revisions.head], {
    capture: true,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    errorMessage: "unable to resolve local verification head",
  }).trim().toLowerCase();
  const clean = run("git", ["status", "--porcelain=v1", "--untracked-files=all"], {
    capture: true,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    errorMessage: "unable to inspect local verification worktree",
  }).length === 0;
  let previousReport = null;
  if (clean && existsSync(reportPath)) {
    try {
      previousReport = JSON.parse(readFileSync(reportPath, "utf8"));
    } catch {}
  }
  let reusedResults = [];
  if (previousReport && /^[a-f0-9]{40}$/u.test(previousReport.candidateHead || "")) {
    const ancestor = previousReport.candidateHead === currentHead || spawnSync(
      "git", ["merge-base", "--is-ancestor", previousReport.candidateHead, currentHead],
      { cwd: repoRoot, stdio: "ignore", shell: false },
    ).status === 0;
    if (ancestor) {
      const validEvidenceHeads = new Set((previousReport.results || [])
        .map((result) => result.evidenceHead)
        .filter((head) => /^[a-f0-9]{40}$/u.test(head || ""))
        .filter((head) => head === previousReport.candidateHead || spawnSync(
          "git", ["merge-base", "--is-ancestor", head, previousReport.candidateHead],
          { cwd: repoRoot, stdio: "ignore", shell: false },
        ).status === 0));
      reusedResults = reusableLinuxResults(previousReport, {
        currentHead,
        changedPaths: changedPaths({
          base: previousReport.candidateHead,
          head: currentHead,
          target: "pr",
        }),
        catalog,
        validEvidenceHeads,
      });
    }
  }
  const reusedIds = new Set(reusedResults.flatMap(resultMembers));
  const linuxModules = withExecutionPrerequisites(
    catalog.filter((module) => linuxIds.has(module.id) && !reusedIds.has(module.id)),
    catalog,
  );
  const focusedLinuxRetry = reusedResults.length > 0;
  rmSync(reportPath, { force: true });
  const [runner, targetResults] = await Promise.all([
    linuxModules.length === 0
      ? Promise.resolve({ status: 0, error: null, stdout: "" })
      : spawnClientGateProcess(process.execPath, [
        "tools/scripts/client-local-linux-runner.mjs",
        "run",
        "--profile",
        "engineering",
        ...(focusedLinuxRetry
          ? linuxModules.flatMap((module) => ["--module", module.id])
          : []),
      ], { capture: true, output }),
    runWindowsTargetEvidence({ revisions, modules: uniqueWindowsTargets, output }),
  ]);
  let linuxReport = null;
  if (existsSync(reportPath)) {
    try {
      linuxReport = JSON.parse(readFileSync(reportPath, "utf8"));
    } catch {
      linuxReport = null;
    }
  }
  const combinedResults = combineLocalRegressionResults(
    linuxReport?.results || [],
    hostResult.report?.results || [],
    host,
  );
  const results = [
    ...reusedResults,
    ...combinedResults,
    ...targetResults,
    ...missingTargets,
  ];
  const coveredIds = new Set(results.flatMap(resultMembers));
  const applicableIds = new Set([
    ...linuxIds,
    ...supplemental.map((module) => module.id),
    ...affected.flatMap((module) =>
      (module.regression.targetEvidenceHosts || []).length > 0 ? [module.id] : []),
  ]);
  for (const module of catalog.filter((entry) => applicableIds.has(entry.id))) {
    if (!coveredIds.has(module.id)) {
      results.push(Object.freeze({
        ...blockedTargetResult(module, host),
        id: `execution-result.${module.id}`,
        reason: "execution_result_missing",
      }));
    }
  }
  const startedAt = linuxReport?.startedAt || hostResult.report?.startedAt || new Date().toISOString();
  const completedAt = new Date().toISOString();
  const evidencedResults = results.map((result) => result.evidenceHead
    ? result
    : Object.freeze({ ...result, evidenceHead: currentHead }));
  const report = createClientRegressionReport({
    runKind: "complete",
    startedAt,
    completedAt,
    durationMs: Math.max(0, Date.parse(completedAt) - Date.parse(startedAt)),
    results: evidencedResults,
    concurrency: linuxReport?.concurrency || hostResult.report?.concurrency || {},
    compatibility: [],
    candidateHead: currentHead,
    sourceStateDigest: readLinuxRunnerReceipt(runner.stdout)?.sourceStateDigest ||
      (reusedResults.length > 0 && linuxModules.length === 0
        ? previousReport?.sourceStateDigest || null
        : null),
  });
  await writeClientRegressionReport(report, reportPath);
  const runnerPassed = !runner.error && runner.status === 0 &&
    (linuxModules.length === 0 || linuxReport?.results?.every((result) =>
      result.status === "passed"));
  const mergeReady = runnerPassed && hostResult.exitCode === 0 && reportIsMergeReady(report);
  output.write(`${JSON.stringify({
    ok: mergeReady,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    target: revisions.target,
    execution: revisions.execution,
    host,
    changedCount: plan.changedCount,
    lanes: plan.lanes,
    selectedStepCount: applicableIds.size,
    complete: report.complete,
    missingTargetEvidenceCount: results.filter((result) =>
      result.status === "blocked" && result.id.startsWith("target-evidence.")).length,
  })}\n`);
  return mergeReady ? 0 : 1;
}

export async function runClientGateStep(stepId, {
  catalog = CLIENT_MODULE_CATALOG,
  executor = executeClientModules,
  output = process.stdout,
} = {}) {
  const selected = selectModulesById([stepId], catalog);
  const result = await executor(selected, {
    repoRoot,
    catalog,
    output,
    reportPath: null,
    runKind: "focused",
    compatibilityRunner: async () => [],
  });
  const passed = result.exitCode === 0 &&
    result.report?.results?.every((entry) => entry.status === "passed") === true;
  output.write(`${JSON.stringify({
    ok: passed,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    scope: "focused-step",
    stepId,
    complete: false,
    mergeReady: false,
  })}\n`);
  return passed ? 0 : 1;
}

export function runLane(lane, {
  spawnImpl = spawnSync,
  output = process.stdout,
  eventEmitter = emitClientGateTaskEvent,
} = {}) {
  const scripts = CLIENT_GATE_LANES[lane];
  if (!scripts) fail(`unknown client gate lane: ${lane || "<missing>"}`);
  const steps = lane === "release-policy"
    ? [Object.freeze({
      id: "release-policy.contract-tests",
      command: process.execPath,
      args: ["--test",
        "tests/contract/client/client-source-release.test.mjs",
        "tests/contract/client/macos-release-adapters.test.mjs",
        "tests/contract/client/macos-release-candidate.test.mjs",
        "tests/contract/client/apple-release-integration.test.mjs"],
    }), ...scripts.map((script) => Object.freeze({
      id: script,
      command: "npm",
      args: ["run", script],
    }))]
    : scripts.map((script) => Object.freeze({
      id: script,
      command: "npm",
      args: ["run", script],
    }));
  const results = [];
  for (const step of steps) {
    eventEmitter({ type: "step-start", stage: step.id });
    output.write(`\n[client-gate:${lane}] ${step.id}\n`);
    const result = spawnImpl(step.command, step.args, {
      cwd: repoRoot,
      env: process.env,
      shell: false,
      stdio: "inherit",
    });
    const status = !result.error && result.status === 0 ? "passed" : "failed";
    results.push(Object.freeze({ id: step.id, status }));
    if (status === "failed") {
      eventEmitter({
        type: "step-failure",
        stage: step.id,
        code: result.error ? "command-launch-failed" : "command-exit-nonzero",
        exitCode: result.status ?? 1,
        retryable: false,
        recovery: "inspect-failed-step",
      });
    }
  }
  const ok = results.every((result) => result.status === "passed");
  output.write(`${JSON.stringify({
    ok,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    lane,
    stepCount: steps.length,
    results,
  })}\n`);
  return ok ? 0 : 1;
}

export async function main(args = process.argv.slice(2)) {
  const [command, ...rest] = args;
  if (command === "topology") {
    process.stdout.write(`${JSON.stringify(validateClientGateTopology())}\n`);
    return;
  }
  if (command === "plan") {
    planGate(rest);
    return;
  }
  if (command === "run") {
    if (rest.length !== 1) fail("client gate run requires exactly one lane");
    process.exitCode = runLane(rest[0]);
    return;
  }
  if (command === "verify") {
    process.exitCode = await verifyClientGate(rest);
    return;
  }
  if (command === "step") {
    if (rest.length !== 1) fail("client gate step requires exactly one module id");
    process.exitCode = await runClientGateStep(rest[0]);
    return;
  }
  fail("usage: client-gate.mjs <topology|plan|run LANE|verify|step MODULE_ID>");
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await main();
  } catch (error) {
    process.stderr.write(`${error?.message || error}\n`);
    process.exitCode = 1;
  }
}
