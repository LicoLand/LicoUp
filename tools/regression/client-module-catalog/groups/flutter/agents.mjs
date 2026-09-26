import { flutterTests, defineModule } from "../../helpers.mjs";

export const AGENTS_MODULES = Object.freeze([
  defineModule({
      id: "flutter.feature.agents",
      kind: "flutter-feature",
      summary: "Agent workspace coordination, rendering, and target presentation",
      inputs: [
        "apps/desktop/lib/src/application/features/agents/workspace/**",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_conversation_display_names.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_render_adapter.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_workspace_sidebar.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agents_canvas.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agents_toolbar.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/mobile_widgets_page.dart",
        "apps/desktop/lib/src/platform/agent_render_adapter/**",
        "apps/desktop/lib/src/platform/agents/**",
        "apps/desktop/lib/src/contracts/agent_command_runner.dart",
        "apps/desktop/lib/src/contracts/agent_render_adapter_source.dart",
        "apps/desktop/assets/agent-icons/**",
        "apps/desktop/assets/agent-render-adapters/**",
        "apps/desktop/test/agent_application_dependency_boundary_test.dart",
        "apps/desktop/test/agent_render_adapter_test.dart",
      ],
      command: flutterTests([
        "test/agent_application_dependency_boundary_test.dart",
        "test/agent_render_adapter_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agents.workspace.renderer-cache",
      kind: "flutter-feature",
      summary: "Agent workspace render-adapter resolution cache",
      inputs: [
        "apps/desktop/test/agents_workspace/agents_workspace_renderer_cache_test.dart",
        "apps/desktop/test/agents_workspace/support/agents_workspace_test_harness.dart",
      ],
      command: flutterTests([
        "test/agents_workspace/agents_workspace_renderer_cache_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agents.workspace.renderer-diagnostics",
      kind: "flutter-feature",
      summary: "Agent workspace semantic artifacts and diagnostics",
      inputs: [
        "apps/desktop/test/agents_workspace/agents_workspace_renderer_diagnostics_test.dart",
        "apps/desktop/test/agents_workspace/support/agents_workspace_test_harness.dart",
      ],
      command: flutterTests([
        "test/agents_workspace/agents_workspace_renderer_diagnostics_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agents.workspace.renderer-collapse",
      kind: "flutter-feature",
      summary: "Agent workspace collapsed metadata, plugins, and subagent output",
      inputs: [
        "apps/desktop/test/agents_workspace/agents_workspace_renderer_collapse_test.dart",
        "apps/desktop/test/agents_workspace/support/agents_workspace_test_harness.dart",
      ],
      command: flutterTests([
        "test/agents_workspace/agents_workspace_renderer_collapse_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agents.workspace.layout",
      kind: "flutter-feature",
      summary: "Agent workspace desktop and mobile layout boundaries",
      inputs: [
        "apps/desktop/test/agents_workspace/agents_workspace_layout_test.dart",
        "apps/desktop/test/agents_workspace/support/agents_workspace_test_harness.dart",
      ],
      command: flutterTests([
        "test/agents_workspace/agents_workspace_layout_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agents.workspace.interaction",
      kind: "flutter-feature",
      summary: "Agent workspace process, composer, and navigation interactions",
      inputs: [
        "apps/desktop/test/agents_workspace/agents_workspace_interaction_test.dart",
        "apps/desktop/test/agents_workspace/support/agents_workspace_test_harness.dart",
      ],
      command: flutterTests([
        "test/agents_workspace/agents_workspace_interaction_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agents.workspace.state",
      kind: "flutter-feature",
      summary: "Agent workspace active-turn, history, and localization state",
      inputs: [
        "apps/desktop/test/agents_workspace/agents_workspace_state_test.dart",
        "apps/desktop/test/agents_workspace/support/agents_workspace_test_harness.dart",
      ],
      command: flutterTests([
        "test/agents_workspace/agents_workspace_state_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.adapter-plugin-management",
      kind: "flutter-feature",
      summary: "Canonical agent-adapter inventory, confirmed managed-bridge lifecycle, and desktop plugin destination",
      inputs: [
        "apps/desktop/lib/src/application/features/plugin_management/**",
        "apps/desktop/lib/src/application/controller/assembly/client_plugin_management_component_assembly.dart",
        "apps/desktop/lib/src/frontend/features/plugin_management/**",
        "apps/desktop/lib/src/contracts/presentation/semantic_destination.dart",
        "apps/desktop/lib/src/presentation/layout/semantic_destination_catalog.dart",
        "apps/desktop/lib/src/frontend/shell/client_shell.dart",
        "apps/desktop/test/adapter_plugin_controller_test.dart",
        "apps/desktop/test/adapter_plugin_panel_test.dart",
        "apps/desktop/test/client_interface_entry_hooks_test.dart",
        "apps/desktop/test/fixtures/plugin_management_presentation_fixture.dart",
        "apps/desktop/test/layout/semantic_destination_catalog_test.dart",
        "apps/desktop/test/plugin_management_presentation_sources_test.dart",
      ],
      command: flutterTests([
        "test/adapter_plugin_controller_test.dart",
        "test/adapter_plugin_panel_test.dart",
        "test/client_interface_entry_hooks_test.dart",
        "test/optional_collaboration_settings_boundary_test.dart",
        "test/layout/semantic_destination_catalog_test.dart",
        "test/layout/profiles/dashboard/desktop/dashboard_desktop_bundle_test.dart",
        "test/plugin_management_presentation_sources_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.targets",
      kind: "flutter-feature",
      summary: "Target discovery, ordering, manual entry, and cards",
      inputs: [
        "apps/desktop/lib/src/application/features/targets/**",
        "apps/desktop/lib/src/frontend/features/targets/**",
        "apps/desktop/lib/src/contracts/target_candidate.dart",
        "apps/desktop/lib/src/contracts/target_management.dart",
        "apps/desktop/test/manual_target_dialog_test.dart",
        "apps/desktop/test/scanned_targets_incremental_scan_test.dart",
        "apps/desktop/test/target_controller_test.dart",
        "apps/desktop/test/target_candidate_conversation_test.dart",
        "apps/desktop/test/target_card_test.dart",
        "apps/desktop/test/target_scan_coordination_test.dart",
      ],
      command: flutterTests([
        "test/manual_target_dialog_test.dart",
        "test/scanned_targets_incremental_scan_test.dart",
        "test/target_controller_test.dart",
        "test/target_candidate_conversation_test.dart",
        "test/target_card_test.dart",
        "test/target_scan_coordination_test.dart",
      ]),
    }),
]);
