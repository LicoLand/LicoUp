#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  RELEASE_CLOSURE_CHALLENGE_ENV,
  createReleaseClosureChallenge,
} from "./lib/release-closure-challenge.mjs";
import { loadClientReleaseTargetCatalog } from "./lib/client-release-targets.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const schemaVersion = "licoup.device-demo.v2";
const defaultAgent = "codex";
const implementedPlatforms = new Set(["macos"]);

export const DEVICE_DEMO_PLATFORMS = Object.freeze([
  ...new Set(loadClientReleaseTargetCatalog().targets
    .filter((target) => target.packageBuildSupported === true)
    .map((target) => target.platform)),
]);

function fail(code) {
  throw new Error(code);
}

export function parseDeviceDemoArgs(argv) {
  const options = { agents: [], platform: "", selfTest: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--self-test") {
      options.selfTest = true;
    } else if (argument === "--platform") {
      const platform = String(argv[index + 1] || "").trim().toLowerCase();
      if (!DEVICE_DEMO_PLATFORMS.includes(platform) || options.platform) {
        fail("device_demo_platform_invalid");
      }
      options.platform = platform;
      index += 1;
    } else if (argument === "--agent") {
      const agent = String(argv[index + 1] || "")
        .trim()
        .toLowerCase()
        .replaceAll("_", "-");
      if (!/^[a-z0-9-]{1,64}$/u.test(agent)) fail("device_demo_agent_invalid");
      options.agents.push(agent);
      index += 1;
    } else {
      fail("device_demo_argument_unsupported");
    }
  }
  if (options.selfTest && (options.agents.length > 0 || options.platform)) {
    fail("device_demo_argument_conflict");
  }
  if (!options.selfTest && !options.platform) fail("device_demo_platform_required");
  options.agents = [...new Set(options.agents.length > 0 ? options.agents : [defaultAgent])];
  return Object.freeze({
    agents: Object.freeze(options.agents),
    platform: options.platform,
    selfTest: options.selfTest,
  });
}

export function buildDeviceDemoInvocation(platform, agents, challenge) {
  if (!implementedPlatforms.has(platform)) fail("device_demo_platform_unavailable");
  const args = ["tools/scripts/client-agent-conversation-product-e2e.mjs"];
  for (const agent of agents) args.push("--agent", agent);
  return Object.freeze({
    command: process.execPath,
    args: Object.freeze(args),
    environment: Object.freeze({
      ...process.env,
      [RELEASE_CLOSURE_CHALLENGE_ENV]: challenge,
    }),
  });
}

export function deviceDemoReceipt(payload, platform, expectedAgents) {
  const testedAgents = Array.isArray(payload?.testedAgents) ? payload.testedAgents : [];
  const testedAgentIds = testedAgents.map((entry) => entry?.agentId);
  const passed = payload?.status === "passed"
    && payload?.receiptKind === "release-ui-live-product"
    && payload?.productHarnessKind === "packaged-release-app-live-runtime"
    && payload?.fixtureBackend === false
    && payload?.productLivePassed === true
    && payload?.externalRuntimeInvoked === true
    && payload?.cleanupPassed === true
    && payload?.composerSubmitted === true
    && payload?.historyReadback === true
    && JSON.stringify(testedAgentIds) === JSON.stringify(expectedAgents)
    && testedAgents.every((entry) =>
      entry?.productLivePassed === true && entry?.cleanupPassed === true);
  return Object.freeze({
    schemaVersion,
    group: `device-demo:${platform}`,
    platform,
    status: passed ? "passed" : "failed",
    scenarioCount: 1,
    testedAgentCount: testedAgents.length,
    externalRuntimeInvoked: payload?.externalRuntimeInvoked === true,
    replyReadbackVerified: payload?.historyReadback === true,
    sessionCleanupVerified: payload?.cleanupPassed === true,
    privateDataIncluded: false,
  });
}

function selfTest() {
  const options = parseDeviceDemoArgs(["--platform", "macos"]);
  const invocation = buildDeviceDemoInvocation(
    options.platform,
    options.agents,
    "challenge-fixture",
  );
  const receipt = deviceDemoReceipt({
    status: "passed",
    receiptKind: "release-ui-live-product",
    productHarnessKind: "packaged-release-app-live-runtime",
    fixtureBackend: false,
    productLivePassed: true,
    externalRuntimeInvoked: true,
    cleanupPassed: true,
    composerSubmitted: true,
    historyReadback: true,
    testedAgents: [{ agentId: defaultAgent, productLivePassed: true, cleanupPassed: true }],
  }, "macos", [defaultAgent]);
  const failed = deviceDemoReceipt({ status: "failed" }, "macos", [defaultAgent]);
  let unsupportedPlatformRejected = false;
  try {
    buildDeviceDemoInvocation("android", [defaultAgent], "challenge-fixture");
  } catch (error) {
    unsupportedPlatformRejected = error?.message === "device_demo_platform_unavailable";
  }
  const passed = options.platform === "macos"
    && options.agents[0] === defaultAgent
    && DEVICE_DEMO_PLATFORMS.length === 5
    && invocation.args.some((argument) =>
      argument.endsWith("client-agent-conversation-product-e2e.mjs"))
    && invocation.environment[RELEASE_CLOSURE_CHALLENGE_ENV] === "challenge-fixture"
    && receipt.status === "passed"
    && receipt.platform === "macos"
    && failed.status === "failed"
    && unsupportedPlatformRejected;
  return {
    schemaVersion: `${schemaVersion}.self-test`,
    status: passed ? "passed" : "failed",
    realRuntimeInvoked: false,
  };
}

function run(options) {
  const invocation = buildDeviceDemoInvocation(
    options.platform,
    options.agents,
    createReleaseClosureChallenge(),
  );
  const execution = spawnSync(invocation.command, invocation.args, {
    cwd: repoRoot,
    env: invocation.environment,
    encoding: "utf8",
    timeout: 60 * 60 * 1000,
    maxBuffer: 2 * 1024 * 1024,
  });
  let payload = null;
  try {
    payload = JSON.parse(String(execution.stdout || "").trim());
  } catch {
    // The public receipt below remains bounded and never republishes raw output.
  }
  const receipt = deviceDemoReceipt(payload, options.platform, options.agents);
  if (execution.status !== 0 || execution.error || receipt.status !== "passed") {
    return { ...receipt, status: "failed" };
  }
  return receipt;
}

let receipt;
try {
  const options = parseDeviceDemoArgs(process.argv.slice(2));
  receipt = options.selfTest ? selfTest() : run(options);
} catch (error) {
  const reasonCode = /^[a-z0-9_-]{1,96}$/u.test(error?.message || "")
    ? error.message
    : "device_demo_failed";
  receipt = {
    schemaVersion,
    group: "device-demo",
    status: "failed",
    reasonCode,
    privateDataIncluded: false,
  };
}

process.stdout.write(`${JSON.stringify(receipt)}\n`);
if (receipt.status !== "passed") process.exitCode = 1;
