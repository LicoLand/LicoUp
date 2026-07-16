import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

Widget usageTestApp({required ThemeData theme, required Widget home}) {
  return MaterialApp(
    builder: (context, child) => Material(child: child),
    theme: theme,
    home: home,
  );
}

List<TargetCandidate> testTargets(List<String> agentIds) {
  return [
    for (final agentId in agentIds)
      TargetCandidate(
        target: agentId,
        label: switch (agentId) {
          'claude-code' => 'Claude Code',
          'codex' => 'Codex',
          'opencode' => 'OpenCode',
          _ => agentId,
        },
        kind: 'agent',
        status: 'detected',
        configured: true,
        confidence: 1,
        adapterStatus: 'available',
      ),
  ];
}

AgentUsageReport snapshotOnlyReport({
  required String generatedAt,
  required int totalTokens,
}) {
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: generatedAt,
    summary: {
      'agentCount': 1,
      'totalTokens': totalTokens,
      'confidence': 'high',
    },
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: {
          'totalTokens': totalTokens,
          'modelUsage': {
            'gpt-5.4': {'totalTokens': totalTokens},
          },
        },
        confidence: 'high',
      ),
    ],
    warnings: const [],
  );
}

AgentUsageReport equalModelUsageReport() {
  final now = DateTime.now();
  final date =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final modelUsage = {
    for (var index = 0; index < 11; index += 1)
      'model-${String.fromCharCode('a'.codeUnitAt(0) + index)}': 100,
  };
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: now.toUtc().toIso8601String(),
    summary: const {'agentCount': 1, 'totalTokens': 1100, 'confidence': 'high'},
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: {
          'totalTokens': 1100,
          'dailyUsage': [
            {'date': date, 'totalTokens': 1100, 'modelUsage': modelUsage},
          ],
          'modelUsage': modelUsage,
        },
        confidence: 'high',
      ),
    ],
    warnings: const [],
  );
}

AgentUsageReport formalNamingUsageReport() {
  final date = dayKeyForNow();
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    summary: const {'agentCount': 4, 'totalTokens': 2799, 'confidence': 'high'},
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: {
          'totalTokens': 1600,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 1600,
              'modelUsage': [
                {'model': 'openai/gpt-5.5', 'totalTokens': 500},
                {'model': 'GPT_5.5', 'totalTokens': 50},
                {'model': 'gpt-5.6-sol', 'totalTokens': 400},
                {'model': 'claude-opus-4.6', 'totalTokens': 300},
                {'model': 'deepseek-v4-flash', 'totalTokens': 200},
                {'model': 'deepseek_v4_pro', 'totalTokens': 100},
                {'model': 'Others', 'totalTokens': 50},
              ],
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
          'totalTokens': 75,
          'dailyUsage': [
            {
              'date': dayKeyForOffset(-1),
              'totalTokens': 75,
              'modelUsage': {'cursor-auto': 75},
            },
          ],
        },
        confidence: 'high',
      ),
      AgentUsageAgentSummary(
        agentId: 'kimi-code',
        label: 'Kimi Code',
        status: 'detected',
        history: {
          'totalTokens': 125,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 125,
              'modelUsage': {'kimi-k2.5': 125},
            },
          ],
        },
        confidence: 'high',
      ),
      AgentUsageAgentSummary(
        agentId: 'code',
        label: 'VS Code',
        status: 'detected',
        history: {
          'totalTokens': 999,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 999,
              'modelUsage': {'fake-vscode-model': 999},
            },
          ],
        },
        confidence: 'low',
      ),
    ],
    warnings: const [],
  );
}

AgentUsageReport shareFractionUsageReport() {
  final date = dayKeyForNow();
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    summary: const {'agentCount': 2, 'totalTokens': 1000, 'confidence': 'high'},
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: {
          'totalTokens': 550,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 550,
              'modelUsage': {'gpt-5.5': 550},
              'modelTokenUsage': {
                'gpt-5.5': {'totalTokens': 550},
              },
            },
          ],
        },
        confidence: 'high',
      ),
      AgentUsageAgentSummary(
        agentId: 'claude-code',
        label: 'Claude Code',
        status: 'detected',
        history: {
          'totalTokens': 450,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 450,
              'modelUsage': {'claude-sonnet-4': 450},
              'modelTokenUsage': {
                'claude-sonnet-4': {'totalTokens': 450},
              },
            },
          ],
        },
        confidence: 'high',
      ),
    ],
    warnings: const [],
  );
}

double progressFillFactor(WidgetTester tester, String label) {
  final progress = find.byKey(ValueKey('usage-progress-$label'));
  final track = find.descendant(
    of: progress,
    matching: find.byKey(const ValueKey('usage-progress-track')),
  );
  final fill = find.descendant(
    of: progress,
    matching: find.byKey(const ValueKey('usage-progress-fill')),
  );
  final trackWidth = tester.getSize(track).width;
  expect(trackWidth, greaterThan(0));
  return tester.getSize(fill).width / trackWidth;
}

String dayKeyForNow() {
  return dayKeyForOffset(0);
}

String dayKeyForOffset(int days) {
  final now = DateTime.now().add(Duration(days: days));
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}
