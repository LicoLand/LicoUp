import 'dart:async';
import 'dart:convert';

import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';

class UsageAgentService extends AgentService {
  UsageAgentService({String? reportGeneratedAt})
    : reportGeneratedAt =
          reportGeneratedAt ?? DateTime.now().toUtc().toIso8601String(),
      super(runCliExecutable: null);

  final String reportGeneratedAt;
  int reportCalls = 0;
  int scanCalls = 0;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'targets' && args[1] == 'scan') {
      return _targets(['claude-code', 'codex', 'opencode']);
    }
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'report') {
      reportCalls += 1;
      return jsonDecode(
            jsonEncode({
              'ok': true,
              'schemaVersion': AgentUsageReport.currentSchemaVersion,
              'mode': AgentUsageReport.currentMode,
              'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
              'reports': [
                {
                  'schemaVersion': AgentUsageReport.currentSchemaVersion,
                  'mode': AgentUsageReport.currentMode,
                  'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
                  'generatedAt': reportGeneratedAt,
                  'summary': {
                    'agentCount': 3,
                    'totalTokens': 240448446,
                    'confidence': '',
                  },
                  'agents': [
                    {
                      'agentId': 'claude-code',
                      'label': 'Claude Code',
                      'status': 'detected',
                      'history': {
                        'totalTokens': 231917287,
                        'dailyUsage': [
                          {
                            'date': _dayKey(),
                            'totalTokens': 231917287,
                            'modelUsage': {'claude-sonnet-4': 231917287},
                          },
                        ],
                        'modelUsage': [
                          {
                            'model': 'claude-sonnet-4',
                            'totalTokens': 231917287,
                          },
                        ],
                      },
                    },
                    {
                      'agentId': 'codex',
                      'label': 'Codex',
                      'status': 'detected',
                      'history': {
                        'totalTokens': 7860433,
                        'dailyUsage': [
                          {
                            'date': _dayKey(),
                            'totalTokens': 7860433,
                            'modelUsage': {'gpt-5.4': 7860433},
                          },
                        ],
                        'modelUsage': {
                          'gpt-5.4': {'totalTokens': 7860433},
                        },
                      },
                    },
                    {
                      'agentId': 'opencode',
                      'label': 'OpenCode',
                      'status': 'detected',
                      'history': {
                        'totalTokens': 670726,
                        'dailyUsage': [
                          {
                            'date': _dayKey(),
                            'totalTokens': 670726,
                            'modelUsage': {'deepseek-v4-pro': 670726},
                          },
                        ],
                      },
                    },
                  ],
                },
              ],
            }),
          )
          as Map<String, dynamic>;
    }
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'scan') {
      scanCalls += 1;
      final agentId = _argValue(args, '--agent');
      final tokens = switch (agentId) {
        'claude-code' => 231917287,
        'codex' => 7860433,
        'opencode' => 670726,
        _ => 0,
      };
      final label = switch (agentId) {
        'claude-code' => 'Claude Code',
        'codex' => 'Codex',
        'opencode' => 'OpenCode',
        _ => agentId,
      };
      return jsonDecode(
            jsonEncode({
              'ok': true,
              'schemaVersion': AgentUsageReport.currentSchemaVersion,
              'mode': AgentUsageReport.currentMode,
              'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
              'generatedAt': '2026-07-02T00:00:00Z',
              'summary': {
                'agentCount': 1,
                'totalTokens': tokens,
                'confidence': '',
              },
              'agents': [
                {
                  'agentId': agentId,
                  'label': label,
                  'status': 'detected',
                  'history': {
                    'totalTokens': tokens,
                    'dailyUsage': [
                      {
                        'date': _dayKey(),
                        'totalTokens': tokens,
                        'modelUsage': _modelUsage(agentId, tokens),
                      },
                    ],
                    'modelUsage': _modelUsage(agentId, tokens),
                  },
                },
              ],
            }),
          )
          as Map<String, dynamic>;
    }
    return {'ok': true};
  }

  String _argValue(List<String> args, String flag, {String fallback = ''}) {
    final index = args.indexOf(flag);
    if (index < 0 || index + 1 >= args.length) {
      return fallback;
    }
    return args[index + 1];
  }

  Object _modelUsage(String agentId, int tokens) {
    if (tokens <= 0) {
      return const [];
    }
    return switch (agentId) {
      'claude-code' => [
        {'model': 'claude-sonnet-4', 'totalTokens': tokens - 31917287},
        {'model': 'claude-haiku', 'totalTokens': 31917287},
      ],
      'codex' => {
        'gpt-5.4': {'totalTokens': tokens - 1000},
        'deepseek-v4-pro': {'totalTokens': 1000},
      },
      'opencode' => [
        {
          'model':
              '{"id":"deepseek-v4-pro","providerID":"deepseek","variant":"max"}',
          'promptTokens': tokens,
        },
      ],
      _ => const [],
    };
  }

  Map<String, dynamic> _targets(List<String> agentIds) {
    return {
      'ok': true,
      'candidates': [
        for (final agentId in agentIds)
          {
            'target': agentId,
            'label': switch (agentId) {
              'claude-code' => 'Claude Code',
              'codex' => 'Codex',
              'opencode' => 'OpenCode',
              _ => agentId,
            },
            'kind': 'agent',
            'status': 'detected',
            'configured': true,
            'confidence': 1,
          },
      ],
    };
  }

  String _dayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}

class DelayedStaleUsageAgentService extends UsageAgentService {
  DelayedStaleUsageAgentService()
    : super(
        reportGeneratedAt: DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 2))
            .toIso8601String(),
      );

  final Completer<void> _reportRelease = Completer<void>();
  int reportRequests = 0;

  void releaseReport() {
    if (!_reportRelease.isCompleted) {
      _reportRelease.complete();
    }
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'report') {
      reportRequests += 1;
      await _reportRelease.future;
    }
    return super.runCli(args);
  }
}

class DeltaUsageAgentService extends AgentService {
  DeltaUsageAgentService() : super(runCliExecutable: null);

  int reportCalls = 0;
  int scanCalls = 0;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'targets' && args[1] == 'scan') {
      return _targets(['claude-code', 'codex']);
    }
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'report') {
      reportCalls += 1;
      return jsonDecode(
            jsonEncode({
              'ok': true,
              'schemaVersion': AgentUsageReport.currentSchemaVersion,
              'mode': AgentUsageReport.currentMode,
              'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
              'reports': [
                _report(
                  generatedAt: DateTime.now().toUtc().toIso8601String(),
                  agents: {
                    'claude-code': ('Claude Code', 100),
                    'codex': ('Codex', 40),
                  },
                ),
              ],
            }),
          )
          as Map<String, dynamic>;
    }
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'scan') {
      scanCalls += 1;
      final agentId = _argValue(args, '--agent');
      final tokens = switch (agentId) {
        'claude-code' => 100,
        'codex' => 40,
        _ => 0,
      };
      final label = switch (agentId) {
        'claude-code' => 'Claude Code',
        'codex' => 'Codex',
        _ => agentId,
      };
      return jsonDecode(
            jsonEncode(
              _report(
                generatedAt: '2026-07-02T00:00:00Z',
                agents: {agentId: (label, tokens)},
              ),
            ),
          )
          as Map<String, dynamic>;
    }
    return {'ok': true};
  }

  Map<String, dynamic> _report({
    required String generatedAt,
    required Map<String, (String, int)> agents,
  }) {
    final total = agents.values.fold<int>(0, (sum, agent) => sum + agent.$2);
    return {
      'ok': true,
      'schemaVersion': AgentUsageReport.currentSchemaVersion,
      'mode': AgentUsageReport.currentMode,
      'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
      'generatedAt': generatedAt,
      'summary': {
        'agentCount': agents.length,
        'totalTokens': total,
        'confidence': '',
      },
      'agents': [
        for (final entry in agents.entries)
          {
            'agentId': entry.key,
            'label': entry.value.$1,
            'status': 'detected',
            'history': {
              'totalTokens': entry.value.$2,
              'dailyUsage': [
                {
                  'date': _dayKey(),
                  'totalTokens': entry.value.$2,
                  'modelUsage': {'${entry.key}-model': entry.value.$2},
                },
              ],
              'modelUsage': {
                '${entry.key}-model': {'totalTokens': entry.value.$2},
              },
            },
          },
      ],
    };
  }

  String _argValue(List<String> args, String flag, {String fallback = ''}) {
    final index = args.indexOf(flag);
    if (index < 0 || index + 1 >= args.length) {
      return fallback;
    }
    return args[index + 1];
  }

  Map<String, dynamic> _targets(List<String> agentIds) {
    return {
      'ok': true,
      'candidates': [
        for (final agentId in agentIds)
          {
            'target': agentId,
            'label': switch (agentId) {
              'claude-code' => 'Claude Code',
              'codex' => 'Codex',
              _ => agentId,
            },
            'kind': 'agent',
            'status': 'detected',
            'configured': true,
            'confidence': 1,
          },
      ],
    };
  }

  String _dayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}
