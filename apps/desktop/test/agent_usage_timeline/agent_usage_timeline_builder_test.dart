import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_builder.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_timeline_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builder preserves the 30-day agent and model aggregation window', () {
    final report = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: '2026-07-15T12:00:00Z',
      summary: const {'totalTokens': 120},
      agents: const [
        AgentUsageAgentSummary(
          agentId: 'codex',
          label: 'Codex',
          status: 'detected',
          history: {
            'totalTokens': 120,
            'dailyUsage': [
              {
                'date': '2026-07-15',
                'totalTokens': 120,
                'modelUsage': {'gpt-5.5': 120},
                'modelTokenUsage': {
                  'gpt-5.5': {
                    'promptTokens': 100,
                    'cachedInputTokens': 40,
                    'completionTokens': 20,
                    'totalTokens': 120,
                  },
                },
              },
              {'date': '2026-05-01', 'totalTokens': 999},
            ],
          },
          confidence: 'high',
        ),
      ],
      warnings: const [],
    );

    final byAgent = buildAgentUsageTimelineData(
      report,
      AgentUsageChartGrouping.agent,
      const {'codex'},
      anchor: DateTime(2026, 7, 15),
    );
    final byModel = buildAgentUsageTimelineData(
      report,
      AgentUsageChartGrouping.model,
      const {'codex'},
      anchor: DateTime(2026, 7, 15),
    );

    expect(byAgent.snapshots, hasLength(agentUsageTimelineDayCount));
    expect(byAgent.snapshots.first.time, DateTime(2026, 6, 16));
    expect(byAgent.snapshots.last.time, DateTime(2026, 7, 15));
    expect(byAgent.series.map((series) => series.label), ['ChatGPT - Desktop']);
    expect(byAgent.totalFor('ChatGPT - Desktop'), 120);
    expect(byAgent.snapshots.last.total, 120);
    expect(byAgent.groupTotal, 120);
    expect(byAgent.hasDailyBreakdown, isTrue);
    expect(byModel.series.map((series) => series.label), ['GPT 5.5']);
    expect(byModel.totalFor('GPT 5.5'), 120);
    expect(byModel.groupTotal, 120);
  });
}
