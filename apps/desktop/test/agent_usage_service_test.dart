import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/services/agent_service.dart';
import 'package:flutter_client/src/services/agent_usage_service.dart';
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
                'history': {'sessionCount': 1, 'totalTokens': 18},
                'traffic': {
                  'meteredTotalBytes': 750,
                  'estimatedHistoricalBytes': 1200,
                  'attribution': 'mixed',
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
      observeMs: 1500,
    );

    expect(report.totalTokens, 18);
    expect(report.agent('codex')?.meteredTotalBytes, 750);
    expect(captured.single, [
      'agent-usage',
      'scan',
      '--agent',
      'codex',
      '--observe-ms',
      '1500',
    ]);
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
            'reports': [
              {
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
}
