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
  const remoteReleaseStrategies = readJson("tools/client-remote-release-strategies.json");
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
    scripts["client:release:remote-strategy"] !==
    "node tools/scripts/client-remote-release-strategy.mjs"
  ) {
    fail("package.json must bind the canonical remote release strategy command");
  }
  if (
    remoteReleaseStrategies?.schemaVersion !==
      "licoup.client-remote-release-strategies.v1" ||
    remoteReleaseStrategies?.groupId !== "client-remote-release-validity" ||
    JSON.stringify(remoteReleaseStrategies?.activeStrategyIds) !==
      JSON.stringify(["build-success"]) ||
    remoteReleaseStrategies?.strategies?.length !== 1 ||
    remoteReleaseStrategies.strategies[0]?.id !== "build-success" ||
    remoteReleaseStrategies.strategies[0]?.releaseValidWhen !==
      "selected-target-build-command-succeeded" ||
    JSON.stringify(remoteReleaseStrategies.strategies[0]?.remoteValidationCommands) !==
      JSON.stringify([])
  ) {
    fail("remote release strategy group must activate only build-success");
  }
  if (
    scripts["client:verify:agent-conversations:release-ready"] !==
    "node tools/scripts/client-agent-conversation-parity-reducer.mjs --check --require-ready"
  ) {
    fail("package.json must bind the canonical conversation release-readiness gate");
  }
  for (const [lane, laneScripts] of Object.entries(CLIENT_GATE_LANES)) {
    for (const script of laneScripts) {
      if (!scripts[script]) {
        fail(`client gate lane ${lane} references missing package script ${script}`);
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
  for (const token of forbiddenSourceTokens) {
    assertExcludes(plan, token, `CI plan job must not contain ${token}`);
    assertExcludes(source, token, `CI source job must not contain ${token}`);
  }
  assertIncludes(
    source,
    "npm run client:gate:source",
    "CI source job must invoke the canonical source gate",
  );
  for (const lane of ["flutter", "rust", "android", "dependencies", "release-policy"]) {
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
    "needs: [source, flutter, rust, android, dependencies, release-policy]",
    "required CI reducer must observe every independent lane",
  );
  assertIncludes(required, "if: always()", "required CI reducer must always report lane failures");
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

function releaseOptions(workflow) {
  return [...inputBlock(workflow, "target").matchAll(/^\s{12}- ([a-z0-9-]+)$/gmu)]
    .map((match) => match[1]);
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
  const releaseEntry = readText("tools/scripts/client-release.mjs");
  const updateFinalizer = readText("tools/scripts/client-update-release-finalize.mjs");
  const catalog = readJson("tools/client-release-targets.json");
  const supportedTargets = catalog.targets
    .filter((target) => target.releaseSupported === true)
    .map((target) => target.id)
    .sort();
  const policyTargets = Object.keys(CLIENT_RELEASE_TARGETS).sort();
  const options = releaseOptions(workflow).sort();
  if (JSON.stringify(supportedTargets) !== JSON.stringify(policyTargets)) {
    fail("release target policy must exactly match releaseSupported catalog entries");
  }
  if (JSON.stringify(options) !== JSON.stringify(policyTargets)) {
    fail("release workflow target choice must exactly match releaseSupported targets");
  }
  const expectedInputs = ["release_tag", "target", "publish_release"].sort();
  if (JSON.stringify(releaseInputIds(workflow).sort()) !== JSON.stringify(expectedInputs)) {
    fail("release workflow must accept one target and bounded publication inputs");
  }
  const expectedJobs = [
    "preflight",
    ...Object.values(CLIENT_RELEASE_TARGETS)
      .flatMap((target) => [target.buildJob, target.publishJob]),
  ].sort();
  if (JSON.stringify(workflowJobIds(workflow).sort()) !== JSON.stringify(expectedJobs)) {
    fail("release workflow jobs must match the independent target topology");
  }
  const preflight = jobBlock(workflow, "preflight");
  for (const command of ["npm run ", "cargo ", "flutter "]) {
    assertExcludes(
      preflight,
      command,
      `remote release request validation must not repeat local gates: ${command.trim()}`,
    );
  }
  assertExcludes(workflow, "timeout-minutes:", "release workflow must use the platform default job timeout");
  const macosJob = jobBlock(workflow, "build-macos");
  for (const command of ["client:verify:", "client:gate:", "flutter test", "cargo test"]) {
    assertExcludes(
      macosJob,
      command,
      `GitHub-hosted macOS publication must build without repeating local validation: ${command}`,
    );
  }
  assertIncludes(
    macosJob,
    "name: licoup-macos-update",
    "macOS release build must preserve its independently signed update artifact",
  );
  for (const token of [
    "cp tools/install-macos.sh build/apps/desktop/distribution/macos/install-macos.sh",
    "build/apps/desktop/distribution/macos/install-macos.sh",
  ]) {
    assertIncludes(macosJob, token, `macOS release must publish the one-line installer: ${token}`);
  }
  for (const token of [
    'keyUsage=critical,digitalSignature',
    'sudo -n security add-trusted-cert -d -r trustRoot -p codeSign',
    '-k /Library/Keychains/System.keychain',
    'security find-identity -v -p codesigning',
    '"${existing_keychains[@]}"',
  ]) {
    assertIncludes(
      macosJob,
      token,
      `macOS release build must prepare a trusted ephemeral signing identity: ${token}`,
    );
  }
  for (const token of [
    "client-update-release-finalize.mjs",
    'publish_release=${options.publish && options.target !== "macos-arm64"}',
  ]) {
    assertIncludes(releaseEntry, token, `release entry is missing macOS update finalization: ${token}`);
  }
  for (const token of [
    "LicoUp-macos-arm64-update.tar.gz",
    "LicoUp-update-stable.json",
    "client-update-manifest-sign.mjs",
    "licoup-macos-update",
  ]) {
    assertIncludes(updateFinalizer, token, `macOS update finalizer is missing: ${token}`);
  }
  assertIncludes(
    workflow,
    "client-github-release-${{ inputs.release_tag }}-${{ inputs.target }}",
    "release builds must be concurrent across different targets",
  );
  const buildCommandByTarget = {
    "macos-arm64": "npm run client:install:macos",
    "linux-glibc-arm64": "npm run client:build:linux",
    "android-arm64": "npm run client:build:android",
  };
  for (const [target, topology] of Object.entries(CLIENT_RELEASE_TARGETS)) {
    const build = jobBlock(workflow, topology.buildJob);
    const publish = jobBlock(workflow, topology.publishJob);
    assertIncludes(
      build,
      `inputs.target == '${target}'`,
      `release build ${topology.buildJob} must be selected only by ${target}`,
    );
    assertIncludes(
      build,
      `LICO_CLIENT_RELEASE_TARGETS: ${target}`,
      `release build ${topology.buildJob} must bind its target acceptance`,
    );
    assertIncludes(
      build,
      "needs: preflight",
      `release build ${topology.buildJob} must depend on the unified preflight`,
    );
    const buildCommand = buildCommandByTarget[target];
    const strategyCommand =
      "npm run client:release:remote-strategy -- --expect build-success";
    assertIncludes(build, buildCommand,
      `release build ${topology.buildJob} must execute its selected-target build`);
    assertIncludes(build, strategyCommand,
      `release build ${topology.buildJob} must apply the active build-success strategy`);
    if (build.indexOf(strategyCommand) < build.indexOf(buildCommand)) {
      fail(`release build ${topology.buildJob} applies its strategy before the build succeeds`);
    }
    for (const command of [
      "client:verify:",
      "client:gate:",
      "flutter test",
      "cargo test",
      "gradlew test",
      "client:linux:smoke",
      "client:linux:gui-smoke",
    ]) {
      assertExcludes(
        build,
        command,
        `remote release strategy build-success forbids validation command: ${command}`,
      );
    }
    assertIncludes(
      publish,
      `inputs.target == '${target}'`,
      `release publisher ${topology.publishJob} must be selected only by ${target}`,
    );
    assertIncludes(
      publish,
      `needs: [preflight, ${topology.buildJob}]`,
      `release publisher ${topology.publishJob} must wait only for its own build`,
    );
    assertIncludes(
      publish,
      "client-github-release-publish-${{ inputs.release_tag }}",
      `release publisher ${topology.publishJob} must serialize only same-tag metadata updates`,
    );
    assertIncludes(
      publish,
      `name: ${topology.artifactName}`,
      `release publisher ${topology.publishJob} must consume only its own artifact`,
    );
    assertIncludes(
      publish,
      "client-github-release-publish.mjs",
      `release publisher ${topology.publishJob} must use the canonical append-only publisher`,
    );
    for (const other of Object.values(CLIENT_RELEASE_TARGETS)) {
      if (other.buildJob !== topology.buildJob) {
        assertExcludes(
          publish.split("\n    steps:")[0],
          other.buildJob,
          `release publisher ${topology.publishJob} must not wait for ${other.buildJob}`,
        );
      }
    }
  }
  for (const token of [
    "client-consumer-verification-manifest.mjs",
    "client-release-remote-asset-set.mjs",
    "--clobber",
    "COPYFILE_EXCL",
    "release.targetCommitish !== sourceSha",
  ]) {
    assertIncludes(
      publisher,
      token,
      `canonical release publisher is missing safety token: ${token}`,
    );
  }
}

export function validateClientGateTopology() {
  validatePackageTopology();
  validateCiTopology();
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
  let releaseTarget = null;
  if (paths.includes("tools/client-version.json")) {
    const manifest = spawnSync("git", ["show", `${validateRevision(revisions.head, "head")}:tools/client-version.json`], {
      cwd: repoRoot,
      encoding: "utf8",
      shell: false,
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (manifest.status === 0) {
      try { releaseTarget = JSON.parse(manifest.stdout).releaseTarget || null; } catch { fail("client release target manifest is invalid"); }
    }
  }
  const plan = classifyClientGatePaths(paths, { releaseTarget });
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
