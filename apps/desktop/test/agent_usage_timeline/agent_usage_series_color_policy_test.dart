import 'package:flutter/material.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_series_color_policy.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('series colors preserve known and stable fallback assignments', () {
    final colors = buildLicoTheme().extension<LicoThemeColors>()!;
    final first = agentUsageSeriesColor(colors, 'unlisted-model-v7');
    final second = agentUsageSeriesColor(colors, 'unlisted-model-v7');

    expect(agentUsageSeriesColor(colors, 'Codex'), const Color(0xFF38BDF8));
    expect(
      agentUsageSeriesColor(colors, 'Claude Code'),
      const Color(0xFFF59E0B),
    );
    expect(first, second);
    expect(agentUsageSeriesColor(colors, ''), colors.primaryStrong);
  });
}
