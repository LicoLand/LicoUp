import {
  assert,
  test,
  CLIENT_MODULE_CATALOG,
  selectModulesForChangedPaths,
  ids,
} from "./support.mjs";

test("every explicitly owned Flutter test runs in its module command", () => {
  for (const module of CLIENT_MODULE_CATALOG) {
    const flutterTestIndex = module.command.args.indexOf("test");
    if (flutterTestIndex < 0 ||
        module.command.args[flutterTestIndex - 1] !== "flutter") {
      continue;
    }
    const commandedTests = new Set(
      module.command.args
        .slice(flutterTestIndex + 1)
        .filter((argument) => !argument.startsWith("--")),
    );
    for (const input of module.inputs) {
      if (!input.startsWith("apps/desktop/test/") ||
          !input.endsWith("_test.dart")) {
        continue;
      }
      assert.equal(
        commandedTests.has(input.slice("apps/desktop/".length)),
        true,
        `${module.id} does not execute its owned test: ${input}`,
      );
    }
  }
});

test("changed Flutter feature paths select only their bounded feature module", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/contracts/mcp_adapter.dart",
  ])), ["architecture.client-boundaries", "flutter.feature.mcp-transfer"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/agents/controller/agent_usage_controller.dart",
  ])), ["architecture.client-boundaries", "flutter.feature.agent-usage"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/agents/conversation/agent_conversation_controller.dart",
  ])), ["architecture.client-boundaries", "flutter.feature.agent-conversations"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/agents/conversation/conversation_turn_queue.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.agent-conversations.follow-up-queue",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/agents/ui/conversation_archive_dialog.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.agent-conversations.archive-selection",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_window_control.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.agent-usage.window-control",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/skill_hub/controller/skill_update_controller.dart",
  ])), ["architecture.client-boundaries", "flutter.feature.skill-hub.update"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/skill_hub/controller/skill_delete_controller.dart",
  ])), ["architecture.client-boundaries", "flutter.feature.skill-hub.delete"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/skill_hub/controller/skill_usage_controller.dart",
  ])), ["architecture.client-boundaries", "flutter.feature.skill-hub.usage"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/settings/controller/optional_collaboration_controller.dart",
  ])), ["architecture.client-boundaries", "flutter.feature.optional-collaboration"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/settings/controller/optional_collaboration_workflow_controller.dart",
  ])), ["architecture.client-boundaries", "flutter.feature.optional-collaboration"]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/settings/controller/optional_collaboration_runner_trust_actions.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.optional-collaboration.runner-trust",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/settings/controller/optional_collaboration_install_actions.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.optional-collaboration.install-lifecycle",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/settings/controller/optional_collaboration_local_assembly_actions.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.optional-collaboration.local-server-assembly",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/settings/controller/optional_collaboration_mcp_actions.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.optional-collaboration.mcp-install",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/agents/ui/history_session_search.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.agent-conversations.history-session",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_chart_geometry.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.agent-usage.visualization",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/mobile_relay/controller/secure_mesh_controller.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.mobile-relay.secure-mesh-controller",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_chrome.dart",
  ])), [
    "architecture.client-boundaries",
    "regression.dashboard-desktop-chrome-source-bundle",
    "flutter.layout.dashboard-desktop-chrome.composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_search.dart",
  ])), [
    "architecture.client-boundaries",
    "regression.dashboard-desktop-chrome-source-bundle",
    "flutter.layout.dashboard-desktop-chrome.search",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_pane.dart",
  ])), [
    "architecture.client-boundaries",
    "regression.agent-conversation-pane-source-bundle",
    "flutter.feature.agent-conversations.pane-composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_pane/resize.dart",
  ])), [
    "architecture.client-boundaries",
    "regression.agent-conversation-pane-source-bundle",
    "flutter.feature.agent-conversations.pane-resize",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart",
  ])), [
    "architecture.client-boundaries",
    "regression.agent-conversation-message-blocks-source-bundle",
    "flutter.feature.agent-conversations.message-blocks-dispatcher",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_message_blocks/disclosures.dart",
  ])), [
    "architecture.client-boundaries",
    "regression.agent-conversation-message-blocks-source-bundle",
    "flutter.feature.agent-conversations.message-blocks-disclosures",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart",
  ])), [
    "architecture.client-boundaries",
    "regression.mobile-relay-panel-source-bundle",
    "flutter.feature.mobile-relay.panel-composition",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/frontend/features/mobile_relay/ui/mobile_relay_panel/trust.dart",
  ])), [
    "architecture.client-boundaries",
    "regression.mobile-relay-panel-source-bundle",
    "flutter.feature.mobile-relay.panel-trust",
  ]);
});

test("Flutter controller assembly and main-agent selection select precise closures", () => {
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/controller/client_controller.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.controller.facade",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/controller/assembly/client_mobile_component_assembly.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.controller.assembly.mobile",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/lib/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart",
  ])), [
    "architecture.client-boundaries",
    "flutter.feature.main-agent-selection",
  ]);
  assert.deepEqual(ids(selectModulesForChangedPaths([
    "apps/desktop/test/agent_orchestration_target_test.dart",
  ])), [
    "flutter.contract.main-agent.target",
    "flutter.feature.main-agent-selection",
  ]);

  const facade = CLIENT_MODULE_CATALOG.find(
    (module) => module.id === "flutter.controller.facade",
  );
  assert.equal(
    facade.command.args.includes("test/client_controller_runtime_facades_test.dart"),
    true,
  );
  const mainAgentSelection = CLIENT_MODULE_CATALOG.find(
    (module) => module.id === "flutter.feature.main-agent-selection",
  );
  assert.equal(mainAgentSelection.command.args.length < 16, true);
  assert.equal(
    mainAgentSelection.command.args.includes(
      "test/agent_orchestration_target_test.dart",
    ),
    true,
  );
});

test("main-agent selection owns one bounded desktop acceptance target", () => {
  const projection = CLIENT_MODULE_CATALOG.find(
    (module) => module.id === "flutter.feature.main-agent-selection",
  );
  assert.deepEqual(projection.inputs, [
    "apps/desktop/lib/src/application/features/agents/orchestration/**",
    "apps/desktop/lib/src/application/features/agents/conversation/conversation_message_controller.dart",
    "apps/desktop/test/agent_orchestration_target_test.dart",
  ]);
  assert.deepEqual(projection.command.args.slice(-1), [
    "test/agent_orchestration_target_test.dart",
  ]);
});

test("Dashboard desktop chrome leaves retain exact widget tests and bounded catalog ownership", () => {
  const filters = new Map([
    ["flutter.layout.dashboard-desktop-chrome.composition",
      "test/layout/profiles/dashboard/desktop/dashboard_desktop_widget_test.dart"],
    ["flutter.layout.dashboard-desktop-chrome.folder-sidebar",
      "test/layout/profiles/dashboard/desktop/dashboard_folder_sidebar_test.dart"],
    ["flutter.layout.dashboard-desktop-chrome.search",
      "test/layout/profiles/dashboard/desktop/dashboard_desktop_search_test.dart"],
  ]);
  const modules = CLIENT_MODULE_CATALOG.filter((candidate) =>
    candidate.id.startsWith("flutter.layout.dashboard-desktop-chrome."));
  assert.equal(modules.length, filters.size);
  for (const [id, testPath] of filters) {
    const module = CLIENT_MODULE_CATALOG.find((candidate) => candidate.id === id);
    assert.equal(module.command.args.at(-1), testPath);
  }

  const sourceCheck = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "regression.dashboard-desktop-chrome-source-bundle");
  const ownedInputs = new Set([
    ...modules.flatMap((module) => module.inputs),
    ...sourceCheck.inputs,
  ]);
  for (const relativePath of [
    "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_chrome.dart",
    "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_search.dart",
    "apps/desktop/lib/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_folder_sidebar.dart",
  ]) {
    assert.equal(ownedInputs.has(relativePath), true,
      `Dashboard desktop chrome source must have a focused regression owner: ${relativePath}`);
  }

  const layoutFoundation = CLIENT_MODULE_CATALOG.find((candidate) =>
    candidate.id === "flutter.layer.layout");
  assert.equal(layoutFoundation.inputs.includes(
    "apps/desktop/lib/src/frontend/layout/**"), false);
  assert.equal(layoutFoundation.inputs.includes(
    "apps/desktop/test/layout/**"), false);
});
