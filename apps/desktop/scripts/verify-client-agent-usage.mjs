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

function assertIncludes(source, tokens, label) {
  for (const token of tokens) {
    assert(source.includes(token), `${label} must include ${token}`);
  }
}

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), "utf8");
}

async function readJoinedText(relativePaths) {
  return (await Promise.all(relativePaths.map((relativePath) => readText(relativePath)))).join("\n");
}

const nativeUsage = await readJoinedText([
  "crates/lico-client-native/src/domain/agent_usage.rs",
  "crates/lico-client-native/src/domain/agent_usage/attribution.rs",
  "crates/lico-client-native/src/domain/agent_usage/command.rs",
  "crates/lico-client-native/src/domain/agent_usage/contract.rs",
  "crates/lico-client-native/src/domain/agent_usage/persistence.rs",
  "crates/lico-client-native/src/domain/agent_usage/window.rs",
  "crates/lico-client-native/src/domain/agent_usage/tests.rs"
]);
const codexUsageCache = await readJoinedText([
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/aggregation.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/append_guard.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/cache.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/cache_batch.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/cache_cleanup.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/constants.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/event_hash.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/file_collection.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/lineage.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/models.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/parser.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/rollup.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/scan.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/scan_params.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex/utils.rs",
]);
const nativeUsageCache = await readJoinedText([
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_native.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_native/cache.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_native/files.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_native/models.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_native/parser.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_native/parser/cursor.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_native/parser/hermes.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_native/parser/openagent.rs",
  "crates/lico-client-native/src/domain/agent_usage/agent_usage_native/watermark.rs",
]);
const commandMod = await readText("crates/lico-client-native/src/ffi/commands/mod.rs");
const commandUsage = await readText("crates/lico-client-native/src/ffi/commands/agent_usage.rs");
const cliUsage = await readJoinedText([
  "crates/lico-client-native/src/bin/lico-client.rs",
  "crates/lico-client-native/src/bin/lico-client/presentation.rs"
]);
const stateStore = await readJoinedText([
  "crates/lico-client-native/src/platform/client_state.rs",
  "crates/lico-client-native/src/platform/client_state/policy.rs",
]);
const dartService = await readText(
  "apps/desktop/lib/src/backend/features/agents/services/agent_usage_service.dart"
);
const usageModels = await readText("apps/desktop/lib/src/contracts/agent_usage_models.dart");
const usageGateway = await readText(
  "apps/desktop/lib/src/application/features/agents/contracts/agent_usage_gateway.dart"
);
const usageController = await readText(
  "apps/desktop/lib/src/application/features/agents/controller/agent_usage_controller.dart"
);
const usagePanel = await readJoinedText([
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_panel.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_summary_widgets.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline_data.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_formatters.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_models.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_builder.dart",
  "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_token_breakdown.dart",
]);
const clientShell = await readText("apps/desktop/lib/src/frontend/shell/client_shell.dart");
const serviceTest = await readText("apps/desktop/test/agent_usage_service_test.dart");
const controllerTest = await readText("apps/desktop/test/agent_usage_controller_test.dart");
const componentTest = await readText("apps/desktop/test/agent_usage_component_boundary_test.dart");
const chartTests = await readJoinedText([
  "apps/desktop/test/agent_usage_charts_test.dart",
  "apps/desktop/test/agent_usage_timeline/agent_usage_timeline_builder_test.dart",
  "apps/desktop/test/agent_usage_summary_widgets_test.dart",
  "apps/desktop/test/agent_usage_formatters_test.dart"
]);
const functionalityDocs = await readText(
  "docs/functionality/CLIENT-DESKTOP.md"
);
const incrementalCacheTest = await readJoinedText([
  "crates/lico-client-native/tests/agent_usage_incremental_cache.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/adapter_coverage.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/append_refresh.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/cache_runtime.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/cumulative_resume.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/dedup_lineage.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/fallback_coverage.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/generic_usage.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/native_rollup.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/reconciliation.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/retained_reports.rs",
  "crates/lico-client-native/tests/agent_usage_cache_cases/windows.rs",
]);
assertIncludes(
  nativeUsage,
  [
    "const AGENT_USAGE_SCHEMA_VERSION: u32 = 6",
    'const AGENT_USAGE_MODE: &str = "local-token-usage"',
    'const AGENT_USAGE_TOKEN_SOURCE_MODE: &str = "native-metadata-first-incremental"',
    "const DEFAULT_USAGE_WINDOW_DAYS: u64 = 30",
    '.get("historyDays")',
    ".clamp(1, MAX_USAGE_WINDOW_DAYS)",
    '"tokenSourceBreakdown"',
    '"modelTokenUsage"',
    "summarize_sessions",
    "estimate_tokens",
    "UsageAccuracy::Estimated",
    "is_current_report",
    "sort_reports_by_generated_at",
    "private-local-prompt-canary"
  ],
  "native local-token usage authority"
);
assert(
  nativeUsage.includes('assert!(!serialized.contains("private-local-prompt-canary"))'),
  "native usage tests must prove prompt content is not retained"
);
assertIncludes(
  codexUsageCache,
  [
    "journal_mode",
    "parsed_bytes",
    "raw_totals",
    "counted_totals",
    "cached_input_tokens",
    "usage_rows",
    "event_identity",
    "token_chain_hash",
    "append_guard",
    "lineage_scope",
    "usage_daily_totals",
    "usage_daily_models",
    "compact_historical_details",
    "remove_obsolete_cache_databases",
    "VACUUM",
    "refreshDeferred",
    "forceRefresh"
  ],
  "Codex local usage cache"
);

assert(
  commandMod.includes("agent_usage::register_commands"),
  "command table must register local agent usage commands"
);
assertIncludes(
  nativeUsageCache,
  [
    "native_usage_sources",
    "native_usage_daily_totals",
    "native_usage_daily_models",
    "parse_append_source",
    "parse_openagent_usage_database",
    "parse_cursor_usage_database",
    "parse_hermes_usage_database",
    "append_guard_matches",
    "seal_source",
    "compact_source_days_before",
    "apply_cumulative_watermarks",
    "incremental_vacuum",
    "estimated_records",
    "agent-usage-rollups-v2.sqlite3",
    "remove_legacy_cache",
  ],
  "shared metadata-first native usage cache"
);
for (const forbidden of ["raw_content", "message_content"]) {
  assert(!nativeUsageCache.includes(forbidden), `native usage cache must exclude ${forbidden}`);
}
assert(
  commandUsage.includes('"agent-usage", "scan"') &&
    commandUsage.includes('"agent-usage", "report"'),
  "native command adapter must expose scan and report"
);
assert(
  cliUsage.includes("agent-usage scan") && cliUsage.includes("agent-usage report"),
  "CLI help must document local agent usage commands"
);
assert(
  stateStore.includes('"agent-usage-reports"'),
  "local client state must retain bounded usage reports"
);

assertIncludes(
  dartService,
  [
    "class AgentUsageService",
    "int historyDays = 90",
    "historyDays.clamp(1, 90)",
    "--timezone-transitions-json",
    "AgentUsageReport.currentSchemaVersion",
    "AgentUsageReport.currentMode",
    "AgentUsageReport.currentTokenSourceMode"
  ],
  "Dart local usage service"
);
assert(
  dartService.includes("agentService.runCli(args)"),
  "Dart local usage service must use the native client command boundary"
);
assertIncludes(
  usageModels,
  [
    "static const currentSchemaVersion = 6",
    "static const currentMode = 'local-token-usage'",
    "static const currentTokenSourceMode = 'native-metadata-first-incremental'",
    "validateEnvelope",
    "schemaVersion is! int",
    "totalTokens"
  ],
  "Flutter usage contract"
);
assertIncludes(
  usageGateway,
  ["abstract interface class AgentUsageGateway", "Future<AgentUsageReport> scan", "Future<List<AgentUsageReport>> reports"],
  "usage application port"
);
assertIncludes(
  usageController,
  [
    "class AgentUsageController",
    "defaultAgentUsageScanHistoryDays = agentUsageDailyCacheMaxDays",
    "defaultAgentUsageDisplayHistoryDays = 30",
    "hasFreshScanCoverage",
    "projectViewport",
    "_applyViewport",
    "acquirePollingOwner",
    "releasePollingOwner",
    "_pollingOwners",
    "_refreshFuture",
    "_scanFuture",
    "showProgress: false",
    "List.unmodifiable"
  ],
  "usage application controller"
);
assertIncludes(
  usagePanel,
  [
    "AgentUsagePanel",
    "enum AgentUsageChartGrouping { agent, model }",
    "AgentUsageChartGrouping.agent",
    "AgentUsageChartGrouping.model",
    "strings.tokenUsage",
    "strings.totalTokens",
    "modelTokenUsage",
    "startAgentUsagePolling",
    "ensureAgentUsageLoadedAndFresh"
  ],
  "local-token usage UI"
);
assert(
  clientShell.includes("ClientSection.monitoring => AgentUsagePanel"),
  "desktop routes must mount the dedicated local-token usage panel"
);

assertIncludes(
  serviceTest,
  [
    "scans agent usage through lico-client agent-usage scan",
    "--history-days",
    "90",
    "rejects retained reports outside the current contract",
    "requires schemaVersion to be the exact integer 6",
    "rejects malformed entries inside retained reports"
  ],
  "Dart usage service regression"
);
assertIncludes(
  controllerTest,
  [
    "shares one in-flight scan and keeps bounded report history",
    "polling owners acquire and release independent leases"
  ],
  "Dart usage controller regression"
);
assertIncludes(
  componentTest,
  [
    "usage panel components form a one-way normal-library graph",
    "isNot(contains('agent_usage_panel.dart'))",
    "isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true)))"
  ],
  "usage component dependency regression"
);
assertIncludes(
  chartTests,
  ["AgentUsageChartGrouping.agent", "AgentUsageChartGrouping.model", "cachedInputTokens"],
  "usage chart regressions"
);
assert(
  usagePanel.includes("source.hasUsage") &&
    usagePanel.includes("formatAgentUsageNumber(source.totalTokens)") &&
    !usagePanel.includes("≈"),
  "usage UI must render cached fallback totals as ordinary numeric values"
);

for (const testName of [
  "codex_usage_reconciles_subsets_duplicates_and_divergent_totals",
  "codex_usage_warm_scan_reuses_files_and_append_scan_reads_only_suffix",
  "codex_usage_keeps_finalized_day_immutable_after_source_rewrite",
  "codex_usage_detects_middle_rewrite_before_append_in_large_file",
  "codex_usage_force_refresh_detects_equal_metadata_rewrite",
  "codex_usage_applies_one_local_calendar_window_to_daily_and_total_values",
  "codex_usage_deduplicates_forked_rollout_prefix_before_window_filtering",
  "codex_usage_counts_identical_events_from_independent_sessions",
  "codex_usage_returns_cached_snapshot_when_same_root_refresh_is_busy",
  "generic_usage_extractor_keeps_cached_input_as_a_subset",
  "generic_usage_extractor_projects_parent_usage_once_for_content_blocks",
  "native_usage_finalizes_past_days_and_only_parses_appended_bytes",
  "cumulative_metadata_counts_new_usage_when_an_old_session_resumes",
  "cumulative_append_rewrite_preserves_today_and_only_adds_new_delta",
  "openagent_today_query_detects_a_resumed_cross_day_session",
  "native_adapters_prefer_exact_metadata_from_bounded_standard_stores",
  "native_adapters_cache_estimates_when_native_counters_are_absent",
  "codex_usage_applies_historical_timezone_transitions_per_event",
  "retained_reports_keep_only_current_contract_and_sort_by_timestamp"
]) {
  assert(
    incrementalCacheTest.includes(testName),
    `native usage regression must cover ${testName}`
  );
}

const report = {
  ok: failures.length === 0,
  productionReady: failures.length === 0,
  generatedAt: new Date().toISOString(),
  artifactKind: "client-local-agent-token-usage-evidence",
  scenario: "agent-usage-metering",
  contract: {
    schemaVersion: 6,
    mode: "local-token-usage",
    tokenSourceMode: "native-metadata-first-incremental",
    defaultScanWindowDays: 90,
    defaultDisplayWindowDays: 30,
    dimensions: ["agent", "model"]
  },
  evidence: {
    nativeAggregation: failures.every((failure) => !failure.startsWith("native")),
    boundedLocalCache: codexUsageCache.includes("append_guard"),
    commandBoundary: commandMod.includes("agent_usage::register_commands"),
    strictFlutterEnvelope: usageModels.includes("validateEnvelope"),
    singleFlightController: usageController.includes("_scanFuture"),
    independentUiComponents: componentTest.includes("one-way normal-library graph"),
    localOnlyDocumentation:
      functionalityDocs.includes("No raw prompt, response, account, local path")
  },
  failures
};

atomicWriteReportJson(repoRoot, reportRef, report);

if (failures.length > 0) {
  console.error(JSON.stringify(report, null, 2));
  process.exit(1);
}

console.log(JSON.stringify(report, null, 2));
