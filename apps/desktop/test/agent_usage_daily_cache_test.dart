import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/controller/agent_usage_daily_cache.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';

void main() {
  test('viewport projection slices one native report without merging', () {
    final source = _reportWithDailyUsage(windowDays: 90);

    final seven = projectViewport(source, 7);
    final thirty = projectViewport(source, 30);
    final ninety = projectViewport(source, 90);

    expect(seven?.windowDays, 7);
    expect(seven?.totalTokens, 700);
    expect(thirty?.windowDays, 30);
    expect(thirty?.totalTokens, 3000);
    expect(ninety?.windowDays, 90);
    expect(ninety?.totalTokens, 9000);
  });

  test('a one-day native projection replaces rather than merging days', () {
    final today = agentUsageWindowDateKeys(1).single;
    final todayReport = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      summary: const {
        'agentCount': 1,
        'totalTokens': 999,
        'confidence': 'high',
      },
      agents: [
        AgentUsageAgentSummary(
          agentId: 'codex',
          label: 'Codex',
          status: 'detected',
          history: {
            'dailyUsage': [
              {
                'date': today,
                'totalTokens': 999,
                'promptTokens': 800,
                'cachedInputTokens': 100,
                'completionTokens': 199,
              },
            ],
          },
          confidence: 'high',
        ),
      ],
      warnings: const [],
      window: const {'days': 1},
    );

    final viewport = projectViewport(todayReport, 7);
    expect(viewport?.totalTokens, 999);
    expect(viewport?.windowDays, 7);
  });

  test('partial native window still projects the requested viewport', () {
    final source = _reportWithDailyUsage(windowDays: 30);
    final viewport = projectViewport(source, 30);
    expect(viewport?.windowDays, 30);
    expect(viewport?.totalTokens, 3000);
  });

  test('multi-agent native report projects a non-empty 30-day viewport', () {
    final source = _multiAgentReport(windowDays: 90);
    final viewport = projectViewport(source, 30);
    expect(viewport, isNotNull);
    expect(viewport!.agents, hasLength(3));
    expect(viewport.totalTokens, greaterThan(0));
    expect(viewport.agent('cursor')?.totalTokens, 3000);
    expect(viewport.agent('codex')?.totalTokens, 3000);
    expect(viewport.agent('claude-code')?.totalTokens, 3000);
    expect((viewport.agent('cursor')?.history['dailyUsage'] as List).length, 30);
  });

  test('newest native projection is the only Flutter owner', () {
    final fresh = _reportWithDailyUsage(
      windowDays: 30,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      agents: {'cursor': ('Cursor', 100), 'codex': ('Codex', 200)},
    );
    final viewport = projectViewport(fresh, 30);
    expect(viewport?.totalTokens, 9000);
    expect(viewport?.agent('cursor')?.totalTokens, 3000);
    expect(viewport?.agent('codex')?.totalTokens, 6000);
    expect(viewport?.agent('antigravity'), isNull);
  });

  test('snapshot-only aggregate totals survive viewport projection', () {
    final source = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      summary: const {
        'agentCount': 1,
        'totalTokens': 140,
        'confidence': 'high',
      },
      agents: [
        AgentUsageAgentSummary(
          agentId: 'codex',
          label: 'Codex',
          status: 'detected',
          history: {
            'totalTokens': 140,
            'modelUsage': {'gpt-5.4': 140},
          },
          confidence: 'high',
        ),
      ],
      warnings: const [],
      window: const {'days': 90},
    );

    expect(projectViewport(source, 30)?.totalTokens, 140);
  });

  test('detected agents without exact metadata survive projection', () {
    final source = AgentUsageReport(
      schemaVersion: AgentUsageReport.currentSchemaVersion,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      summary: const {'agentCount': 2, 'totalTokens': 0},
      agents: const [
        AgentUsageAgentSummary(
          agentId: 'antigravity',
          label: 'Antigravity',
          status: 'detected',
          history: {},
          confidence: 'unavailable',
        ),
        AgentUsageAgentSummary(
          agentId: 'cursor',
          label: 'Cursor',
          status: 'detected',
          history: {},
          confidence: 'unavailable',
        ),
      ],
      warnings: const [],
      window: const {'days': 90},
    );

    final viewport = projectViewport(source, 30);
    expect(viewport?.agents.map((agent) => agent.agentId), [
      'antigravity',
      'cursor',
    ]);
    expect(viewport?.agent('cursor')?.confidence, 'unavailable');
  });
}

AgentUsageReport _reportWithDailyUsage({
  required int windowDays,
  String? generatedAt,
  DateTime? anchor,
  String agentId = 'codex',
  String agentLabel = 'Codex',
  Map<String, (String, int)>? agents,
}) {
  final base = (anchor ?? DateTime.now()).toLocal();
  final today = DateTime(base.year, base.month, base.day);
  final resolvedAgents = agents ?? {agentId: (agentLabel, 100)};
  final agentSummaries = [
    for (final entry in resolvedAgents.entries)
      AgentUsageAgentSummary(
        agentId: entry.key,
        label: entry.value.$1,
        status: 'detected',
        history: {
          'totalTokens': windowDays * entry.value.$2,
          'promptTokens': windowDays * (entry.value.$2 * 8 ~/ 10),
          'cachedInputTokens': windowDays * (entry.value.$2 ~/ 10),
          'completionTokens': windowDays * (entry.value.$2 ~/ 5),
          'dailyUsage': [
            for (var offset = windowDays - 1; offset >= 0; offset -= 1)
              {
                'date': _dateKey(
                  DateTime(today.year, today.month, today.day - offset),
                ),
                'totalTokens': entry.value.$2,
                'promptTokens': entry.value.$2 * 8 ~/ 10,
                'cachedInputTokens': entry.value.$2 ~/ 10,
                'completionTokens': entry.value.$2 ~/ 5,
                'modelUsage': {'${entry.key}-model': entry.value.$2},
              },
          ],
          'modelUsage': {'${entry.key}-model': windowDays * entry.value.$2},
        },
        confidence: 'high',
      ),
  ];
  final totalTokens =
      windowDays *
      resolvedAgents.values.fold<int>(0, (sum, agent) => sum + agent.$2);
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: generatedAt ?? DateTime.now().toUtc().toIso8601String(),
    summary: {
      'agentCount': resolvedAgents.length,
      'sessionCount': resolvedAgents.length,
      'messageCount': windowDays * resolvedAgents.length,
      'totalTokens': totalTokens,
      'confidence': 'high',
    },
    agents: agentSummaries,
    warnings: const [],
    window: {'days': windowDays},
  );
}

AgentUsageReport _multiAgentReport({required int windowDays}) {
  return _reportWithDailyUsage(
    windowDays: windowDays,
    agents: {
      'cursor': ('Cursor', 100),
      'codex': ('Codex', 100),
      'claude-code': ('Claude Code', 100),
    },
  );
}

String _dateKey(DateTime value) {
  final day = DateTime(value.year, value.month, value.day);
  return '${day.year}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}
