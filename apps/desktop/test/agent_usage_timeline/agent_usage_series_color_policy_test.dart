import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_series_color_policy.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('series colors remain stable inside one cohesive gradient', () {
    final colors = buildLicoTheme().extension<LicoThemeColors>()!;
    final first = agentUsageSeriesColor(colors, 'unlisted-model-v7');
    final second = agentUsageSeriesColor(colors, 'unlisted-model-v7');

    final ramp = {
      for (var step = 0; step < 9; step++)
        Color.lerp(colors.textSecondary, colors.primary, step / 8),
    };
    for (final label in ['Codex', 'Claude Code', 'unlisted-model-v7']) {
      expect(ramp, contains(agentUsageSeriesColor(colors, label)));
    }
    expect(first, second);
    expect(agentUsageSeriesColor(colors, ''), colors.primaryStrong);
  });
}
