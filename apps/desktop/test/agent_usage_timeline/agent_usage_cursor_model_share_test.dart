import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('model share surfaces cursor-native grok composer and fable labels', () {
    final report = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: '2026-07-21T08:00:00Z',
      summary: const {'totalTokens': 26_000_000},
      agents: [
        AgentUsageAgentSummary(
          agentId: 'codex',
          label: 'Codex',
          status: 'detected',
          history: {
            'totalTokens': 25_160_544_438,
            'dailyUsage': [
              {
                'date': '2026-07-21',
                'totalTokens': 25_160_544_438,
                'modelUsage': {
                  'gpt-5.6-sol': 25_160_544_438,
                  'gpt-5.5': 10_323_960_092,
                },
              },
            ],
          },
          confidence: 'high',
        ),
        AgentUsageAgentSummary(
          agentId: 'cursor',
          label: 'Cursor',
          status: 'detected',
          history: {
            'totalTokens': 26_171_535,
            'dailyUsage': [
              {
                'date': '2026-07-21',
                'totalTokens': 26_171_535,
                'modelUsage': {
                  'grok-4.5': 17_404_328,
                  'claude-fable-5': 1_561_773,
                  'composer-2.5-fast': 6_984_030,
                  'grok-4.5-fast-xhigh': 225_703,
                },
              },
            ],
          },
          confidence: 'high',
        ),
      ],
      warnings: const [],
      window: const {'days': 30},
    );

    final timeline = buildAgentUsageTimelineData(
      report,
      AgentUsageChartGrouping.model,
      const {'codex', 'cursor'},
      anchor: DateTime(2026, 7, 21),
    );

    expect(timeline.shareSeriesLabels, contains('Grok 4.5'));
    expect(timeline.shareSeriesLabels, contains('Claude Fable 5'));
    expect(timeline.shareSeriesLabels, contains('Composer 2.5'));
    expect(timeline.shareTotalFor('Grok 4.5'), 17_404_328);
    expect(timeline.shareTotalFor('Claude Fable 5'), 1_561_773);
    expect(timeline.shareTotalFor('Composer 2.5'), 6_984_030);
  });

  test('tokenless hosted requests stay request counts, never token totals', () {
    final report = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: '2026-07-21T08:00:00Z',
      summary: const {'totalTokens': 100},
      agents: const [
        AgentUsageAgentSummary(
          agentId: 'cursor',
          label: 'Cursor',
          status: 'detected',
          history: {
            'totalTokens': 100,
            'dailyUsage': [
              {
                'date': '2026-07-21',
                'totalTokens': 100,
                'modelUsage': {'composer-2.5': 100},
                'modelTokenUsage': {
                  'composer-2.5': {
                    'promptTokens': 80,
                    'cachedInputTokens': 0,
                    'completionTokens': 20,
                    'totalTokens': 100,
                    'requestCount': 3,
                  },
                  // Included Auto calls arrive as requests with no token
                  // fields; the share list shows the count, not a total.
                  'cursor-auto': {
                    'promptTokens': 0,
                    'cachedInputTokens': 0,
                    'completionTokens': 0,
                    'totalTokens': 0,
                    'requestCount': 7,
                    'tokenUnavailableRequests': 7,
                  },
                },
              },
            ],
          },
          confidence: 'medium',
        ),
      ],
      warnings: const [],
      window: const {'days': 30},
    );

    final timeline = buildAgentUsageTimelineData(
      report,
      AgentUsageChartGrouping.model,
      const {'cursor'},
      anchor: DateTime(2026, 7, 21),
    );

    expect(timeline.series.map((series) => series.label), ['Composer 2.5']);
    expect(timeline.totalFor('Composer 2.5'), 100);
    expect(timeline.totalFor('Cursor Auto'), 0);
    expect(timeline.requestOnlyShareLabels, ['Cursor Auto']);
    expect(timeline.requestCountFor('Cursor Auto'), 7);
    expect(timeline.requestCountFor('Composer 2.5'), 3);
    expect(timeline.groupTotal, 100);
  });
}
