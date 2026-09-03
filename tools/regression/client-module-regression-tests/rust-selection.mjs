import {
  assert,
  path,
  test,
  CLIENT_MODULE_CATALOG,
  selectModulesForChangedPaths,
  ids,
  sourceFiles,
} from "./support.mjs";

test("Rust catalog commands are independently filtered", () => {
  for (const module of CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.kind.startsWith("rust-"))) {
    if (module.command.args.includes("--test")) continue;
    const filter = module.command.args.at(-1);
    assert.notEqual(filter, "core::", `${module.id} has a broad core filter`);
    assert.notEqual(filter, "domain::", `${module.id} has a broad domain filter`);
  }
});

test("catalog convergence crate and native adapters retain bounded closures", () => {
  const selections = new Map([
    ["crates/lico-catalog-convergence/src/engine.rs", [
      "rust.crate.catalog-convergence",
    ]],
    ["crates/licoup-native/src/domain/catalog_convergence.rs", [
      "architecture.client-boundaries",
      "rust.domain.catalog-convergence-adapter",
    ]],
    ["crates/licoup-native/src/platform/catalog_cache_store.rs", [
      "architecture.client-boundaries",
      "rust.platform.catalog-cache-store",
    ]],
    ["crates/licoup-native/src/bin/licoup/stdio_rpc/server.rs", [
      "regression.subagent-mcp-common",
      "architecture.client-boundaries",
      "rust.ffi.client-state-contract",
      "rust.ffi.catalog-convergence",
      "rust.ffi.cli-command-admission",
      "rust.bin.licoup.rpc",
      "bridge.native-mcp-rpc-guard",
    ]],
  ]);
  for (const [changedPath, expectedIds] of selections) {
    assert.deepEqual(ids(selectModulesForChangedPaths([changedPath])), expectedIds);
  }

  const crateModule = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.crate.catalog-convergence");
  assert.deepEqual(crateModule.command.args, [
    "test",
    "--manifest-path",
    "crates/lico-catalog-convergence/Cargo.toml",
  ]);
  for (const id of [
    "rust.domain.catalog-convergence-adapter",
    "rust.platform.catalog-cache-store",
    "rust.ffi.catalog-convergence",
  ]) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.deepEqual(module.command.args, [
      "check",
      "--manifest-path",
      "crates/licoup-native/Cargo.toml",
      "--lib",
    ]);
  }
});

test("Subagent MCP startup integration test keeps one bounded Rust selection", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/tests/subagent_mcp_startup.rs",
  ])), ["rust.bin.licoup.subagent-mcp-startup"]);
  const module = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.bin.licoup.subagent-mcp-startup");
  assert.deepEqual(module.command.args.slice(-2), ["--test", "subagent_mcp_startup"]);
});

test("Rust domain changes select a precise cargo-filtered slice", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mcp_adapter/plan.rs",
  ])), ["architecture.client-boundaries", "rust.domain.mcp-adapter"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mcp_adapter/execution.rs",
  ])), ["architecture.client-boundaries", "rust.domain.mcp-adapter"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/secure_mesh_command_runtime.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.secure-mesh-command-runtime",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/agent_usage/window.rs",
  ])), ["architecture.client-boundaries", "rust.domain.agent-usage.window"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/agent_usage/agent_usage_native/parser.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-usage.native-cache",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/agent_usage/agent_usage_codex.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-usage-cache",
    "regression.agent-usage-codex-source-bundle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/agent_usage/agent_usage_codex/cache_batch.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-usage.codex-cache-batch",
    "regression.agent-usage-codex-source-bundle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/agent_usage/agent_usage_codex/constants.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-usage.codex-models",
    "rust.domain.agent-usage.codex-append-guard",
    "rust.domain.agent-usage.codex-cache-database",
    "regression.agent-usage-codex-source-bundle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/tests/agent_usage_incremental_cache.rs",
  ])), [
    "rust.domain.agent-usage-cache",
    "regression.agent-usage-codex-source-bundle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/tests/agent_usage_cache_cases/cache_runtime.rs",
  ])), [
    "rust.domain.agent-usage-cache.runtime",
    "regression.agent-usage-codex-source-bundle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/tests/agent_usage_cache_cases/native_rollup.rs",
  ])), [
    "rust.domain.agent-usage-cache.native-rollup",
    "regression.agent-usage-codex-source-bundle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversations.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation_snapshots.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.snapshots.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation_archive_jobs.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.archive-jobs.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation_archive_jobs/request.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.archive-jobs.request",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation_archive_jobs/plan.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.archive-jobs.plan",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation_archive_jobs/retry.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.archive-jobs.retry",
    "rust.domain.agent-conversations.archive-jobs.cancel",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/snapshot_codec.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.snapshot-codec",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/snapshots/settings.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.snapshots.settings",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/snapshots/discovery.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.snapshots.discovery",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/snapshots/selection_plan.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.snapshots.selection-plan",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/snapshots/privacy_projection.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.snapshots.privacy-projection",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/snapshots/materialization.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.snapshots.materialization",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/snapshots/validation.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.snapshots.validation",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/archive_queue.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.archive-queue",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/event_semantics.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.event-semantic",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation_semantic.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.conversation-semantic-source-bundle",
    "rust.domain.agent-conversations.semantic.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation_semantic/privacy.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.conversation-semantic-source-bundle",
    "rust.domain.agent-conversations.semantic.privacy",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/history/codex.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.parser-codex",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/history/cursor_openagent.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.cursor-openagent-source-bundle",
    "rust.domain.agent-conversations.parser-cursor-openagent.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/history/cursor_openagent/codec.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.cursor-openagent-source-bundle",
    "rust.domain.agent-conversations.parser-cursor-openagent.codec",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/history/tests/cursor_openagent.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.parser-cursor-openagent.integration",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/history/message_projection.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.message-projection-source-bundle",
    "rust.domain.agent-conversations.message-projection.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/history/message_projection/structured_privacy.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.message-projection-source-bundle",
    "rust.domain.agent-conversations.message-projection.structured-privacy",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/history/session_merge.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.session-merge-source-bundle",
    "rust.domain.agent-conversations.session-merge.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/history/session_merge/delegated_merge.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.session-merge-source-bundle",
    "rust.domain.agent-conversations.session-merge.delegated",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/conversation/history/tests/session_merge.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.agent-conversations.session-merge.integration",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/targets/catalog.rs",
  ])), ["architecture.client-boundaries", "rust.domain.targets.catalog"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/targets/target_cache.rs",
  ])), ["architecture.client-boundaries", "rust.domain.targets.discovery-cache"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/targets/model_catalog/kilo.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.targets.model-catalog.kilo",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/targets/model_catalog/claude.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.targets.model-catalog.claude-code",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/targets/model_catalog/opencode.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.targets.model-catalog.opencode",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mobile_relay/pairing.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.mobile-relay.pairing",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mobile_relay/relay_operations.rs",
  ])), [
    "regression.relay-operations-source-bundle",
    "architecture.client-boundaries",
    "rust.domain.mobile-relay.relay-operations",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mobile_relay/secret_custody.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.mobile-relay.secret-custody",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mobile_relay/secret_custody/runtime.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.mobile-relay.secret-custody.runtime",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mobile_relay/tests/secret_custody.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.mobile-relay.secret-custody.scenario.config-integrity",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mobile_relay/tests/secret_custody/secure_command_store.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.mobile-relay.secret-custody.scenario.secure-command-store",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mobile_relay/endpoint_trust/persistence.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.mobile-relay.endpoint-trust.persistence",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mobile_relay/tests/endpoint_trust.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.mobile-relay.endpoint-trust.scenarios",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/collaboration_plugin/lifecycle/mod.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.optional-collaboration",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/collaboration_plugin/workflow/operations.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.collaboration-workflow-operations-source-bundle",
    "rust.domain.optional-collaboration.workflow-operations.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/collaboration_plugin/workflow/operations/validation.rs",
  ])), [
    "architecture.client-boundaries",
    "regression.collaboration-workflow-operations-source-bundle",
    "rust.domain.optional-collaboration.workflow-operations.validation",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/collaboration_plugin/workflow/tests.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.optional-collaboration.workflow-operations.integration",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/client_update.rs",
  ])), [
    "regression.client-update-source-bundle",
    "architecture.client-boundaries",
    "rust.domain.client-update",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/skill_hub/usage.rs",
  ])), ["architecture.client-boundaries", "rust.domain.skill-hub.usage"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/skill_hub/delete.rs",
  ])), ["architecture.client-boundaries", "rust.domain.skill-hub.delete"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/skill_hub/catalog.rs",
  ])), ["architecture.client-boundaries", "rust.domain.skill-hub.pairing-catalog"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/skill_hub/pairing.rs",
  ])), ["architecture.client-boundaries", "rust.domain.skill-hub.pairing-catalog"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/skill_hub/package.rs",
  ])), ["architecture.client-boundaries", "rust.domain.skill-hub.package"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/skill_hub/state.rs",
  ])), ["architecture.client-boundaries", "rust.domain.skill-hub"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/mod.rs",
  ])), ["architecture.client-boundaries", "rust.composition"]);

  const mobilePairing = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.domain.mobile-relay.pairing");
  const agentUsage = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.domain.agent-usage");
  const agentUsageCache = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.domain.agent-usage-cache");
  const nativeUsageCache = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.domain.agent-usage.native-cache");
  const targets = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.domain.targets");
  const skillHub = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.domain.skill-hub");
  const optionalCollaboration = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.domain.optional-collaboration");
  const clientUpdate = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.domain.client-update");
  assert.equal(mobilePairing.command.args.at(-1), "pairing");
  assert.equal(agentUsage.command.args.at(-1), "domain::agent_usage::");
  assert.deepEqual(agentUsageCache.command.args.slice(-3), [
    "--test",
    "agent_usage_incremental_cache",
    "agent_usage_cache_cases::",
  ]);
  assert.equal(
    nativeUsageCache.command.args.at(-1),
    "domain::agent_usage::agent_usage_native::",
  );
  const codexLeafFilters = new Map([
    ["rust.domain.agent-usage.codex-models",
      "domain::agent_usage::agent_usage_codex::tests::models::"],
    ["rust.domain.agent-usage.codex-utils",
      "domain::agent_usage::agent_usage_codex::tests::utils::"],
    ["rust.domain.agent-usage.codex-scan-params",
      "domain::agent_usage::agent_usage_codex::tests::scan_params::"],
    ["rust.domain.agent-usage.codex-files",
      "domain::agent_usage::agent_usage_codex::tests::file_collection::"],
    ["rust.domain.agent-usage.codex-append-guard",
      "domain::agent_usage::agent_usage_codex::tests::append_guard::"],
    ["rust.domain.agent-usage.codex-event-hash",
      "domain::agent_usage::agent_usage_codex::tests::event_hash::"],
    ["rust.domain.agent-usage.codex-lineage",
      "domain::agent_usage::agent_usage_codex::tests::lineage::"],
    ["rust.domain.agent-usage.codex-model-backfill",
      "domain::agent_usage::agent_usage_codex::model_backfill::tests::"],
    ["rust.domain.agent-usage.codex-cache-database",
      "domain::agent_usage::agent_usage_codex::tests::cache::"],
    ["rust.domain.agent-usage.codex-cache-batch",
      "domain::agent_usage::agent_usage_codex::tests::cache_batch::"],
    ["rust.domain.agent-usage.codex-parser",
      "domain::agent_usage::agent_usage_codex::tests::parser::"],
    ["rust.domain.agent-usage.codex-rollup",
      "domain::agent_usage::agent_usage_codex::tests::parser::"],
    ["rust.domain.agent-usage.codex-aggregation",
      "domain::agent_usage::agent_usage_codex::tests::aggregation::"],
    ["rust.domain.agent-usage.codex-test-support",
      "domain::agent_usage::agent_usage_codex::tests::"],
  ]);
  for (const [id, filter] of codexLeafFilters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    assert.equal(module.inputs.includes(
      "crates/licoup-native/src/domain/agent_usage/agent_usage_codex.rs"), false);
  }
  const codexSourceBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.agent-usage-codex-source-bundle");
  assert.deepEqual(codexSourceBundle.command.args, [
    "--test",
    "tests/contract/client/agent-usage-codex-source-bundle.test.mjs",
  ]);
  const codexScenarioFilters = new Map([
    ["rust.domain.agent-usage-cache.append-refresh",
      "agent_usage_cache_cases::append_refresh::"],
    ["rust.domain.agent-usage-cache.runtime",
      "agent_usage_cache_cases::cache_runtime::"],
    ["rust.domain.agent-usage-cache.dedup-lineage",
      "agent_usage_cache_cases::dedup_lineage::"],
    ["rust.domain.agent-usage-cache.generic-usage",
      "agent_usage_cache_cases::generic_usage::"],
    ["rust.domain.agent-usage-cache.native-rollup",
      "agent_usage_cache_cases::native_rollup::"],
    ["rust.domain.agent-usage-cache.reconciliation",
      "agent_usage_cache_cases::reconciliation::"],
    ["rust.domain.agent-usage-cache.retained-reports",
      "agent_usage_cache_cases::retained_reports::"],
    ["rust.domain.agent-usage-cache.two-phase",
      "agent_usage_cache_cases::two_phase::"],
    ["rust.domain.agent-usage-cache.windows",
      "agent_usage_cache_cases::windows::"],
  ]);
  for (const [id, filter] of codexScenarioFilters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.deepEqual(module.command.args.slice(-3), [
      "--test",
      "agent_usage_incremental_cache",
      filter,
    ]);
  }
  assert.equal(targets.command.args.at(-1), "domain::targets::tests::");
  assert.equal(skillHub.command.args.at(-1), "domain::skill_hub::tests");
  assert.equal(optionalCollaboration.command.args.at(-1),
    "domain::collaboration_plugin");
  assert.equal(clientUpdate.command.args.at(-1), "domain::client_update::tests::");
});

test("foundation and security modules retain exact narrow command filters", () => {
  const commandFilter = (id) => CLIENT_MODULE_CATALOG
    .find((module) => module.id === id)
    .command.args.at(-1);
  assert.equal(commandFilter("rust.core.acp.composition"), "core::acp::tests");
  assert.equal(commandFilter("rust.core.acp.requests"),
    "core::acp::tests::requests");
  assert.equal(commandFilter("rust.core.acp.responses"),
    "core::acp::tests::responses");
  assert.equal(commandFilter("rust.core.acp.codec"),
    "core::acp::tests::codec");
  assert.equal(commandFilter("rust.core.mcp.composition"), "core::mcp::tests");
  assert.equal(commandFilter("rust.core.mcp.wire"), "core::mcp::tests::wire");
  assert.equal(commandFilter("rust.core.mcp.transfer"),
    "core::mcp::tests::transfer");
  assert.equal(commandFilter("rust.domain.mcp-adapter"),
    "domain::mcp_adapter::tests::");
  assert.equal(commandFilter("rust.domain.secure-mesh-command-runtime"),
    "domain::secure_mesh_command_runtime::tests::");
  assert.equal(commandFilter("rust.domain.agent-usage.window"),
    "domain::agent_usage::window::tests::");
  assert.equal(commandFilter("rust.core.secure-mesh.secret-custody-port"),
    "core::secure_mesh_secret_store::tests::");
  assert.equal(commandFilter("rust.platform.secure-mesh-mls-store"),
    "platform::secure_mesh_mls_store::tests::");
  assert.equal(commandFilter("rust.core.secure-mesh.pairwise-persistence.schema-reset"),
    "core::secure_mesh_pairwise::tests::persistence_schema_reset::");
  assert.equal(commandFilter("rust.core.task-queue"), "core::task_queue::tests");
  assert.equal(commandFilter("rust.core.secure-mesh.command"),
    "core::secure_mesh_command::tests");
  assert.equal(commandFilter("rust.core.secure-mesh.command.schema"),
    "core::secure_mesh_command::tests::agent_sessions_");
  assert.equal(commandFilter("rust.core.secure-mesh.command.replay"),
    "core::secure_mesh_command::tests::secure_mesh_command_idempotency");
  assert.equal(commandFilter("rust.core.secure-mesh.command.policy"),
    "core::secure_mesh_command::tests::secure_mesh_command_gate_");
  assert.equal(commandFilter("rust.core.secure-mesh.command.runtime"),
    "core::secure_mesh_command::tests::ready_agent_dispatch_");
  assert.equal(commandFilter("rust.core.secure-mesh.command.codec"),
    "core::secure_mesh_command::tests::secure_mesh_command_execution_");
  assert.equal(commandFilter("rust.core.secure-mesh.directory"),
    "core::secure_mesh_directory::tests::");
  assert.equal(commandFilter("rust.core.secure-mesh.pairwise-codec"),
    "core::secure_mesh_pairwise::tests::codec");
  const composition = CLIENT_MODULE_CATALOG.find((module) =>
    module.id === "rust.composition");
  assert.deepEqual(composition.command.args, [
    "check",
    "--manifest-path",
    "crates/licoup-native/Cargo.toml",
    "--lib",
  ]);

  for (const [id, sharedFacade] of [
    ["rust.core.acp.requests", "crates/licoup-native/src/core/acp.rs"],
    ["rust.core.acp.responses", "crates/licoup-native/src/core/acp.rs"],
    ["rust.core.acp.codec", "crates/licoup-native/src/core/acp.rs"],
    ["rust.core.mcp.wire", "crates/licoup-native/src/core/mcp.rs"],
    ["rust.core.mcp.transfer", "crates/licoup-native/src/core/mcp.rs"],
  ]) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.inputs.includes(sharedFacade), false,
      `${id} must not inherit shared facade fanout`);
  }
});

test("Secure Mesh custody, runtime, MLS store, and schema reset select bounded closures", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/secure_mesh_secret_store/authorization.rs",
  ])), [
    "architecture.client-boundaries",
      "rust.platform.secure-mesh-secret-store.authorization",
      "rust.core.secure-mesh.secret-custody-port",
      "rust.core.secure-mesh.presence-authorization",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/secure_mesh_command_runtime.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.secure-mesh-command-runtime",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/platform/secure_mesh_mls_store.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.platform.secure-mesh-mls-store",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/core/secure_mesh_pairwise/tests/persistence_schema_reset.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.core.secure-mesh.pairwise-persistence.schema-reset",
  ]);
});

test("snapshot modules retain leaf-owned inputs and exact command filters", () => {
  const filters = new Map([
    ["rust.domain.agent-conversations.snapshots.settings",
      "domain::conversation::snapshots::tests::settings"],
    ["rust.domain.agent-conversations.snapshots.support",
      "domain::conversation::snapshots::tests::support"],
    ["rust.domain.agent-conversations.snapshots.discovery",
      "domain::conversation::snapshots::tests::discovery"],
    ["rust.domain.agent-conversations.snapshots.selection",
      "domain::conversation::snapshots::tests::selection"],
    ["rust.domain.agent-conversations.snapshots.selection-plan",
      "domain::conversation::snapshots::tests::selection_plan::"],
    ["rust.domain.agent-conversations.snapshots.orchestration",
      "domain::conversation::snapshots::tests::orchestration"],
    ["rust.domain.agent-conversations.snapshots.privacy-projection",
      "domain::conversation::snapshots::tests::privacy_projection"],
    ["rust.domain.agent-conversations.snapshots.materialization",
      "domain::conversation::snapshots::tests::materialization"],
    ["rust.domain.agent-conversations.snapshots.validation",
      "domain::conversation::snapshots::tests::validation"],
    ["rust.domain.agent-conversations.snapshots.reporting",
      "domain::conversation::snapshots::tests::reporting"],
    ["rust.domain.agent-conversations.snapshot-codec",
      "domain::conversation::snapshot_codec::tests"],
    ["rust.domain.agent-conversations.snapshot-collection",
      "domain::conversation::snapshot_collection::tests"],
    ["rust.domain.agent-conversations.snapshot-content",
      "domain::conversation::snapshot_content::tests"],
    ["rust.domain.agent-conversations.snapshot-identity",
      "domain::conversation::snapshot_identity::tests"],
  ]);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    assert.equal(module.inputs.includes(
      "crates/licoup-native/src/domain/conversation_snapshots.rs"), false);
    assert.equal(module.inputs.includes(
      "crates/licoup-native/src/domain/conversation/snapshots/mod.rs"), false);
  }
});

test("collaboration workflow operation leaves retain exact tests and complete source ownership", async () => {
  const registration = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.domain.collaboration-plugin.mcp-registration");
  assert.equal(registration.command.args.at(-1),
    "domain::collaboration_plugin::workflow::tests::mcp_partial_commit_rolls_back_payload_and_private_agent_registration");
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/collaboration_plugin/registration.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.collaboration-plugin.mcp-registration",
  ]);
  const bridge = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "rust.domain.collaboration-plugin.mcp-bridge");
  assert.equal(bridge.command.args.at(-1),
    "domain::collaboration_plugin::bridge::tests::");
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "crates/licoup-native/src/domain/collaboration_plugin/bridge.rs",
  ])), [
    "architecture.client-boundaries",
    "rust.domain.collaboration-plugin.mcp-bridge",
  ]);

  const filters = new Map([
    ["rust.domain.optional-collaboration.workflow-operations.composition",
      "domain::collaboration_plugin::workflow::operations::tests::composition::"],
    ["rust.domain.optional-collaboration.workflow-operations.plan-local",
      "domain::collaboration_plugin::workflow::operations::tests::plan_local::"],
    ["rust.domain.optional-collaboration.workflow-operations.plan-mcp",
      "domain::collaboration_plugin::workflow::operations::tests::plan_mcp::"],
    ["rust.domain.optional-collaboration.workflow-operations.apply-local",
      "domain::collaboration_plugin::workflow::operations::tests::apply_local::"],
    ["rust.domain.optional-collaboration.workflow-operations.apply-mcp",
      "domain::collaboration_plugin::workflow::operations::tests::apply_mcp::"],
    ["rust.domain.optional-collaboration.workflow-operations.cancel",
      "domain::collaboration_plugin::workflow::operations::tests::cancel::"],
    ["rust.domain.optional-collaboration.workflow-operations.validation",
      "domain::collaboration_plugin::workflow::operations::tests::validation::"],
    ["rust.domain.optional-collaboration.workflow-operations.package-revalidation",
      "domain::collaboration_plugin::workflow::operations::tests::package_revalidation::"],
    ["rust.domain.optional-collaboration.workflow-operations.destination-policy",
      "domain::collaboration_plugin::workflow::operations::tests::destination_policy::"],
    ["rust.domain.optional-collaboration.workflow-operations.staging",
      "domain::collaboration_plugin::workflow::operations::tests::staging::"],
    ["rust.domain.optional-collaboration.workflow-operations.projection",
      "domain::collaboration_plugin::workflow::operations::tests::projection::"],
    ["rust.domain.optional-collaboration.workflow-operations.integration",
      "domain::collaboration_plugin::workflow::tests::"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("rust.domain.optional-collaboration.workflow-operations."));
  assert.equal(modules.length, filters.size);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
  }
  assert.equal(CLIENT_MODULE_CATALOG.some((candidate) =>
    candidate.id === "rust.domain.optional-collaboration.workflow-operations"), false);

  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.collaboration-workflow-operations-source-bundle");
  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  const splitSources = await sourceFiles(
    "crates/licoup-native/src/domain/collaboration_plugin/workflow/operations",
    ".rs",
  );
  for (const relativePath of [
    "crates/licoup-native/src/domain/collaboration_plugin/workflow/operations.rs",
    ...splitSources,
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `collaboration workflow operation source must have a focused regression owner: ${relativePath}`);
  }
});

test("skill hub modules retain leaf-owned inputs and exact command filters", () => {
  const filters = new Map([
    ["rust.domain.skill-hub.pairing-catalog",
      "domain::skill_hub::tests::pairing_catalog::"],
    ["rust.domain.skill-hub.package", "domain::skill_hub::package::tests"],
    ["rust.domain.skill-hub.discovery", "domain::skill_hub::discovery::tests"],
    ["rust.domain.skill-hub.delete", "domain::skill_hub::delete::tests::"],
    ["rust.domain.skill-hub.usage", "domain::skill_hub::usage::"],
  ]);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    assert.equal(module.inputs.includes(
      "crates/licoup-native/src/domain/skill_hub.rs"), false);
  }
});

test("target modules retain leaf-owned inputs and exact command filters", () => {
  const filters = new Map([
    ["rust.domain.targets.scan-paths", "domain::targets::scan_paths::tests::"],
    ["rust.domain.targets.binaries", "domain::targets::binaries::tests::"],
    ["rust.domain.targets.catalog", "domain::targets::catalog::tests::"],
    ["rust.domain.targets.parameters", "domain::targets::parameters::tests::"],
    ["rust.domain.targets.platform-paths", "domain::targets::platform_paths::tests::"],
    ["rust.domain.targets.processes", "domain::targets::processes::tests::"],
    ["rust.domain.targets.platform-integration", "domain::targets::tests::platform::"],
    ["rust.domain.targets.probe-pool", "domain::targets::probe_pool::tests::"],
    ["rust.domain.targets.discovery", "domain::targets::tests::discovery::"],
    ["rust.domain.targets.discovery-cache", "domain::targets::target_cache::tests::"],
    ["rust.domain.targets.manual", "domain::targets::tests::manual::"],
    ["rust.domain.targets.scan-merge", "domain::targets::tests::scan_merge::"],
    ["rust.domain.targets.runtime-binding", "domain::targets::tests::runtime_binding::"],
    ["rust.domain.targets.model-catalog.antigravity",
      "domain::targets::model_catalog::tests::antigravity::"],
    ["rust.domain.targets.model-catalog.cursor",
      "domain::targets::model_catalog::tests::cursor::"],
    ["rust.domain.targets.model-catalog.config",
      "domain::targets::model_catalog::tests::config_"],
    ["rust.domain.targets.model-catalog.history",
      "domain::targets::model_catalog::tests::history::"],
    ["rust.domain.targets.model-catalog.kilo",
      "domain::targets::model_catalog::tests::kilo::"],
    ["rust.domain.targets.model-catalog.claude-code",
      "domain::targets::model_catalog::tests::claude_code::"],
    ["rust.domain.targets.model-catalog.opencode",
      "domain::targets::model_catalog::tests::opencode::"],
    ["rust.domain.targets.model-catalog.normalization",
      "domain::targets::model_catalog::tests::normalization::"],
    ["rust.domain.targets.model-catalog.provider",
      "domain::targets::model_catalog::tests::provider::"],
    ["rust.domain.targets.model-catalog.reasoning",
      "domain::targets::model_catalog::tests::reasoning::"],
    ["rust.domain.targets.model-catalog.merge",
      "domain::targets::model_catalog::tests::merge::"],
  ]);
  for (const [id, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), filter);
    assert.equal(module.inputs.includes(
      "crates/licoup-native/src/domain/targets.rs"), false);
  }
});

test("client update leaves retain exact narrow regression filters", () => {
  const sourceBundleId = "regression.client-update-source-bundle";
  const selections = new Map([
    ["signature.rs", "rust.domain.client-update.signature-roles"],
    ["release.rs", "rust.domain.client-update.release-selection"],
    ["canonical.rs", "rust.domain.client-update.artifact-binding"],
    ["staging/path.rs", "rust.domain.client-update.staging-paths"],
    ["revocation.rs", "rust.domain.client-update.revocation"],
    ["apply.rs", "rust.domain.client-update.workflow"],
    ["native_runner/macos_integrity.rs", "rust.domain.client-update.native-runner"],
  ]);
  for (const [leaf, moduleId] of selections) {
    assert.deepEqual(ids(selectModulesForChangedPaths([
      `crates/licoup-native/src/domain/client_update/${leaf}`,
    ])), [sourceBundleId, "architecture.client-boundaries", moduleId]);
  }
  const filters = new Map([
    ["rust.domain.client-update", "domain::client_update::tests::"],
    ["rust.domain.client-update.signature-roles",
      "domain::client_update::tests::signature_roles::"],
    ["rust.domain.client-update.release-selection",
      "domain::client_update::tests::release_selection::"],
    ["rust.domain.client-update.artifact-binding",
      "domain::client_update::tests::artifact_binding::"],
    ["rust.domain.client-update.staging-paths",
      "domain::client_update::tests::staging_paths::"],
    ["rust.domain.client-update.revocation",
      "domain::client_update::tests::revocation::"],
    ["rust.domain.client-update.workflow",
      "domain::client_update::tests::workflow::"],
    ["rust.domain.client-update.native-runner",
      "domain::client_update::tests::native_runner::"],
  ]);
  for (const [moduleId, filter] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === moduleId);
    assert.equal(module.command.args.at(-1), filter);
  }
  const sourceBundle = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === sourceBundleId);
  assert.deepEqual(sourceBundle.command.args, [
    "--test",
    "tests/contract/client/client-update-source-bundle.test.mjs",
  ]);
});
