#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  readFileSync,
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
  "client:verify:github-release",
  "client:verify:product-line-security",
  "gh release",
]);

function fail(message) {
  throw new Error(message);
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
    "node tools/scripts/client-agent-conversation-parity-reducer.mjs --check --require-ready"
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
    "client-cursor-conversation-gate.mjs",
    "client-up-local-service-conversation-gate.mjs",
    "client-same-session-conversation-gate.mjs",
    "client-claude-code-conversation-gate.mjs",
    "client-antigravity-conversation-gate.mjs",
    "client-codex-conversation-parity.mjs",
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
  const docsPlan = jobBlock(workflow, "docs-plan");
  const docsFast = jobBlock(workflow, "docs-fast");
  const plan = jobBlock(workflow, "plan");
  const source = jobBlock(workflow, "source");
  for (const token of [
    "github.event.pull_request.base.sha",
    "github.event.pull_request.head.sha",
    "docs-fast-promotion.mjs plan",
  ]) {
    assertIncludes(docsPlan, token, `CI documentation classifier is missing: ${token}`);
  }
  assertIncludes(
    docsFast,
    "docs-fast-promotion.mjs verify",
    "CI documentation fast lane must run the manifest/privacy verifier",
  );
  assertIncludes(
    docsFast,
    "needs.docs-plan.outputs.docs_fast == 'true'",
    "CI documentation fast lane must require literal true selection",
  );
  assertIncludes(
    plan,
    "needs.docs-plan.outputs.docs_fast != 'true'",
    "ordinary client planning must be inverse to documentation fast selection",
  );
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
    "needs: [docs-plan, docs-fast, plan, source, flutter, rust, android, dependencies]",
    "required CI reducer must observe every independent lane",
  );
  assertIncludes(required, "if: always()", "required CI reducer must always report lane failures");
  for (const token of [
    "DOCS_PLAN_RESULT",
    "DOCS_FAST_SELECTED",
    "DOCS_FAST_RESULT",
    "PLAN_RESULT",
    "An ordinary client gate ran for a documentation-only change",
    "Documentation path selection was ambiguous",
  ]) {
    assertIncludes(required, token, `required CI reducer is missing: ${token}`);
  }
  for (const forbidden of [
    "client:build:",
    "client:archive:",
    "client:package:",
    "client:install:",
    "client:run:",
    "client:verify:github-release",
    "client:verify:product-line-security",
    "gh release",
  ]) {
    assertExcludes(workflow, forbidden, `client CI must not perform release target work: ${forbidden}`);
  }
}

function validatePromotionTopology() {
  const stable = readText(".github/workflows/client-stable.yml");
  const stablePlan = jobBlock(stable, "docs-plan");
  const stableFast = jobBlock(stable, "docs-fast");
  const stableFull = jobBlock(stable, "stable-client-full");
  const stableRequired = jobBlock(stable, "stable-client");
  if (JSON.stringify(workflowJobIds(stable)) !==
    JSON.stringify(["docs-plan", "docs-fast", "stable-client-full", "stable-client"])) {
    fail("stable promotion workflow jobs must match the conditional topology");
  }
  assertIncludes(stable, "branches:\n      - stable",
    "stable promotion workflow must target stable");
  for (const token of [
    "name: Stable client full validation",
    "runs-on: macos-15",
    "HEAD_REPOSITORY: ${{ github.event.pull_request.head.repo.full_name }}",
    "TARGET_REPOSITORY: ${{ github.repository }}",
    'test "$HEAD_REPOSITORY" = "$TARGET_REPOSITORY"',
    'test "$HEAD_BRANCH" = nightly',
    'test "$(uname -m)" = arm64',
    "LICO_CLIENT_RELEASE_TARGETS: macos-arm64",
    "npm run client:build:macos",
    "npm run client:install:macos -- --launch-installed --verify-stable",
  ]) {
    assertIncludes(stableFull, token, `stable full promotion lane is missing: ${token}`);
  }
  for (const token of [
    "HEAD_REPOSITORY: ${{ github.event.pull_request.head.repo.full_name }}",
    'test "$HEAD_REPOSITORY" = "$TARGET_REPOSITORY"',
    'test "$HEAD_BRANCH" = nightly',
    "docs-fast-promotion.mjs plan",
  ]) {
    assertIncludes(stablePlan, token, `stable documentation classifier is missing: ${token}`);
  }
  assertIncludes(stableFast, "docs-fast-promotion.mjs verify",
    "stable documentation fast lane must verify manifest privacy");
  assertIncludes(stableRequired, "name: Stable client",
    "stable aggregate must preserve its required context name");
  assertIncludes(stableRequired, "if: always()",
    "stable aggregate must always reduce lane results");
  if ((stableFull.match(/npm run client:build:macos/gmu) || []).length !== 1) {
    fail("stable promotion must build exactly once");
  }
  if ((stableFull.match(/npm run client:install:macos/gmu) || []).length !== 1) {
    fail("stable promotion must install, launch, and prove survival exactly once");
  }
  const stableOrder = [
    "name: Verify promotion source",
    "uses: actions/checkout@",
    "run: npm run client:build:macos",
    "run: npm run client:install:macos -- --launch-installed --verify-stable",
  ].map((token) => stableFull.indexOf(token));
  if (stableOrder.some((index) => index < 0) ||
    stableOrder.some((index, position) => position > 0 && index <= stableOrder[position - 1])) {
    fail("stable promotion must guard, build once, then install, launch, and prove survival");
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
  const readyPlan = jobBlock(ready, "docs-plan");
  const readyFast = jobBlock(ready, "docs-fast");
  const readyFull = jobBlock(ready, "release-ready-full");
  const readyRequired = jobBlock(ready, "release-ready");
  if (JSON.stringify(workflowJobIds(ready)) !==
    JSON.stringify(["docs-plan", "docs-fast", "release-ready-full", "release-ready"])) {
    fail("release promotion workflow jobs must match the conditional topology");
  }
  assertIncludes(ready, "branches:\n      - release",
    "release promotion workflow must target release");
  for (const token of [
    "name: Release ready full policy",
    "runs-on: ubuntu-24.04",
    "HEAD_REPOSITORY: ${{ github.event.pull_request.head.repo.full_name }}",
    "TARGET_REPOSITORY: ${{ github.repository }}",
    'test "$HEAD_REPOSITORY" = "$TARGET_REPOSITORY"',
    'test "$HEAD_BRANCH" = stable',
    "npm run client:gate:topology",
    "npm run client:gate:release-policy",
  ]) {
    assertIncludes(readyFull, token, `release full promotion lane is missing: ${token}`);
  }
  for (const token of [
    "HEAD_REPOSITORY: ${{ github.event.pull_request.head.repo.full_name }}",
    'test "$HEAD_REPOSITORY" = "$TARGET_REPOSITORY"',
    'test "$HEAD_BRANCH" = stable',
    "docs-fast-promotion.mjs plan",
  ]) {
    assertIncludes(readyPlan, token, `release documentation classifier is missing: ${token}`);
  }
  assertIncludes(readyFast, "docs-fast-promotion.mjs verify",
    "release documentation fast lane must verify manifest privacy");
  assertIncludes(readyRequired, "name: Release ready",
    "release aggregate must preserve its required context name");
  assertIncludes(readyRequired, "if: always()",
    "release aggregate must always reduce lane results");
  const readyOrder = [
    "name: Verify promotion source",
    "uses: actions/checkout@",
    "run: npm run client:gate:topology",
    "run: npm run client:gate:release-policy",
  ].map((token) => readyFull.indexOf(token));
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

function releaseInputIds(workflow) {
  const start = workflow.indexOf("    inputs:\n");
  const end = workflow.indexOf("\npermissions:", start);
  if (start < 0 || end < 0) fail("release workflow input mapping is missing");
  return [...workflow.slice(start, end).matchAll(/^\s{6}([a-z][a-z0-9_]*):\s*$/gmu)]
    .map((match) => match[1]);
}

function workflowJobIds(workflow) {
  const start = workflow.indexOf("\njobs:\n");
  if (start < 0) fail("workflow jobs mapping is missing");
  return [...workflow.slice(start).matchAll(/^\s{2}([a-z0-9][a-z0-9-]*):\s*$/gmu)]
    .map((match) => match[1]);
}

function validateReleaseTopology() {
  const workflow = readText(".github/workflows/client-release.yml");
  const publisher = readText("tools/scripts/client-github-release-publish.mjs");
  const preflight = readText("tools/scripts/client-pr-preflight.mjs");
  const catalog = readJson("tools/client-release-targets.json");
  const supportedTargets = catalog.targets
    .filter((target) => target.releaseSupported === true &&
      CLIENT_RELEASE_TARGETS[target.id]?.localOnly !== true)
    .map((target) => target.id)
    .sort();
  const policyTargets = Object.keys(CLIENT_RELEASE_TARGETS).sort();
  const governedPolicyTargets = catalog.targets
    .filter((target) => target.releaseSupported === true ||
      (CLIENT_RELEASE_TARGETS[target.id]?.publicationBlocked === true &&
        target.releaseBlockers?.includes("macos_github_release_publication_not_authorized")))
    .map((target) => target.id)
    .sort();
  if (JSON.stringify(governedPolicyTargets) !== JSON.stringify(policyTargets) ||
    supportedTargets.some((target) => CLIENT_RELEASE_TARGETS[target].publicationBlocked === true)) {
    fail("release target policy must match publishable or explicitly local-only catalog entries");
  }
  const expectedInputs = ["phase", "release_tag", "targets", "correlation",
    "prepare_run_id", "source_revision", "artifact_digests",
    "signed_update_manifest_base64", "publish_release"].sort();
  if (JSON.stringify(releaseInputIds(workflow).sort()) !== JSON.stringify(expectedInputs)) {
    fail("release workflow must accept one or more targets and bounded publication inputs");
  }
  const expectedJobs = ["source", "prepare", "publish"].sort();
  if (JSON.stringify(workflowJobIds(workflow).sort()) !== JSON.stringify(expectedJobs)) {
    fail("release workflow jobs must match the multi-package topology");
  }
  assertExcludes(
    jobBlock(workflow, "source"),
    "npm run client:gate:",
    "remote release request binding must not repeat local gates",
  );
  assertIncludes(
    workflow,
    "client-github-release-${{ inputs.release_tag }}",
    "release phases for one tag must serialize",
  );
  const source = jobBlock(workflow, "source");
  const prepare = jobBlock(workflow, "prepare");
  const publish = jobBlock(workflow, "publish");
  for (const token of ["--targets", "--artifact-digests", "--mode matrix"]) {
    assertIncludes(source, token,
      `release request binding is missing multi-package token: ${token}`);
  }
  for (const token of [
    "matrix: ${{ fromJSON(needs.source.outputs.matrix) }}",
    "client:release:build", "client:release:verify",
  ]) {
    assertIncludes(prepare, token,
      `release prepare matrix is missing token: ${token}`);
  }
  for (const target of supportedTargets) {
    assertIncludes(prepare, target,
      `release prepare matrix has no exact build path for ${target}`);
  }
  for (const target of policyTargets) {
    if (CLIENT_RELEASE_TARGETS[target].artifactName !== `licoup-${target}`) {
      fail(`release artifact name is not target-derived: ${target}`);
    }
  }
  for (const token of [
    "client-github-release-publish.mjs", "client-release-workflow-binding.mjs",
    "--targets", "--incoming-root", "--artifact-digests",
    "LICO_SIGNED_UPDATE_MANIFEST_BASE64",
    '--name "licoup-$target"',
  ]) {
    assertIncludes(publish, token,
      `release publisher is missing multi-package token: ${token}`);
  }
  for (const token of [
    "client-consumer-verification-manifest.mjs",
    "client-release-remote-asset-set.mjs",
    "COPYFILE_EXCL",
    "release.targetCommitish !== sourceSha",
  ]) {
    assertIncludes(
      publisher,
      token,
      `canonical release publisher is missing safety token: ${token}`,
    );
  }
  assertIncludes(workflow, "client:release:remote-strategy -- --expect build-success",
    "remote release validity must use the active build-success strategy");
  const deviceDemoStages = preflight.match(
    /npmStage\(`device-demo-\$\{platform\}`, `client:demo:device:\$\{platform\}`/gu,
  ) || [];
  if (deviceDemoStages.length !== 1) {
    fail("release preflight must run each selected platform demo exactly once");
  }
}

export function validateClientGateTopology() {
  validatePackageTopology();
  validateCiTopology();
  validatePromotionTopology();
  validateReleaseTopology();
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
    process.stdout.write(`\n[client-gate:${lane}] npm run ${script}\n`);
    run("npm", ["run", script]);
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
