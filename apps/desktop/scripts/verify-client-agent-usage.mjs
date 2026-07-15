#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { atomicWriteReportJson } from "../../../tools/scripts/lib/safe-report-io.mjs";

const repoRoot = path.resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const reportRef = "build/reports/client-agent-usage-metering.json";
const failures = [];

function assert(condition, message) {
  if (!condition) failures.push(message);
}

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function readJoinedText(relativePaths) {
  return (await Promise.all(relativePaths.map((relativePath) => readText(relativePath)))).join("\n");
}

const nativeUsage = await readText("crates/lico-client-native/src/domain/agent_usage.rs");
const codexUsageCache = await readText(
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex.rs"
);
const commandMod = await readText("crates/lico-client-native/src/ffi/commands/mod.rs");
const commandUsage = await readText("crates/lico-client-native/src/ffi/commands/agent_usage.rs");
const cliUsage = await readText("crates/lico-client-native/src/bin/lico-client.rs");
const stateStore = await readText("crates/lico-client-native/src/platform/client_state.rs");
const dartService = await readText("apps/desktop/lib/src/backend/features/agents/services/agent_usage_service.dart");
const usageModels = await readText("apps/desktop/lib/src/contracts/agent_usage_models.dart");
const controller = await readText("apps/desktop/lib/src/application/controller/client_controller.dart");
const controllerActions = await readJoinedText([
  "apps/desktop/lib/src/application/features/agents/controller/agent_usage_actions.dart",
  "apps/desktop/lib/src/application/features/agents/controller/agent_usage_scan_actions.dart"
]);
const usagePanel = await readJoinedText([
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_panel.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart"
]);
const usagePricing = await readText(
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_pricing.dart"
);
const clientShell = await readText("apps/desktop/lib/src/frontend/shell/client_shell.dart");
const workspace = await readText("apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_workspace.dart");
const serviceTest = await readText("apps/desktop/test/agent_usage_service_test.dart");
const controllerTest = await readText("apps/desktop/test/client_controller_test.dart");
const incrementalCacheTest = await readText(
  "crates/lico-client-native/tests/agent_usage_incremental_cache.rs"
);
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
  "account_allowances_for",
  "claude-weekly-limit",
  "antigravity-gemini-weekly-limit",
  "tokenSourceBreakdown",
  "modelTokenUsage",
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
assert(nativeUsage.includes("const AGENT_USAGE_SCHEMA_VERSION: u32 = 2") &&
  nativeUsage.includes("is_current_report") &&
  nativeUsage.includes("sort_reports_by_generated_at"),
  "native reports must enforce the current schema and sort retained reports by timestamp");
for (const token of [
  "journal_mode",
  "parsed_bytes",
  "raw_totals",
  "counted_totals",
  "cached_input_tokens",
  "usage_rows",
  "usage_estimates",
  "usage_estimate_coverage",
  "event_identity",
  "token_chain_hash",
  "estimate_chain_hash",
  "append_guard",
  "lineage_scope",
  "refreshDeferred",
  "forceRefresh"
]) {
  assert(codexUsageCache.includes(token), `Codex usage cache must include ${token}`);
}

assert(dartService.includes("class AgentUsageService") &&
  dartService.includes("'agent-usage'") &&
  dartService.includes("'scan'") &&
  dartService.includes("'report'") &&
  dartService.includes("agentService.runCli"),
  "Dart AgentUsageService must delegate scan/report to lico-client");
assert(dartService.includes("--timezone-transitions-json") &&
  nativeUsage.includes("timezoneTransitionsJson"),
  "GUI and native usage windows must exchange historical timezone transitions");
assert(usageModels.includes("currentSchemaVersion = 2") &&
  usageModels.includes("schemaVersion != currentSchemaVersion"),
  "Flutter report parsing must accept only the current usage schema");
assert(nativeUsage.includes('"usageUnit": "credits"') &&
  !usagePanel.includes("totalCreditsUsed"),
  "billing credits must remain separate from token chart values");
assert(controller.includes("AgentUsageService") &&
  controller.includes("isScanningAgentUsage") &&
  controller.includes("_agentUsagePollingTimer") &&
  controller.includes("agentUsageReport"),
  "controller must own agent usage state");
assert(controllerActions.includes("scanAgentUsage") &&
  controllerActions.includes("startAgentUsagePolling") &&
  controllerActions.includes("stopAgentUsagePolling") &&
  controllerActions.includes("showProgress: false") &&
  controllerActions.includes("loadAgentUsageReports"),
  "controller actions must expose lifecycle-safe usage polling and scan/report flows");
assert(usagePanel.includes("AgentUsagePanel") &&
  usagePanel.includes("strings.tokenUsage") &&
  usagePanel.includes("strings.totalTokens") &&
  usagePanel.includes("modelTokenUsage") &&
  usagePanel.includes("strings.apiPriceEstimate") &&
  clientShell.includes("ClientSection.monitoring => AgentUsagePanel") &&
  workspace.includes("AgentsWorkspaceDestination.stats => AgentUsagePanel") &&
  usagePanel.includes("startAgentUsagePolling") &&
  usagePanel.includes("ensureAgentUsageLoadedAndFresh"),
  "Agents UI must use dedicated full-width token-usage routes with model pricing and lifecycle polling");
assert(usagePricing.includes("billableUncachedInputTokens") &&
  usagePricing.includes("cachedInputUsdPerMillion") &&
  usagePricing.includes("AgentUsageApiPriceEstimate.unavailable") &&
  usagePricing.includes("verifiedOn"),
  "API price estimates must separate cached input and fail closed for unpriced usage");
assert(workspace.includes("AgentsWorkspaceDestination.stats => AgentUsagePanel"),
  "Agents workspace statistics destination must render the dedicated usage panel");
assert(serviceTest.includes("agent-usage") && controllerTest.includes("agent usage background scan updates token and traffic"),
  "Flutter tests must cover agent usage service and controller state");
for (const token of [
  "codex_usage_deduplicates_forked_rollout_prefix_before_window_filtering",
  "codex_usage_counts_identical_events_from_independent_sessions",
  "codex_usage_explicit_copy_covers_estimate_from_incomplete_copy",
  "codex_usage_noop_events_do_not_split_copy_identity",
  "codex_usage_rewrite_to_larger_same_file_forces_full_rescan",
  "codex_usage_detects_middle_rewrite_before_append_in_large_file",
  "codex_usage_force_refresh_detects_equal_metadata_rewrite",
  "codex_usage_returns_cached_snapshot_when_same_root_refresh_is_busy",
  "codex_usage_merges_uncovered_session_estimates_with_explicit_events",
  "retained_reports_persist_only_aggregate_process_metrics",
  "generic_usage_extractor_keeps_cached_input_as_a_subset",
  "generic_usage_extractor_projects_parent_usage_once_for_content_blocks",
  "codex_usage_applies_historical_timezone_transitions_per_event"
]) {
  assert(incrementalCacheTest.includes(token), `integration tests must cover ${token}`);
}

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
    accountAllowances: nativeUsage.includes("account_allowances_for"),
    claudeAllowance: nativeUsage.includes("claude-weekly-limit"),
    antigravityAllowance: nativeUsage.includes("antigravity-gemini-weekly-limit"),
    tokenSourceBreakdown: nativeUsage.includes("tokenSourceBreakdown"),
    modelTokenUsage: nativeUsage.includes("modelTokenUsage"),
    platformUnavailableFallback: nativeUsage.includes('"platform-unavailable"'),
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
    panelMounted: usagePanel.includes("AgentUsagePanel"),
    apiPriceEstimate: usagePanel.includes("strings.apiPriceEstimate") &&
      usagePricing.includes("billableUncachedInputTokens"),
    dedicatedRoutesAndPolling:
      clientShell.includes("ClientSection.monitoring => AgentUsagePanel") &&
      workspace.includes("AgentsWorkspaceDestination.stats => AgentUsagePanel") &&
      usagePanel.includes("startAgentUsagePolling"),
    currentUsageRoutes:
      clientShell.includes("ClientSection.monitoring => AgentUsagePanel") &&
      workspace.includes("AgentsWorkspaceDestination.stats => AgentUsagePanel")
  },
  testEvidence: {
    serviceTest: serviceTest.includes("agent-usage"),
    controllerTest: controllerTest.includes("agent usage background scan updates token and traffic"),
    forkPrefixDedup: incrementalCacheTest.includes("codex_usage_deduplicates_forked_rollout_prefix_before_window_filtering"),
    independentSessionIsolation: incrementalCacheTest.includes("codex_usage_counts_identical_events_from_independent_sessions"),
    crossCopyEstimateCoverage: incrementalCacheTest.includes("codex_usage_explicit_copy_covers_estimate_from_incomplete_copy"),
    noOpStableIdentity: incrementalCacheTest.includes("codex_usage_noop_events_do_not_split_copy_identity"),
    rewriteGenerationGuard: incrementalCacheTest.includes("codex_usage_rewrite_to_larger_same_file_forces_full_rescan"),
    fullPrefixGenerationGuard: incrementalCacheTest.includes("codex_usage_detects_middle_rewrite_before_append_in_large_file"),
    equalMetadataGenerationGuard: incrementalCacheTest.includes("codex_usage_force_refresh_detects_equal_metadata_rewrite"),
    busySnapshotFallback: incrementalCacheTest.includes("codex_usage_returns_cached_snapshot_when_same_root_refresh_is_busy"),
    mixedCoverage: incrementalCacheTest.includes("codex_usage_merges_uncovered_session_estimates_with_explicit_events"),
    contentBlockUsageProjection: incrementalCacheTest.includes("generic_usage_extractor_projects_parent_usage_once_for_content_blocks"),
    aggregateProcessPrivacy: incrementalCacheTest.includes("retained_reports_persist_only_aggregate_process_metrics")
  },
  privacyEvidence: {
    aggregateOnly: clientDocs.includes("Aggregate per-agent session/message counts"),
    noPromptRetention: clientDocs.includes("does not store prompt text") ||
      scenarioDocs.includes("does not store prompt text") ||
      scenarioDocs.includes("do not store prompt text"),
    noRawPayloadRetention: clientDocs.includes("raw network payloads") || scenarioDocs.includes("raw network payloads"),
    unsupportedMetersUnavailable: scenarioDocs.includes("Unsupported process network providers return `unavailable`, not zero")
  },
  remainingProductionBlockers: [
    "Cross-platform live per-process network counters still need platform provider evidence beyond local injected/process-sample verification; traffic without samples remains estimated."
  ],
  failures
};

atomicWriteReportJson(repoRoot, reportRef, report);

if (failures.length > 0) {
  console.error(JSON.stringify(report, null, 2));
  process.exit(1);
}

console.log(JSON.stringify(report, null, 2));
