import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_source_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source parser normalizes daily shapes, JSON, and token values', () {
    final entries = agentUsageDailySourceEntries([
      {
        'timestamp': '2026-07-15T09:30:00Z',
        'responseUsage': {'total_tokens': '1,200'},
      },
      {
        '2026-07-14': {'prompt_tokens': 20, 'completion_tokens': 5},
      },
      {'not-a-date': 999},
    ]);

    expect(entries.map((entry) => entry.date), ['2026-07-15', '2026-07-14']);
    expect(agentUsageTokensFromSource(entries.first.source), 1200);
    expect(agentUsageTokensFromSource(entries.last.source), 25);
    expect(agentUsageSourceDateKey(DateTime.utc(2026, 7, 3)), '2026-07-03');
    expect(agentUsageJsonObjectFromText('{"model":"gpt-5.5"}'), {
      'model': 'gpt-5.5',
    });
    expect(agentUsageJsonObjectFromText('{invalid'), isNull);
  });
}
