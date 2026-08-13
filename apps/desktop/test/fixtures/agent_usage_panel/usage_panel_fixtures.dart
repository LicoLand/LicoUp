import 'package:flutter/material.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
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
  int windowDays = 90,
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
    window: {'days': windowDays},
  );
}

/// Shared current-generation 52-Token workflow fixture used by contract,
/// controller, widget, localization, and rendered-evidence tests. Unknown
/// content/location fields are intentional canaries: the Dart model must drop
/// them before any UI projection.
AgentUsageReport syntheticWorkflowUsageReport({
  String workflowSchema = agentUsageWorkflowReportSchema,
}) {
  Map<String, dynamic> node({
    required String id,
    required String role,
    required String agent,
    required String model,
    required String state,
    required String dispatch,
    String? parent,
    String? task,
    required int prompt,
    required int cached,
    required int completion,
    String accuracy = 'exact',
  }) {
    return {
      'nodeId': id,
      if (parent != null) 'parentNodeId': parent,
      'planCode': 'PLAN-TREE',
      'planRevision': 2,
      if (task != null) 'taskCode': task,
      'phase': role,
      'dispatchId': dispatch,
      'role': role,
      'attempt': 1,
      'agentId': agent,
      'model': model,
      'accuracy': accuracy,
      'sessionMode': 'resume',
      'state': state,
      'usageSettlement': 'ready',
      'usage': {
        'promptTokens': prompt,
        'cachedInputTokens': cached,
        'completionTokens': completion,
        'totalTokens': prompt + completion,
      },
      'path': 'private-workflow-location-canary',
      'prompt': 'private-prompt-canary',
      'reply': 'private-reply-canary',
      'toolPayload': 'private-tool-canary',
    };
  }

  final rootId = 'delivery-tree-root';
  final nodes = [
    node(
      id: rootId,
      role: 'main',
      agent: 'main-agent',
      model: 'main-model',
      state: 'completed',
      dispatch: 'delivery-tree-root-dispatch',
      prompt: 10,
      cached: 2,
      completion: 3,
    ),
    node(
      id: 'designer-node',
      parent: rootId,
      role: 'designer',
      agent: 'agent-designer',
      model: 'model-designer',
      state: 'completed',
      dispatch: 'designer-dispatch',
      task: 'DESIGN',
      prompt: 10,
      cached: 2,
      completion: 2,
    ),
    node(
      id: 'worker-node',
      parent: rootId,
      role: 'worker',
      agent: 'agent-worker',
      model: 'model-worker',
      state: 'completed',
      dispatch: 'worker-dispatch',
      task: 'IMPLEMENT',
      prompt: 6,
      cached: 1,
      completion: 2,
    ),
    node(
      id: 'reviewer-node',
      parent: rootId,
      role: 'reviewer',
      agent: 'agent-reviewer',
      model: 'model-reviewer',
      state: 'completed',
      dispatch: 'reviewer-dispatch',
      task: 'REVIEW',
      prompt: 15,
      cached: 3,
      completion: 4,
    ),
  ];
  return AgentUsageReport.fromJson({
    'ok': true,
    'schemaVersion': AgentUsageReport.currentSchemaVersion,
    'mode': AgentUsageReport.currentMode,
    'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
    'generatedAt': '2026-08-09T00:00:00Z',
    'summary': {'agentCount': 1, 'totalTokens': 0, 'confidence': 'high'},
    'agents': [
      {
        'agentId': 'codex',
        'label': 'Codex',
        'status': 'detected',
        'history': const {'totalTokens': 12},
        'confidence': 'high',
      },
    ],
    'workflow': {
      'ok': true,
      'schemaVersion': workflowSchema,
      'ledgerSchemaVersion': agentUsageWorkflowLedgerSchemaVersion,
      'resultKind': agentUsageWorkflowResultKind,
      'summary': const {
        'promptTokens': 41,
        'cachedInputTokens': 8,
        'completionTokens': 11,
        'totalTokens': 52,
        'exactCount': 4,
        'estimatedCount': 0,
      },
      'workflows': [
        {
          'workflowId': 'delivery-tree',
          'planCode': 'PLAN-TREE',
          'planRevision': 2,
          'state': 'completed',
          'terminalCorrelation': 'terminal-tree',
          'totals': {
            'promptTokens': 41,
            'cachedInputTokens': 8,
            'completionTokens': 11,
            'totalTokens': 52,
            'exactCount': 4,
            'estimatedCount': 0,
          },
          'nodes': nodes,
          'roots': const [],
          'nativePath': 'private-workflow-location-canary',
          'summary': 'private-summary-canary',
        },
      ],
    },
    'workflows': const [],
    'workflowSummary': const {},
    'warnings': const [],
  });
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
