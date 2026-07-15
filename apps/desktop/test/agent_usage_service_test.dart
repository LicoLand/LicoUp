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
            'schemaVersion': 2,
            'generatedAt': '2026-06-28T00:00:00Z',
            'summary': {
              'agentCount': 1,
              'totalTokens': 18,
              'meteredTotalBytes': 750,
              'estimatedHistoricalBytes': 1200,
              'attribution': 'mixed',
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
                'traffic': {
                  'meteredTotalBytes': 750,
                  'estimatedHistoricalBytes': 1200,
                  'attribution': 'mixed',
                },
                'allowances': [
                  {
                    'kind': 'chatgpt-weekly-limit',
                    'label': 'ChatGPT weekly limit',
                    'provider': 'ChatGPT',
                    'period': 'week',
                    'status': 'unavailable',
                    'source': 'provider-api-unconfigured',
                    'message': 'System Codex auth quota lookup is unavailable.',
                  },
                ],
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
    expect(report.agent('codex')?.meteredTotalBytes, 750);
    expect(
      report.agent('codex')?.allowances.single.kind,
      'chatgpt-weekly-limit',
    );
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
            'schemaVersion': 2,
            'generatedAt': '2026-07-02T00:00:00Z',
            'summary': {'agentCount': 1, 'totalTokens': 5},
            'agents': [
              {
                'agentId': 'codex',
                'label': 'Codex',
                'history': {'totalTokens': 5},
                'traffic': const {},
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
            'schemaVersion': 2,
            'reports': [
              {
                'schemaVersion': 2,
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

  test('rejects legacy retained report schemas', () async {
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async => ProcessResult(
        0,
        0,
        jsonEncode({
          'ok': true,
          'schemaVersion': 2,
          'reports': [
            {
              'schemaVersion': 1,
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

  test('requires schemaVersion to be the exact integer 2', () {
    for (final schemaVersion in <Object>[2.0, 2.9, '2']) {
      expect(
        () => AgentUsageReport.fromJson({
          'schemaVersion': schemaVersion,
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
          'schemaVersion': 2,
          'reports': {'schemaVersion': 2},
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
          'schemaVersion': 2,
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
