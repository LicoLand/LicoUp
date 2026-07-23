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
          agentId: 'codex-desktop',
          label: 'Codex - Desktop',
          status: 'detected',
          history: {
            'totalTokens': 70,
            'dailyUsage': [
              {
                'date': '2026-07-15',
                'totalTokens': 70,
                'modelUsage': {'gpt-5.5': 70},
                'modelTokenUsage': {
                  'gpt-5.5': {
                    'promptTokens': 60,
                    'cachedInputTokens': 20,
                    'completionTokens': 10,
                    'totalTokens': 70,
                  },
                },
              },
              {'date': '2026-05-01', 'totalTokens': 999},
            ],
          },
          confidence: 'high',
        ),
        AgentUsageAgentSummary(
          agentId: 'codex-cli',
          label: 'Codex - CLI',
          status: 'detected',
          history: {
            'totalTokens': 50,
            'dailyUsage': [
              {
                'date': '2026-07-15',
                'totalTokens': 50,
                'modelUsage': {'gpt-5.5': 50},
              },
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
      const {'codex-desktop', 'codex-cli'},
      anchor: DateTime(2026, 7, 15),
    );
    final byModel = buildAgentUsageTimelineData(
      report,
      AgentUsageChartGrouping.model,
      const {'codex-desktop', 'codex-cli'},
      anchor: DateTime(2026, 7, 15),
    );

    expect(byAgent.snapshots, hasLength(agentUsageTimelineDayCount));
    expect(byAgent.snapshots.first.time, DateTime(2026, 6, 16));
    expect(byAgent.snapshots.last.time, DateTime(2026, 7, 15));
    expect(byAgent.series.map((series) => series.label), ['Codex']);
    expect(byAgent.totalFor('Codex'), 120);
    expect(byAgent.snapshots.last.total, 120);
    expect(byAgent.groupTotal, 120);
    expect(byAgent.hasDailyBreakdown, isTrue);
    expect(byModel.series.map((series) => series.label), ['GPT 5.5']);
    expect(byModel.totalFor('GPT 5.5'), 120);
    expect(byModel.groupTotal, 120);
  });

  test('builder stretches the x-axis to the report window days', () {
    AgentUsageReport reportForWindow(int days) => AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: '2026-07-15T12:00:00Z',
      summary: const {'totalTokens': 70},
      agents: const [
        AgentUsageAgentSummary(
          agentId: 'codex',
          label: 'Codex',
          status: 'detected',
          history: {
            'totalTokens': 70,
            'dailyUsage': [
              {'date': '2026-07-15', 'totalTokens': 70},
              {'date': '2026-05-01', 'totalTokens': 999},
            ],
          },
          confidence: 'high',
        ),
      ],
      warnings: const [],
      window: {'days': days},
    );

    for (final days in [7, 30, 90, 365]) {
      final timeline = buildAgentUsageTimelineData(
        reportForWindow(days),
        AgentUsageChartGrouping.agent,
        const {'codex'},
        anchor: DateTime(2026, 7, 15),
      );
      expect(timeline.snapshots, hasLength(days));
      expect(timeline.snapshots.last.time, DateTime(2026, 7, 15));
      expect(timeline.snapshots.last.total, 70);
    }
  });

  test('displayDayCount crops the x-axis independently of report.windowDays', () {
    final report = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: '2026-07-15T12:00:00Z',
      summary: const {'totalTokens': 70},
      agents: const [
        AgentUsageAgentSummary(
          agentId: 'codex',
          label: 'Codex',
          status: 'detected',
          history: {
            'totalTokens': 70,
            'dailyUsage': [
              {'date': '2026-07-15', 'totalTokens': 70},
              {'date': '2026-05-01', 'totalTokens': 999},
            ],
          },
          confidence: 'high',
        ),
      ],
      warnings: const [],
      window: const {'days': 90},
    );

    final timeline = buildAgentUsageTimelineData(
      report,
      AgentUsageChartGrouping.agent,
      const {'codex'},
      anchor: DateTime(2026, 7, 15),
      displayDayCount: 7,
    );
    expect(timeline.snapshots, hasLength(7));
    expect(timeline.snapshots.first.time, DateTime(2026, 7, 9));
    expect(timeline.snapshots.last.time, DateTime(2026, 7, 15));
    expect(timeline.snapshots.last.total, 70);
  });
}
