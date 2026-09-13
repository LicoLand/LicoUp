import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_series_color_policy.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_models.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final colors = buildLicoTheme().extension<LicoThemeColors>()!;
  test(
    'Agent brand accents are distinct and stable across changes in rank',
    () {
      expect(
        agentUsageSeriesColor(colors, 'Claude Code'),
        const Color(0xFFD97757),
      );
      expect(
        agentUsageSeriesColor(colors, 'Kilo Code'),
        const Color(0xFFF8F676),
      );
      expect(agentUsageSeriesColor(colors, 'Kimi'), const Color(0xFF1783FF));
      final labels = [
        'Codex',
        'Claude Code',
        'Cursor',
        'Kilo Code',
        'Antigravity',
        'Kimi Code',
        'GitHub Copilot',
      ];
      expect(
        labels
            .map((label) => agentUsageSeriesColor(colors, label))
            .toSet()
            .length,
        labels.length,
      );
      for (final label in [
        'Antigravity',
        'Kimi',
        'Kimi Code',
        'GitHub Copilot',
      ]) {
        expect(
          HSLColor.fromColor(agentUsageSeriesColor(colors, label)).hue,
          inInclusiveRange(205, 275),
        );
      }
      expect(
        agentUsageSeriesColor(colors, 'new-agent'),
        agentUsageSeriesColor(colors, 'NEW AGENT'),
      );
    },
  );

  test('models use their developer hue and stronger tiers deepen that hue', () {
    double brightness(Color color) => color.r + color.g + color.b;
    Color model(String label) => agentUsageSeriesColor(
      colors,
      label,
      grouping: AgentUsageChartGrouping.model,
    );
    final claude = [
      'Claude Haiku 4.6',
      'Claude Sonnet 4.6',
      'Claude Opus 4.6',
      'Claude Fable 5',
    ].map(model).map(HSLColor.fromColor).toList();
    for (var i = 1; i < claude.length; i++) {
      expect(claude[i].lightness, lessThan(claude[i - 1].lightness));
      expect(claude[i].hue, closeTo(claude[0].hue, 1));
    }
    expect(
      brightness(model('GPT-6 Astra')),
      lessThan(brightness(model('GPT-5.6 Sol'))),
    );
    expect(
      brightness(model('Grok 4.6')),
      lessThan(brightness(model('Grok 4.5'))),
    );
    expect(
      brightness(model('GPT-5.10')),
      lessThan(brightness(model('GPT-5.9'))),
    );
    expect(model('Claude Opus 4.6 20260913'), model('Claude Opus 4.6'));
    expect(
      model('Claude Opus 4.6'),
      isNot(agentUsageSeriesColor(colors, 'Cursor')),
    );
  });

  test(
    'native display facts select brand color while canonical IDs keep unknown colors stable',
    () {
      expect(
        agentUsageSeriesColor(
          colors,
          'moonshotai/kimi-k3',
          grouping: AgentUsageChartGrouping.model,
          displayName: 'Kimi K3',
        ),
        agentUsageSeriesColor(
          colors,
          'Kimi K3',
          grouping: AgentUsageChartGrouping.model,
        ),
      );
      expect(
        agentUsageSeriesColor(
          colors,
          'custom/model-id',
          grouping: AgentUsageChartGrouping.model,
          displayName: 'Research Model',
        ),
        agentUsageSeriesColor(
          colors,
          'custom/model-id',
          grouping: AgentUsageChartGrouping.model,
          displayName: 'Research Renamed',
        ),
      );
    },
  );
}
