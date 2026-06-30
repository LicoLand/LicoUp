#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const reportPath = path.join(repoRoot, "build", "reports", "client-agent-usage-metering.json");
const failures = [];

function assert(condition, message) {
  if (!condition) failures.push(message);
}

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

const nativeUsage = await readText("crates/lico-client-native/src/agent_usage.rs");
const commandMod = await readText("crates/lico-client-native/src/commands/mod.rs");
const commandUsage = await readText("crates/lico-client-native/src/commands/agent_usage.rs");
const cliUsage = await readText("crates/lico-client-native/src/bin/lico-client.rs");
const stateStore = await readText("crates/lico-client-native/src/client_state.rs");
const dartService = await readText("apps/desktop/lib/src/services/agent_usage_service.dart");
const controller = await readText("apps/desktop/lib/src/controllers/future_client_controller.dart");
const controllerActions = await readText("apps/desktop/lib/src/controllers/agent_usage_actions.dart");
const usagePanel = await readText("apps/desktop/lib/src/ui/agent_usage_panel.dart");
const workspace = await readText("apps/desktop/lib/src/ui/agent_conversation_workspace.dart");
const serviceTest = await readText("apps/desktop/test/agent_usage_service_test.dart");
const controllerTest = await readText("apps/desktop/test/future_client_controller_test.dart");
const clientDocs = await readText("docs/functionality/CLIENT-DESKTOP.md");
const scenarioDocs = await readText("docs/scenarios/personal-user/client-priority-scenarios.md");

for (const token of [
  "agent-usage-metering",
  "Agent Usage Metering",
  "process network",
  "estimated historical"
]) {
  assert(clientDocs.includes(token) || scenarioDocs.includes(token),
    `client scenario docs must mention ${token}`);
}

for (const token of [
  "AGENT_USAGE_SCHEMA_VERSION",
  "processSamples",
  "estimatedHistoricalBytes",
  "tokenSourceBreakdown",
  "process_network_meter_unavailable",
  "agent-usage-reports"
]) {
  assert(nativeUsage.includes(token), `agent_usage.rs must include ${token}`);
}
assert(commandMod.includes("agent_usage::register_commands"), "command table must register agent_usage commands");
assert(commandUsage.includes('"agent-usage", "scan"') && commandUsage.includes('"agent-usage", "report"'),
  "agent_usage command module must expose scan and report");
assert(cliUsage.includes("agent-usage scan") && cliUsage.includes("agent-usage report"),
  "lico-client usage text must document agent-usage commands");
assert(stateStore.includes('"agent-usage-reports"'), "client state store must retain agent usage reports");

assert(dartService.includes("class AgentUsageService") &&
  dartService.includes("'agent-usage'") &&
  dartService.includes("'scan'") &&
  dartService.includes("'report'") &&
  dartService.includes("agentService.runCli"),
  "Dart AgentUsageService must delegate scan/report to lico-client");
assert(controller.includes("AgentUsageService") &&
  controller.includes("isScanningAgentUsage") &&
  controller.includes("isObservingAgentNetwork") &&
  controller.includes("agentUsageReport"),
  "controller must own agent usage state");
assert(controllerActions.includes("scanAgentUsage") &&
  controllerActions.includes("observeNetwork") &&
  controllerActions.includes("loadAgentUsageReports"),
  "controller actions must expose usage scan/report flows");
assert(usagePanel.includes("AgentUsagePanel") &&
  usagePanel.includes("Scan usage") &&
  usagePanel.includes("Observe network") &&
  usagePanel.includes("Estimated history"),
  "Agents UI must expose usage scan and process network observation");
assert(workspace.includes("AgentUsagePanel"), "Agents workspace must mount AgentUsagePanel");
assert(serviceTest.includes("agent-usage") && controllerTest.includes("agent usage scan updates controller state"),
  "Flutter tests must cover agent usage service and controller state");

const report = {
  ok: failures.length === 0,
  productionReady: false,
  generatedAt: new Date().toISOString(),
  artifactKind: "client-agent-usage-metering-evidence",
  scenario: "agent-usage-metering",
  nativeCommand: "agent-usage scan|report",
  ui: "Agents",
  documents: {
    clientDesktopScenarioCoverage: true,
    personalScenarioCoverage: true,
    processMeteringLabelsDocumented: true
  },
  nativeEvidence: {
    schemaVersion: nativeUsage.includes("AGENT_USAGE_SCHEMA_VERSION"),
    processSamples: nativeUsage.includes("processSamples"),
    estimatedHistoricalBytes: nativeUsage.includes("estimatedHistoricalBytes"),
    tokenSourceBreakdown: nativeUsage.includes("tokenSourceBreakdown"),
    unavailableProcessMeter: nativeUsage.includes("process_network_meter_unavailable"),
    retainedReports: nativeUsage.includes("agent-usage-reports")
  },
  cliEvidence: {
    commandRegistered: commandMod.includes("agent_usage::register_commands"),
    scanCommand: commandUsage.includes('"agent-usage", "scan"') && cliUsage.includes("agent-usage scan"),
    reportCommand: commandUsage.includes('"agent-usage", "report"') && cliUsage.includes("agent-usage report"),
    retainedStateCollection: stateStore.includes('"agent-usage-reports"')
  },
  uiEvidence: {
    serviceDelegatesToCli: dartService.includes("class AgentUsageService") && dartService.includes("agentService.runCli"),
    controllerOwnsState: controller.includes("AgentUsageService") && controller.includes("agentUsageReport"),
    actionsExposeFlows: controllerActions.includes("scanAgentUsage") && controllerActions.includes("loadAgentUsageReports"),
    panelMounted: workspace.includes("AgentUsagePanel"),
    panelControls: usagePanel.includes("Scan usage") && usagePanel.includes("Observe network")
  },
  testEvidence: {
    serviceTest: serviceTest.includes("agent-usage"),
    controllerTest: controllerTest.includes("agent usage scan updates controller state")
  },
  privacyEvidence: {
    aggregateOnly: clientDocs.includes("Aggregate per-agent session/message counts"),
    noPromptRetention: clientDocs.includes("does not store prompt text") || scenarioDocs.includes("does not store prompt text"),
    noRawPayloadRetention: clientDocs.includes("raw network payloads") || scenarioDocs.includes("raw network payloads"),
    unsupportedMetersUnavailable: scenarioDocs.includes("Unsupported process network providers return `unavailable`, not zero")
  },
  remainingProductionBlockers: [
    "Cross-platform live per-process network counters still need platform provider evidence beyond local injected/process-sample verification; historical traffic before observation remains estimated."
  ],
  failures
};

await fs.mkdir(path.dirname(reportPath), { recursive: true });
await fs.writeFile(reportPath, JSON.stringify(report, null, 2) + "\n");

if (failures.length > 0) {
  console.error(JSON.stringify(report, null, 2));
  process.exit(1);
}

console.log(JSON.stringify(report, null, 2));
