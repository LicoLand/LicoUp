#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  readFileSync,
  writeSync,
} from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  CLIENT_CI_JOBS,
  CLIENT_GATE_LANES,
  CLIENT_GATE_SCHEMA_VERSION,
  CLIENT_RELEASE_TARGETS,
  classifyClientGatePaths,
} from "./client-gate-policy.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
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
  "client:build:",
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
  const source = jobBlock(workflow, "source");
  for (const token of [
    "github.event.pull_request.base.sha",
    "github.event.pull_request.head.sha",
    "readme-fast-path.mjs classify",
    "readme_fast: ${{ steps.readme.outputs.readme_fast }}",
  ]) {
    assertIncludes(plan, token, `CI README classifier is missing: ${token}`);
  }
  assertIncludes(plan, "steps.readme.outputs.readme_fast != 'true'",
    "ordinary client planning must be inverse to README fast selection");
  assertExcludes(plan, "readme-fast-path.mjs verify",
    "Client required must not repeat the Auditor privacy scan");
  for (const token of forbiddenSourceTokens) {
    assertExcludes(plan, token, `CI plan job must not contain ${token}`);
    assertExcludes(source, token, `CI source job must not contain ${token}`);
  }
  assertIncludes(
    source,
    "npm run client:gate:source",
    "CI source job must invoke the canonical source gate",
  );
  for (const lane of ["flutter", "rust", "android", "dependencies"]) {
    const block = jobBlock(workflow, lane);
    const outputName = lane.replaceAll("-", "_");
    assertIncludes(
      block,
      `needs: plan`,
      `CI ${lane} lane must depend only on the change plan`,
    );
    assertIncludes(
      block,
      `needs.plan.outputs.${outputName}`,
      `CI ${lane} lane must be selected by the change plan`,
    );
    assertIncludes(
      block,
      `npm run client:gate:${lane}`,
      `CI ${lane} lane must invoke its canonical gate`,
    );
  }
  const required = jobBlock(workflow, "client-required");
  assertIncludes(
    required,
    "needs: [plan, source, flutter, rust, android, dependencies]",
    "required CI reducer must observe every independent lane",
  );
  assertIncludes(required, "if: always()", "required CI reducer must always report lane failures");
  for (const token of [
    "PLAN_RESULT",
    "README_FAST_SELECTED",
    "An ordinary client gate ran for an author README update",
    "README path selection was ambiguous",
  ]) {
    assertIncludes(required, token, `required CI reducer is missing: ${token}`);
  }
  for (const forbidden of [
    "client:build:",
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
    'test "$HEAD_BRANCH" = nightly',
    'test "$(uname -m)" = arm64',
    "LICO_CLIENT_RELEASE_TARGETS: macos-arm64",
    "npm run client:build:macos",
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
  if ((stableRequired.match(/npm run client:build:macos/gmu) || []).length !== 1) {
    fail("stable promotion must build exactly once");
  }
  if ((stableRequired.match(/npm run client:install:macos/gmu) || []).length !== 1) {
    fail("stable promotion must install, launch, and prove survival exactly once");
  }
  const stableOrder = [
    "uses: actions/checkout@",
    "run: npm run client:build:macos",
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
    "\n  push:", "workflow_dispatch:", "client:build:", "client:package:",
    "client:archive:", "client:install:", "client:run:", "client:verify:",
    "client:release:", "flutter-action", "rust-toolchain", "actions/setup-java",
    "actions/upload-artifact", "actions/download-artifact", "npm publish", "gh release",
    "client-github-release-publish", "contents: write", "id-token: write", "GH_TOKEN:",
    "secrets.",
  ]) {
    assertExcludes(ready, token, `release readiness must be build-free: ${token}`);
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
    "client:release:macos": "apple-release release start --config tools/apple-release/macos-direct-arm64.json",
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
  const config = readJson("tools/apple-release/macos-direct-arm64.json");
  const candidate = config.candidate;
  const adapterPrefix = "tools/scripts/macos-release/";
  const productCommands = [...(config.gates || []), config.build?.command, config.update?.command]
    .filter((command) => Array.isArray(command) && command[0] === "node");
  if (config.schema !== "apple-release.config.v1" ||
      config.source?.branch !== "release" ||
      !candidate || candidate.branch !== "macos-release-candidate" ||
      Object.keys(candidate).sort().join(",") !== "branch,requiredChecks" ||
      !Array.isArray(candidate.requiredChecks) || candidate.requiredChecks.length === 0 ||
      Object.keys(config.version || {}).sort().join(",") !== "buildField,file,versionField" ||
      config.apple?.target !== "macos-direct-arm64" ||
      config.github?.repository !== "LicoLand/LicoUp" ||
      productCommands.length !== 4 ||
      productCommands.some((command) => !command[1]?.startsWith(adapterPrefix)) ||
      config.artifacts?.length !== 5 ||
      config.artifacts.filter((entry) => entry.role === "update-manifest").length !== 1) {
    fail("LicoUp delegated Apple publication configuration is invalid");
  }
}

function validateAutomaticSourcePublicationTopology() {
  const packageJson = readJson("package.json");
  if (packageJson.scripts?.["client:release:source:self-test"] !==
      "node --test tests/contract/client/client-source-release.test.mjs") {
    fail("package.json must bind the automatic source release self-test");
  }
  const workflow = readText(".github/workflows/client-source-release.yml");
  const publisher = readText("tools/scripts/client-source-release.mjs");
  if (JSON.stringify(workflowJobIds(workflow)) !== JSON.stringify(["publish-source"])) {
    fail("source publication workflow must keep one publication job");
  }
  for (const token of [
    "name: Publish source release",
    "pull_request:\n    types: [closed]\n    branches: [release]",
    "permissions:\n  contents: write",
    "github.event.pull_request.merged == true",
    "github.event.pull_request.head.ref == 'stable'",
    "github.event.pull_request.head.repo.full_name == github.repository",
    "ref: ${{ github.event.pull_request.merge_commit_sha }}",
    "persist-credentials: false",
    "client-source-release.mjs prepare",
    "client-source-release.mjs publish",
  ]) {
    assertIncludes(workflow, token, `automatic source publication is missing: ${token}`);
  }
  for (const token of [
    "tag: `v${version}`",
    "title: `LicoUp ${version}`",
    "`apple-release-source:v1:${revision}`",
  ]) {
    assertIncludes(publisher, token, `source publisher is missing the shared Release contract: ${token}`);
  }
  for (const token of [
    "\n  push:", "workflow_dispatch:", "client:release:macos", "apple-release",
    "notarytool", "codesign", "xcodebuild", "flutter build", "npm publish",
  ]) {
    assertExcludes(workflow, token,
      `automatic source publication must remain source-only: ${token}`);
  }
}

export function validateClientGateTopology() {
  validatePackageTopology();
  validateCiTopology();
  validatePromotionTopology();
  validateReadmeFastPathTopology();
  validateDelegatedApplePublicationTopology();
  validateAutomaticSourcePublicationTopology();
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

function changedPaths({ base, head }) {
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
      return rootDiff.toString("utf8").split("\0").filter(Boolean);
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
  return diff.toString("utf8").split("\0").filter(Boolean);
}

function writePlanOutput(plan, digest) {
  const lines = [
    ...Object.entries(plan.lanes).map(
      ([lane, selected]) => `${lane.replaceAll("-", "_")}=${selected}`,
    ),
    `changed_count=${plan.changedCount}`,
    `change_digest=${digest}`,
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
  })}\n`);
}

function parsePlanArgs(args) {
  const values = { base: "", head: "HEAD" };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    if (flag !== "--base" && flag !== "--head") fail(`unknown plan argument: ${flag}`);
    if (index + 1 >= args.length) fail(`missing value for ${flag}`);
    values[flag.slice(2)] = args[index + 1];
    index += 1;
  }
  return values;
}

function planGate(args) {
  const revisions = parsePlanArgs(args);
  const paths = changedPaths(revisions);
  const plan = classifyClientGatePaths(paths);
  const digest = createHash("sha256")
    .update([...new Set(paths)].sort().join("\0"))
    .digest("hex");
  writePlanOutput(plan, digest);
}

function runLane(lane) {
  const scripts = CLIENT_GATE_LANES[lane];
  if (!scripts) fail(`unknown client gate lane: ${lane || "<missing>"}`);
  for (const script of scripts) {
    emitClientGateTaskEvent({ type: "step-start", stage: script });
    process.stdout.write(`\n[client-gate:${lane}] npm run ${script}\n`);
    run("npm", ["run", script], {
      onFailure: (result) => emitClientGateTaskEvent({
        type: "step-failure",
        stage: script,
        code: result.error ? "command-launch-failed" : "command-exit-nonzero",
        exitCode: result.status ?? 1,
        retryable: false,
        recovery: "inspect-failed-step",
      }),
    });
  }
  process.stdout.write(`${JSON.stringify({
    ok: true,
    schemaVersion: CLIENT_GATE_SCHEMA_VERSION,
    lane,
    stepCount: scripts.length,
  })}\n`);
}

export function main(args = process.argv.slice(2)) {
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
    runLane(rest[0]);
    return;
  }
  fail("usage: client-gate.mjs <topology|plan|run LANE>");
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error?.message || error}\n`);
    process.exitCode = 1;
  }
}
