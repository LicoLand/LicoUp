import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_usage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scans agent usage through lico-client agent-usage scan', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
          jsonEncode({
            'ok': true,
            'schemaVersion': AgentUsageReport.currentSchemaVersion,
            'mode': AgentUsageReport.currentMode,
            'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
            'generatedAt': '2026-06-28T00:00:00Z',
            'summary': {
              'agentCount': 1,
              'totalTokens': 18,
              'confidence': 'high',
            },
            'agents': [
              {
                'agentId': 'codex',
                'label': 'Codex',
                'status': 'detected',
                'history': {
                  'sessionCount': 1,
                  'promptTokens': 12,
                  'cachedInputTokens': 5,
                  'completionTokens': 6,
                  'totalTokens': 18,
                },
                'confidence': 'high',
              },
            ],
          }),
          '',
        );
      },
    );
    const service = AgentUsageService();

    final report = await service.scan(
      agentService: agentService,
      agentId: 'codex',
    );

    expect(report.totalTokens, 18);
    expect(report.agent('codex')?.cachedInputTokens, 5);
    expect(report.mode, AgentUsageReport.currentMode);
    expect(report.tokenSourceMode, AgentUsageReport.currentTokenSourceMode);
    expect(captured.single.take(4), [
      'agent-usage',
      'scan',
      '--agent',
      'codex',
    ]);
    expect(captured.single, containsAll(['--history-days', '30']));
    expect(captured.single, contains('--timezone-offset-minutes'));
    expect(captured.single, contains('--timezone-transitions-json'));
  });

  test('manual scan requests a cache-aware forced refresh', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
          jsonEncode({
            'ok': true,
            'schemaVersion': AgentUsageReport.currentSchemaVersion,
            'mode': AgentUsageReport.currentMode,
            'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
            'generatedAt': '2026-07-02T00:00:00Z',
            'summary': {'agentCount': 1, 'totalTokens': 5},
            'agents': [
              {
                'agentId': 'codex',
                'label': 'Codex',
                'history': {'totalTokens': 5},
                'confidence': 'high',
              },
            ],
          }),
          '',
        );
      },
    );
    const service = AgentUsageService();

    final report = await service.scan(
      agentService: agentService,
      agentId: 'codex',
      forceRefresh: true,
    );

    expect(report.totalTokens, 5);
    expect(captured.single, containsAll(['--agent', 'codex']));
    expect(captured.single, contains('--force-refresh'));
    expect(captured.single, isNot(contains('--transient')));
  });

  test('forwards a manually selected 1-365 day history window', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
          jsonEncode({
            'ok': true,
            'schemaVersion': AgentUsageReport.currentSchemaVersion,
            'mode': AgentUsageReport.currentMode,
            'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
            'generatedAt': '2026-07-02T00:00:00Z',
            'window': {'days': 365},
            'summary': {'agentCount': 0, 'totalTokens': 0},
            'agents': const [],
          }),
          '',
        );
      },
    );

    final report = await const AgentUsageService().scan(
      agentService: agentService,
      historyDays: 365,
    );

    expect(report.windowDays, 365);
    expect(captured.single, containsAll(['--history-days', '365']));
  });

  test('loads retained agent usage reports through lico-client', () async {
    final captured = <List<String>>[];
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
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
                'generatedAt': '2026-06-28T00:00:00Z',
                'summary': {'agentCount': 1, 'totalTokens': 5},
                'agents': const [],
              },
            ],
          }),
          '',
        );
      },
    );
    const service = AgentUsageService();

    final reports = await service.reports(
      agentService: agentService,
      agentId: 'codex',
      limit: 3,
    );

    expect(reports, hasLength(1));
    expect(reports.single.totalTokens, 5);
    expect(captured.single, [
      'agent-usage',
      'report',
      '--limit',
      '3',
      '--agent',
      'codex',
    ]);
  });

  test('rejects retained reports outside the current contract', () async {
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async => ProcessResult(
        0,
        0,
        jsonEncode({
          'ok': true,
          'schemaVersion': AgentUsageReport.currentSchemaVersion,
          'mode': AgentUsageReport.currentMode,
          'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
          'reports': [
            {
              'schemaVersion': 3,
              'mode': AgentUsageReport.currentMode,
              'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
              'generatedAt': '2026-06-28T00:00:00Z',
              'summary': {'totalTokens': 999},
              'agents': const [],
            },
          ],
        }),
        '',
      ),
    );

    expect(
      () => const AgentUsageService().reports(agentService: agentService),
      throwsA(isA<FormatException>()),
    );
  });

  test('requires schemaVersion to be the exact integer 4', () {
    for (final schemaVersion in <Object>[4.0, 4.9, '4']) {
      expect(
        () => AgentUsageReport.fromJson({
          'schemaVersion': schemaVersion,
          'mode': AgentUsageReport.currentMode,
          'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
          'generatedAt': '2026-06-28T00:00:00Z',
          'summary': const <String, dynamic>{},
          'agents': const <Map<String, dynamic>>[],
        }),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('rejects a non-list retained reports payload', () async {
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async => ProcessResult(
        0,
        0,
        jsonEncode({
          'ok': true,
          'schemaVersion': AgentUsageReport.currentSchemaVersion,
          'mode': AgentUsageReport.currentMode,
          'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
          'reports': {'schemaVersion': AgentUsageReport.currentSchemaVersion},
        }),
        '',
      ),
    );

    expect(
      () => const AgentUsageService().reports(agentService: agentService),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects malformed entries inside retained reports', () async {
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async => ProcessResult(
        0,
        0,
        jsonEncode({
          'ok': true,
          'schemaVersion': AgentUsageReport.currentSchemaVersion,
          'mode': AgentUsageReport.currentMode,
          'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
          'reports': ['not-a-report'],
        }),
        '',
      ),
    );

    expect(
      () => const AgentUsageService().reports(agentService: agentService),
      throwsA(isA<FormatException>()),
    );
  });
}
