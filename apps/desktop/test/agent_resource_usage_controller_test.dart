import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/settings/controller/agent_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/contracts/agent_resource_usage_gateway.dart';
import 'package:licoup/src/contracts/agent_resource_usage_models.dart';

final class _SequenceGateway implements AgentResourceUsageGateway {
  _SequenceGateway(this.reports);

  final List<AgentResourceUsageReport> reports;
  int calls = 0;
  bool failing = false;

  @override
  Future<AgentResourceUsageReport> scan() async {
    if (failing) {
      throw const FileSystemException('scan failed');
    }
    final report = reports[calls++ % reports.length];
    return report;
  }
}

AgentResourceUsageReport _report({
  required String target,
  required bool running,
  required int rss,
  int? read,
  int? write,
}) {
  return AgentResourceUsageReport(
    schemaVersion: AgentResourceUsageReport.currentSchemaVersion,
    generatedAt: '2026-07-31T12:00:00Z',
    agents: [
      AgentResourceUsageAgent(
        target: target,
        label: target,
        running: running,
        processes: const [],
        totalRssBytes: rss,
        totalDiskReadBytes: read,
        totalDiskWriteBytes: write,
      ),
    ],
    summary: const {},
  );
}

void main() {
  group('AgentResourceUsageController', () {
    test('samples running agents and computes per-agent deltas', () async {
      var now = DateTime(2026, 7, 31, 12, 0, 0);
      final gateway = _SequenceGateway([
        _report(
          target: 'codex',
          running: true,
          rss: 100,
          read: 1000,
          write: 2000,
        ),
        _report(
          target: 'codex',
          running: true,
          rss: 120,
          read: 1600,
          write: 2100,
        ),
        _report(target: 'codex', running: false, rss: 0),
      ]);
      final controller = AgentResourceUsageController(
        gateway: gateway,
        now: () => now,
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.samplesFor('codex'), isEmpty);
      expect(controller.latestByAgent, isEmpty);

      now = now.add(const Duration(seconds: 5));
      await controller.refresh();
      var samples = controller.samplesFor('codex');
      expect(samples, hasLength(1));
      expect(samples.single.rssBytes, 120);
      expect(samples.single.deltaReadBytes, 600);
      expect(samples.single.deltaWriteBytes, 100);
      expect(samples.single.interval, const Duration(seconds: 5));

      now = now.add(const Duration(seconds: 5));
      await controller.refresh();
      samples = controller.samplesFor('codex');
      expect(samples, hasLength(1));
      expect(controller.latestByAgent['codex']!.rssBytes, 120);
    });

    test('idle agents never appear in the sample history', () async {
      final gateway = _SequenceGateway([
        _report(target: 'cursor', running: false, rss: 0),
      ]);
      final controller = AgentResourceUsageController(gateway: gateway);
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.latestByAgent, isEmpty);
      expect(controller.samplesFor('cursor'), isEmpty);
    });

    test(
      'retains at most the configured number of samples per agent',
      () async {
        var now = DateTime(2026, 7, 31, 12, 0, 0);
        final reports = [
          for (var i = 0; i < 220; i += 1)
            _report(target: 'codex', running: true, rss: 100 + i),
        ];
        final gateway = _SequenceGateway(reports);
        final controller = AgentResourceUsageController(
          gateway: gateway,
          now: () => now,
        );
        addTearDown(controller.dispose);

        await controller.refresh();
        for (var i = 0; i < 200; i += 1) {
          now = now.add(const Duration(seconds: 5));
          await controller.refresh();
        }

        final samples = controller.samplesFor('codex');
        expect(samples.length, agentResourceUsageMaxSamples);
        expect(samples.first.rssBytes, 121);
        expect(samples.last.rssBytes, 300);
      },
    );

    test('scan failures set an error and do not add samples', () async {
      final gateway = _SequenceGateway([
        _report(target: 'codex', running: true, rss: 100),
      ]);
      final controller = AgentResourceUsageController(gateway: gateway);
      addTearDown(controller.dispose);

      await controller.refresh();
      gateway.failing = true;
      await controller.refresh();
      expect(controller.lastError, isNotNull);
      expect(controller.samplesFor('codex'), isEmpty);
    });

    test('start schedules periodic sampling and stop cancels it', () async {
      final gateway = _SequenceGateway([
        _report(target: 'codex', running: true, rss: 100),
      ]);
      final controller = AgentResourceUsageController(gateway: gateway);
      addTearDown(controller.dispose);

      controller.start(interval: const Duration(seconds: 1));
      expect(controller.isSampling, isTrue);
      controller.stop();
      expect(controller.isSampling, isFalse);
    });

    test('notifies listeners after each successful scan', () async {
      final gateway = _SequenceGateway([
        _report(target: 'codex', running: true, rss: 100),
        _report(target: 'codex', running: true, rss: 110),
      ]);
      final controller = AgentResourceUsageController(gateway: gateway);
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.changes.listen((_) => notifications += 1);

      await controller.refresh();
      expect(notifications, 1);
      await controller.refresh();
      expect(notifications, 2);
    });
  });
}
