import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/settings/controller/agent_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/contracts/agent_resource_usage_gateway.dart';
import 'package:licoup/src/contracts/agent_resource_usage_models.dart';
import 'package:licoup/src/frontend/features/settings/ui/agent_resource_usage_card.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'fixtures/agent_usage_panel/usage_panel_fixtures.dart';

final class _SequenceGateway implements AgentResourceUsageGateway {
  _SequenceGateway(this.reports);

  final List<AgentResourceUsageReport> reports;
  int calls = 0;

  @override
  Future<AgentResourceUsageReport> scan() async {
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
  group('AgentResourceUsageCard', () {
    testWidgets('lists running agents with memory and rate chips', (
      tester,
    ) async {
      var now = DateTime(2026, 7, 31, 12, 0, 0);
      AgentResourceUsageReport both({required int codexRss, required int cursorRss}) {
        return AgentResourceUsageReport(
          schemaVersion: AgentResourceUsageReport.currentSchemaVersion,
          generatedAt: '2026-07-31T12:00:00Z',
          agents: [
            AgentResourceUsageAgent(
              target: 'codex',
              label: 'codex',
              running: true,
              processes: const [],
              totalRssBytes: codexRss,
              totalDiskReadBytes: 1000,
              totalDiskWriteBytes: 2000,
            ),
            AgentResourceUsageAgent(
              target: 'cursor',
              label: 'cursor',
              running: true,
              processes: const [],
              totalRssBytes: cursorRss,
              totalDiskReadBytes: 0,
              totalDiskWriteBytes: 0,
            ),
          ],
          summary: const {},
        );
      }

      final gateway = _SequenceGateway([
        both(codexRss: 512 * 1024 * 1024, cursorRss: 128 * 1024 * 1024),
        both(codexRss: 512 * 1024 * 1024, cursorRss: 128 * 1024 * 1024),
      ]);
      final controller = AgentResourceUsageController(
        gateway: gateway,
        now: () => now,
      );
      addTearDown(controller.dispose);
      controller.start(interval: const Duration(milliseconds: 200));

      await tester.pumpWidget(
        usageTestApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: SizedBox(
            width: 760,
            height: 560,
            child: AgentResourceUsageCard(
              gateway: gateway,
              controller: controller,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 250));
      now = now.add(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(find.text('Agent Resources'), findsOneWidget);
      expect(find.text('codex'), findsOneWidget);
      expect(find.text('cursor'), findsOneWidget);
      expect(find.text('512'), findsOneWidget);
      expect(find.text('128'), findsOneWidget);
      expect(find.text('MB'), findsNWidgets(2));
      expect(find.byIcon(Icons.download_outlined), findsNWidgets(2));
      expect(find.byIcon(Icons.upload_outlined), findsNWidgets(2));

      controller.stop();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('shows the idle notice when no agent is running', (
      tester,
    ) async {
      final gateway = _SequenceGateway([
        _report(target: 'openclaw', running: false, rss: 0),
      ]);
      final controller = AgentResourceUsageController(gateway: gateway);
      addTearDown(controller.dispose);
      controller.start(interval: const Duration(milliseconds: 200));

      await tester.pumpWidget(
        usageTestApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: SizedBox(
            width: 760,
            height: 300,
            child: AgentResourceUsageCard(
              gateway: gateway,
              controller: controller,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(find.text('No running agents detected yet.'), findsOneWidget);

      controller.stop();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
