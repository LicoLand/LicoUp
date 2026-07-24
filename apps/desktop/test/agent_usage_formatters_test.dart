import 'package:licoup/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('usage formatters cover bounded numeric presentation', () {
    expect(formatAgentUsageNumber(0), '-');
    expect(formatAgentUsageNumber(1250), '1.3K');
    expect(formatAgentUsageNumber(2300000), '2.3M');
    expect(formatAgentUsageTooltipNumber(0), '0');
    expect(formatAgentUsagePercent(1, 4), '25%');
    expect(agentUsageShareFraction(8, 4), 1);
    expect(formatAgentUsageTimeLabel(DateTime.utc(2026, 7, 15)), '7-15');
  });
}
