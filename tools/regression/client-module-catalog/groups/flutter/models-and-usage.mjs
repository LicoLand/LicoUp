import { flutterTests, defineModule } from "../../helpers.mjs";

export const MODELS_AND_USAGE_MODULES = Object.freeze([
  defineModule({
      id: "flutter.feature.agent-usage",
      kind: "flutter-feature",
      summary: "Local token usage aggregation, time windows, charts, and summaries",
      inputs: [
        "apps/desktop/lib/src/application/features/agents/contracts/agent_usage_gateway.dart",
        "apps/desktop/lib/src/application/features/agents/controller/agent_usage_daily_cache.dart",
        "apps/desktop/lib/src/application/features/agents/controller/agent_usage_controller.dart",
        "apps/desktop/lib/src/application/composition/agent_usage_gateway_adapter.dart",
        "apps/desktop/lib/src/backend/features/agents/services/agent_usage_service.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_summary_widgets.dart",
        "apps/desktop/lib/src/contracts/agent_usage_models.dart",
        "apps/desktop/test/agent_usage_daily_cache_test.dart",
        "apps/desktop/test/agent_usage_native_projection_test.dart",
        "apps/desktop/test/agent_usage_controller_test.dart",
        "apps/desktop/test/agent_usage_refresh_test.dart",
        "apps/desktop/test/agent_usage_loading_test.dart",
        "apps/desktop/test/agent_usage_service_test.dart",
        "apps/desktop/test/agent_usage_summary_widgets_test.dart",
        "apps/desktop/test/client_agent_usage_facade_test.dart",
      ],
      command: flutterTests([
        "test/agent_usage_daily_cache_test.dart",
        "test/agent_usage_native_projection_test.dart",
        "test/agent_usage_controller_test.dart",
        "test/agent_usage_refresh_test.dart",
        "test/agent_usage_loading_test.dart",
        "test/agent_usage_service_test.dart",
        "test/agent_usage_summary_widgets_test.dart",
        "test/client_agent_usage_facade_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.provider-quota",
      kind: "flutter-feature",
      summary: "Provider-quota snapshot projection, roster rings, and hover usage card",
      inputs: [
        "apps/desktop/lib/src/contracts/provider_quota_models.dart",
        "apps/desktop/lib/src/application/features/agents/contracts/provider_quota_gateway.dart",
        "apps/desktop/lib/src/application/features/agents/controller/provider_quota_controller.dart",
        "apps/desktop/lib/src/application/composition/provider_quota_gateway_adapter.dart",
        "apps/desktop/lib/src/application/controller/assembly/client_provider_quota_component_assembly.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_quota_ring.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/messaging/messaging_quota_usage_card.dart",
        "apps/desktop/test/messaging/messaging_roster_quota_test.dart",
      ],
      command: flutterTests([
        "test/messaging/messaging_roster_quota_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.workflow",
      kind: "flutter-feature",
      summary: "Path-free native workflow token hierarchy, exact coverage, and progressive Plan disclosure",
      inputs: [
        "apps/desktop/lib/src/contracts/agent_usage_models.dart",
        "apps/desktop/lib/src/application/features/agents/controller/agent_usage_daily_cache.dart",
        "apps/desktop/lib/src/backend/features/agents/services/agent_usage_service.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_chart_controls.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_models.dart",
        "apps/desktop/lib/src/frontend/l10n/lico_strings_labels.dart",
        "apps/desktop/test/agent_usage_workflow_test.dart",
        "apps/desktop/test/agent_usage_service_test.dart",
        "apps/desktop/test/agent_usage_controller_test.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_panel_fixtures.dart",
      ],
      command: flutterTests([
        "test/agent_usage_workflow_test.dart",
        "test/agent_usage_service_test.dart",
        "test/agent_usage_controller_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.window-control",
      kind: "flutter-feature",
      summary: "Selectable 1-to-90-day token usage window control",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_window_control.dart",
        "apps/desktop/test/agent_usage_window_control_test.dart",
      ],
      command: flutterTests([
        "test/agent_usage_window_control_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.formatters",
      kind: "flutter-feature",
      summary: "Bounded token, percentage, and timeline-label formatting",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_formatters.dart",
        "apps/desktop/test/agent_usage_formatters_test.dart",
      ],
      command: flutterTests(["test/agent_usage_formatters_test.dart"]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.timeline-boundary",
      kind: "flutter-feature",
      summary: "Thin timeline facade and one-way normal-library boundaries",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline_data.dart",
        "apps/desktop/test/agent_usage_component_boundary_test.dart",
      ],
      command: flutterTests(["test/agent_usage_component_boundary_test.dart"]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.timeline-models",
      kind: "flutter-feature",
      summary: "Timeline grouping, snapshot, series, and aggregate value models",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_models.dart",
        "apps/desktop/test/agent_usage_timeline/agent_usage_timeline_models_test.dart",
      ],
      command: flutterTests([
        "test/agent_usage_timeline/agent_usage_timeline_models_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.timeline-builder",
      kind: "flutter-feature",
      summary: "Thirty-day agent/model bucket aggregation and top-series selection",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_builder.dart",
        "apps/desktop/test/agent_usage_timeline/agent_usage_timeline_builder_test.dart",
      ],
      command: flutterTests([
        "test/agent_usage_timeline/agent_usage_timeline_builder_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.source-parser",
      kind: "flutter-feature",
      summary: "Usage-source JSON, daily-shape, date, and numeric token parsing",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_source_parser.dart",
        "apps/desktop/test/agent_usage_timeline/agent_usage_source_parser_test.dart",
      ],
      command: flutterTests([
        "test/agent_usage_timeline/agent_usage_source_parser_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.token-breakdown",
      kind: "flutter-feature",
      summary: "Exact token components and normalized per-model merge",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_token_breakdown.dart",
        "apps/desktop/test/agent_usage_timeline/agent_usage_token_breakdown_test.dart",
      ],
      command: flutterTests([
        "test/agent_usage_timeline/agent_usage_token_breakdown_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.display-names",
      kind: "flutter-feature",
      summary: "Agent and model alias normalization for usage presentation",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_display_names.dart",
        "apps/desktop/test/agent_usage_timeline/agent_usage_display_names_test.dart",
      ],
      command: flutterTests([
        "test/agent_usage_timeline/agent_usage_display_names_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.series-color",
      kind: "flutter-feature",
      summary: "Known and stable fallback color assignment for usage series",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_series_color_policy.dart",
        "apps/desktop/test/agent_usage_timeline/agent_usage_series_color_policy_test.dart",
      ],
      command: flutterTests([
        "test/agent_usage_timeline/agent_usage_series_color_policy_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.visibility",
      kind: "flutter-feature",
      summary: "Detected-agent and meaningful-history visibility policy",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_visibility_policy.dart",
        "apps/desktop/test/agent_usage_timeline/agent_usage_visibility_policy_test.dart",
      ],
      command: flutterTests([
        "test/agent_usage_timeline/agent_usage_visibility_policy_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.visualization",
      kind: "flutter-feature",
      summary: "Token usage panel, chart geometry, controls, painter, and overview",
      inputs: [
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_panel.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_chart_controls.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_chart_geometry.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_hover_card.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_source_hover.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_wave_chart_painter.dart",
        "apps/desktop/lib/src/frontend/features/agents/ui/agent_usage_wave_overview.dart",
        "apps/desktop/test/agent_usage_chart_geometry_test.dart",
        "apps/desktop/test/agent_usage_wave_chart_painter_test.dart",
        "apps/desktop/test/agent_usage_charts_test.dart",
        "apps/desktop/test/agent_usage_hover_card_test.dart",
        "apps/desktop/test/agent_usage_model_sources_test.dart",
        "apps/desktop/test/agent_usage_visualization_test.dart",
        "apps/desktop/test/fixtures/agent_usage_panel_scenarios.dart",
      ],
      command: flutterTests([
        "test/agent_usage_chart_geometry_test.dart",
        "test/agent_usage_wave_chart_painter_test.dart",
        "test/agent_usage_charts_test.dart",
        "test/agent_usage_hover_card_test.dart",
        "test/agent_usage_model_sources_test.dart",
        "test/agent_usage_visualization_test.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.scenario.formatting",
      kind: "flutter-feature",
      summary: "Usage totals, compact number formatting, and grouping controls",
      inputs: [
        "apps/desktop/test/fixtures/agent_usage_panel/formatting_scenarios.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_agent_service_fakes.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_panel_fixtures.dart",
      ],
      command: flutterTests([
        "test/fixtures/agent_usage_panel/formatting_scenarios.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.scenario.timeline",
      kind: "flutter-feature",
      summary: "Daily usage timeline, snapshot semantics, and interactive tooltip",
      inputs: [
        "apps/desktop/test/fixtures/agent_usage_panel/timeline_scenarios.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_agent_service_fakes.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_panel_fixtures.dart",
      ],
      command: flutterTests([
        "test/fixtures/agent_usage_panel/timeline_scenarios.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.scenario.model-share",
      kind: "flutter-feature",
      summary: "Stable model ranking, formal naming, denominator, and share bars",
      inputs: [
        "apps/desktop/test/fixtures/agent_usage_panel/model_share_scenarios.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_agent_service_fakes.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_panel_fixtures.dart",
      ],
      command: flutterTests([
        "test/fixtures/agent_usage_panel/model_share_scenarios.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.scenario.polling",
      kind: "flutter-feature",
      summary: "Bounded local token polling without presentation status churn",
      inputs: [
        "apps/desktop/test/fixtures/agent_usage_panel/polling_scenarios.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_agent_service_fakes.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_panel_fixtures.dart",
      ],
      command: flutterTests([
        "test/fixtures/agent_usage_panel/polling_scenarios.dart",
      ]),
    }),
  defineModule({
      id: "flutter.feature.agent-usage.scenario.cache",
      kind: "flutter-feature",
      summary: "Retained usage cache freshness and unload-safe refresh coalescing",
      inputs: [
        "apps/desktop/test/fixtures/agent_usage_panel/cache_scenarios.dart",
        "apps/desktop/test/fixtures/agent_usage_panel/usage_agent_service_fakes.dart",
      ],
      command: flutterTests([
        "test/fixtures/agent_usage_panel/cache_scenarios.dart",
      ]),
    }),
]);
