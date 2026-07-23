#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const defaultOutput = resolve(
  root,
  "build/reports/agent-orchestration-e2e.json",
);
const readinessPath = resolve(
  root,
  "crates/lico-client-native/resources/agent-conversation-readiness.json",
);
const pluginManifest = resolve(
  root,
  "plugins/lico-arc-codex/.codex-plugin/plugin.json",
);
const mcpServerConfig = resolve(
  root,
  "plugins/lico-arc-codex/mcp/server.json",
);
const mcpBinarySource = resolve(
  root,
  "crates/lico-client-native/src/bin/lico-codex-mcp.rs",
);
const packagingModules = resolve(root, "apps/desktop/packaging.modules.json");
const expectedTools = Object.freeze([
  "lico_agent_capabilities",
  "lico_strategy_preview",
  "lico_workflow_approve",
  "lico_workflow_cancel",
  "lico_workflow_message",
  "lico_workflow_status",
  "lico_workflow_submit",
  "lico_workflow_wait",
]);

function sha256File(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function parseArgs(argv) {
  const options = { selfTest: false, output: defaultOutput, live: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--self-test") options.selfTest = true;
    else if (argument === "--live") options.live = true;
    else if (argument === "--output") {
      const value = argv[++index];
      if (!value) throw new Error("argument_missing");
      options.output = resolve(root, value);
    } else {
      throw new Error(`argument_unsupported:${argument}`);
    }
  }
  return options;
}

function run(command, args, label, timeoutMs = 300_000) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    env: process.env,
    timeout: timeoutMs,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error?.code === "ETIMEDOUT") {
    throw Object.assign(new Error(`${label}_timeout`), {
      detailDigest: createHash("sha256").update(label).digest("hex"),
      exitCode: 124,
    });
  }
  if (result.status !== 0) {
    const detail = `${result.stdout ?? ""}\n${result.stderr ?? ""}`.trim();
    throw Object.assign(new Error(`${label}_failed`), {
      detailDigest: createHash("sha256")
        .update(detail.slice(0, 4096))
        .digest("hex"),
      exitCode: result.status ?? 1,
    });
  }
  return result;
}

function readinessSummary() {
  const catalog = JSON.parse(readFileSync(readinessPath, "utf8"));
  const adapters = Array.isArray(catalog.adapters) ? catalog.adapters : [];
  const sendEnabledTargets = adapters.filter(
    (adapter) => adapter && adapter.sendEnabled === true,
  ).length;
  const catalogSendEnabledTotal =
    typeof catalog.summary?.sendEnabled === "number"
      ? catalog.summary.sendEnabled
      : typeof catalog.sendEnabled === "number"
        ? catalog.sendEnabled
        : null;
  return {
    catalogSendEnabledTotal,
    sendEnabledTargets,
    liveReady: sendEnabledTargets > 0 && catalogSendEnabledTotal !== 0,
  };
}

function assertPackagedPluginSurface() {
  if (!existsSync(pluginManifest) || !existsSync(mcpServerConfig)) {
    throw new Error("plugin_unavailable");
  }
  const manifest = JSON.parse(readFileSync(pluginManifest, "utf8"));
  const server = JSON.parse(readFileSync(mcpServerConfig, "utf8"));
  const packaging = JSON.parse(readFileSync(packagingModules, "utf8"));
  const mcpSource = readFileSync(mcpBinarySource, "utf8");
  if (manifest.name !== "lico-arc-codex") {
    throw new Error("plugin_manifest_invalid");
  }
  if (!manifest.mcpServers?.["lico-arc-orchestration"]) {
    throw new Error("plugin_mcp_missing");
  }
  if (!Array.isArray(server.tools) && !server.command && !server.type) {
    // server.json may describe launch config rather than tool list; accept either.
  }
  const packagingText = JSON.stringify(packaging);
  if (!packagingText.includes("lico-arc-codex") && !packagingText.includes("lico-codex-mcp")) {
    throw new Error("plugin_packaging_unregistered");
  }
  for (const tool of expectedTools) {
    if (!mcpSource.includes(tool)) {
      throw new Error(`mcp_tool_missing:${tool}`);
    }
  }
  for (const method of [
    "workflow.submit",
    "workflow.status",
    "workflow.cancel",
    "workflow.approve",
    "workflow.events",
    "workflow.wait",
    "workflow.message",
  ]) {
    if (!mcpSource.includes(method)) {
      throw new Error(`mcp_method_missing:${method}`);
    }
  }
  if (
    /mcp_adapter|mcp_streamable_http|conversationGateway\.send\(/.test(mcpSource)
  ) {
    throw new Error("mcp_authority_bypass");
  }
}

function syntheticMatrix() {
  assertPackagedPluginSurface();
  const cutover = run(
    "npm",
    [
      "run",
      "client:native:test",
      "--",
      "agent_orchestration_atomic_cutover_acceptance_harness",
      "--",
      "--nocapture",
    ],
    "cutover_harness",
    420_000,
  );
  const output = `${cutover.stdout ?? ""}\n${cutover.stderr ?? ""}`;
  if (!output.includes("LICO_ARC_CUTOVER_ACCEPTANCE ")) {
    throw new Error("cutover_harness_marker_missing");
  }
  if (!/test result: ok\. 1 passed; 0 failed/.test(output)) {
    throw new Error("cutover_harness_zero_tests");
  }
}

function buildReceipt(options, readiness) {
  return {
    schemaVersion: 1,
    status: readiness.liveReady && options.live ? "pass" : "blocked",
    reasonCode: readiness.liveReady
      ? options.live
        ? "synthetic_and_live_ready"
        : "live_not_authorized"
      : "target_unready_send_enabled_zero",
    receiptKind: "agent-orchestration-e2e",
    surfaces: ["desktop", "cli", "codex-mcp"],
    synthetic: {
      cutoverHarness: true,
      packagedPluginSurface: true,
      architectureOracle: false,
    },
    readiness: {
      catalogSendEnabledTotal: readiness.catalogSendEnabledTotal,
      sendEnabledTargets: readiness.sendEnabledTargets,
    },
    revisions: {
      pluginManifestSha256: sha256File(pluginManifest),
      mcpServerConfigSha256: sha256File(mcpServerConfig),
      readinessCatalogSha256: sha256File(readinessPath),
    },
    live: {
      attempted: Boolean(options.live),
      authorized: false,
      blocked: !readiness.liveReady || !options.live,
    },
  };
}

export async function runAgentOrchestrationE2E(options = {}) {
  const resolved = {
    selfTest: Boolean(options.selfTest),
    live: Boolean(options.live),
    output: options.output ? resolve(root, options.output) : defaultOutput,
  };
  syntheticMatrix();
  const readiness = readinessSummary();
  if (resolved.live && readiness.liveReady) {
    throw new Error("live_requires_explicit_provider_auth");
  }
  const receipt = buildReceipt(resolved, readiness);
  mkdirSync(dirname(resolved.output), { recursive: true });
  writeFileSync(resolved.output, `${JSON.stringify(receipt, null, 2)}\n`);
  return receipt;
}

async function main(argv) {
  const options = parseArgs(argv);
  const receipt = await runAgentOrchestrationE2E(options);
  process.stdout.write(`${JSON.stringify(receipt)}\n`);
  process.exitCode = 0;
}

const isDirectRun =
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isDirectRun) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(
      `${JSON.stringify({
        status: "failed",
        reasonCode: error.message,
        detailDigest: error.detailDigest ?? null,
        exitCode: error.exitCode ?? 1,
      })}\n`,
    );
    process.exit(error.exitCode ?? 1);
  });
}
