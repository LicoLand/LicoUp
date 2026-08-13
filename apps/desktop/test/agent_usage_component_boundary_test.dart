import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('usage panel components form a one-way normal-library graph', () {
    const root = 'lib/src/frontend/features/agents/ui';
    final panel = File('$root/agent_usage_panel.dart').readAsStringSync();
    final charts = File(
      '$root/agent_usage_panel_widgets.dart',
    ).readAsStringSync();
    final overview = File(
      '$root/agent_usage_wave_overview.dart',
    ).readAsStringSync();
    final controls = File(
      '$root/agent_usage_chart_controls.dart',
    ).readAsStringSync();
    final painter = File(
      '$root/agent_usage_wave_chart_painter.dart',
    ).readAsStringSync();
    final geometry = File(
      '$root/agent_usage_chart_geometry.dart',
    ).readAsStringSync();
    final timelineFacade = File(
      '$root/agent_usage_timeline_data.dart',
    ).readAsStringSync();
    final timelineLeaves = {
      'models': File(
        '$root/agent_usage_timeline/agent_usage_timeline_models.dart',
      ).readAsStringSync(),
      'builder': File(
        '$root/agent_usage_timeline/agent_usage_timeline_builder.dart',
      ).readAsStringSync(),
      'source-parser': File(
        '$root/agent_usage_timeline/agent_usage_source_parser.dart',
      ).readAsStringSync(),
      'token-breakdown': File(
        '$root/agent_usage_timeline/agent_usage_token_breakdown.dart',
      ).readAsStringSync(),
      'display-names': File(
        '$root/agent_usage_timeline/agent_usage_display_names.dart',
      ).readAsStringSync(),
      'series-color': File(
        '$root/agent_usage_timeline/agent_usage_series_color_policy.dart',
      ).readAsStringSync(),
      'visibility': File(
        '$root/agent_usage_timeline/agent_usage_visibility_policy.dart',
      ).readAsStringSync(),
    };
    final summary = File(
      '$root/agent_usage_summary_widgets.dart',
    ).readAsStringSync();
    final formatters = File(
      '$root/agent_usage_formatters.dart',
    ).readAsStringSync();

    expect(panel, contains("ui/agent_usage_panel_widgets.dart';"));
    expect(charts, contains("ui/agent_usage_timeline_data.dart';"));
    expect(charts, contains("ui/agent_usage_summary_widgets.dart';"));
    expect(charts, contains("ui/agent_usage_formatters.dart';"));
    expect(charts, contains("ui/agent_usage_wave_overview.dart';"));
    expect(overview, contains("ui/agent_usage_chart_controls.dart';"));
    expect(overview, contains("ui/agent_usage_wave_chart_painter.dart';"));
    expect(painter, contains("ui/agent_usage_chart_geometry.dart';"));
    expect(controls, isNot(contains('agent_usage_panel_widgets.dart')));
    expect(painter, isNot(contains('agent_usage_panel_widgets.dart')));
    expect(geometry, isNot(contains('agent_usage_panel_widgets.dart')));
    for (final leaf in [
      timelineFacade,
      ...timelineLeaves.values,
      summary,
      formatters,
    ]) {
      expect(leaf, isNot(contains('agent_usage_panel.dart')));
      expect(leaf, isNot(contains('agent_usage_panel_widgets.dart')));
    }
    expect(
      timelineFacade,
      isNot(contains(RegExp(r'^(?:class|enum) ', multiLine: true))),
    );
    expect(timelineFacade, isNot(contains('buildAgentUsageTimelineData(')));
    expect(
      RegExp(r'^export ', multiLine: true).allMatches(timelineFacade),
      hasLength(timelineLeaves.length),
    );
    for (final entry in timelineLeaves.entries) {
      expect(entry.value, isNot(contains('agent_usage_timeline_data.dart')));
    }
    for (final source in [
      panel,
      charts,
      overview,
      controls,
      painter,
      geometry,
      timelineFacade,
      ...timelineLeaves.values,
      summary,
      formatters,
    ]) {
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }
    expect(charts, isNot(contains('class AgentUsageWaveChartPainter')));
    expect(overview, isNot(contains('void paint(Canvas')));
  });
}
