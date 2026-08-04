import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/agent_resource_usage_models.dart';

void main() {
  group('AgentResourceUsageReport.fromJson', () {
    test('parses running and idle agents with process counters', () {
      final report = AgentResourceUsageReport.fromJson({
        'ok': true,
        'schemaVersion': 1,
        'generatedAt': '2026-07-31T12:00:00.000000000Z',
        'agents': [
          {
            'target': 'codex',
            'label': 'Codex',
            'running': true,
            'processes': [
              {
                'pid': 10,
                'name': 'codex',
                'rssBytes': 4096,
                'diskReadBytes': 1000,
                'diskWriteBytes': 2000,
              },
            ],
            'totalRssBytes': 4096,
            'totalDiskReadBytes': 1000,
            'totalDiskWriteBytes': 2000,
          },
          {
            'target': 'openclaw',
            'label': 'OpenClaw',
            'running': false,
            'processes': [],
            'totalRssBytes': 0,
            'totalDiskReadBytes': null,
            'totalDiskWriteBytes': null,
          },
        ],
        'summary': {'agentCount': 2, 'runningAgentCount': 1, 'totalRssBytes': 4096},
      });

      expect(report.schemaVersion, 1);
      expect(report.agents, hasLength(2));
      final codex = report.agents.first;
      expect(codex.target, 'codex');
      expect(codex.running, isTrue);
      expect(codex.totalRssBytes, 4096);
      expect(codex.totalDiskReadBytes, 1000);
      expect(codex.processes.single.pid, 10);
      final openclaw = report.agents.last;
      expect(openclaw.running, isFalse);
      expect(openclaw.totalDiskReadBytes, isNull);
      expect(report.summary['runningAgentCount'], 1);
    });

    test('tolerates missing optional counters', () {
      final report = AgentResourceUsageReport.fromJson({
        'schemaVersion': 1,
        'generatedAt': '2026-07-31T12:00:00Z',
        'agents': [
          {'target': 'codex', 'label': 'Codex', 'running': true, 'processes': [], 'totalRssBytes': 5},
        ],
        'summary': {},
      });
      expect(report.agents.single.running, isTrue);
      expect(report.agents.single.totalRssBytes, 5);
    });
  });
}
