import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/controller/agent_usage_daily_cache.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';

void main() {
  test('viewport projection slices cached days without rescanning source', () {
    final cache = AgentUsageDailyCache();
    cache.ingestReport(_reportWithDailyUsage(windowDays: 90), replace: true);

    final seven = cache.projectViewport(7);
    final thirty = cache.projectViewport(30);
    final ninety = cache.projectViewport(90);

    expect(seven?.windowDays, 7);
    expect(seven?.totalTokens, 700);
    expect(thirty?.windowDays, 30);
    expect(thirty?.totalTokens, 3000);
    expect(ninety?.windowDays, 90);
    expect(ninety?.totalTokens, 9000);
  });

  test('incremental today merge replaces one day bucket', () {
    final cache = AgentUsageDailyCache();
    cache.ingestReport(_reportWithDailyUsage(windowDays: 90), replace: true);

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

    cache.mergeReport(todayReport);

    expect(cache.hasFullCoverage(), isTrue);
    expect(cache.projectViewport(7)?.totalTokens, 600 + 999);
    expect(cache.hasFreshToday(), isTrue);
  });

  test('retained report loads viewport immediately before backfill', () {
    final cache = AgentUsageDailyCache();
    cache.ingestReport(_reportWithDailyUsage(windowDays: 30), replace: true);

    expect(cache.hasFullCoverage(), isFalse);
    final viewport = cache.projectViewport(30);
    expect(viewport?.windowDays, 30);
    expect(viewport?.totalTokens, 3000);
  });

  test(
    'multi-agent 90-day retained report projects non-empty 30-day viewport',
    () {
      final cache = AgentUsageDailyCache();
      cache.ingestReport(_multiAgentReport(windowDays: 90), replace: true);

      final viewport = cache.projectViewport(30);
      expect(viewport, isNotNull);
      expect(viewport!.agents, hasLength(3));
      expect(viewport.totalTokens, greaterThan(0));
      expect(viewport.agent('cursor')?.totalTokens, 3000);
      expect(viewport.agent('codex')?.totalTokens, 3000);
      expect(viewport.agent('claude-code')?.totalTokens, 3000);
      expect(
        (viewport.agent('cursor')?.history['dailyUsage'] as List).length,
        30,
      );
    },
  );

  test(
    'merging stale 90-day and fresh 30-day reports keeps recent buckets',
    () {
      final cache = AgentUsageDailyCache();
      final staleAnchor = DateTime.now().toLocal().subtract(
        const Duration(days: 60),
      );
      cache.ingestReports([
        _reportWithDailyUsage(
          windowDays: 90,
          generatedAt: staleAnchor.toUtc().toIso8601String(),
          anchor: staleAnchor,
          agentId: 'antigravity',
          agentLabel: 'Antigravity',
        ),
        _reportWithDailyUsage(
          windowDays: 30,
          generatedAt: DateTime.now().toUtc().toIso8601String(),
          agents: {'cursor': ('Cursor', 100), 'codex': ('Codex', 200)},
        ),
      ], replace: true);

      final viewport = cache.projectViewport(30);
      expect(viewport?.totalTokens, 9000);
      expect(viewport?.agent('cursor')?.totalTokens, 3000);
      expect(viewport?.agent('codex')?.totalTokens, 6000);
      expect(viewport?.agent('antigravity')?.totalTokens, 0);
    },
  );

  test('snapshot-only aggregate totals survive viewport projection', () {
    final cache = AgentUsageDailyCache();
    cache.ingestReport(
      AgentUsageReport(
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
      ),
      replace: true,
    );

    expect(cache.hasFullCoverage(), isFalse);
    expect(cache.projectViewport(30)?.totalTokens, 140);
  });

  test('detected agents without exact metadata survive cache projection', () {
    final cache = AgentUsageDailyCache();
    cache.ingestReport(
      AgentUsageReport(
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
      ),
      replace: true,
    );

    final viewport = cache.projectViewport(30);
    expect(cache.hasFullCoverage(), isTrue);
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
