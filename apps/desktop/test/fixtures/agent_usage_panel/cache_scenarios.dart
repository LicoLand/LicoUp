import 'package:flutter/material.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'usage_agent_service_fakes.dart';
import 'monitoring_binding_fixture.dart';
import 'usage_panel_fixtures.dart';

void registerAgentUsageCacheScenarios() {
  testWidgets('agent usage panel refreshes stale retained data once', (
    tester,
  ) async {
    final service = UsageAgentService(
      reportGeneratedAt: DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 2))
          .toIso8601String(),
    );
    final controller = ClientController(agentService: service);
    final monitoring = MonitoringBindingFixture(controller);
    addTearDown(() async {
      await monitoring.close();
      controller.dispose();
    });

    await tester.pumpWidget(
      usageTestApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 980,
          height: 620,
          child: AgentUsagePanel(binding: monitoring.binding, onExit: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(service.reportCalls, 1);
    expect(service.scanCalls, 1);
  });

  testWidgets(
    'stale retained refresh survives a fast panel unload and re-entry',
    (tester) async {
      final service = DelayedStaleUsageAgentService();
      final controller = ClientController(agentService: service);
      final monitoring = MonitoringBindingFixture(controller);
      addTearDown(() async {
        await monitoring.close();
        controller.dispose();
      });

      Widget panel() => usageTestApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 980,
          height: 620,
          child: AgentUsagePanel(binding: monitoring.binding, onExit: () {}),
        ),
      );

      await tester.pumpWidget(panel());
      await tester.pump();
      expect(service.reportRequests, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(panel());
      await tester.pump();

      expect(service.reportRequests, 1);
      final refresh = controller.ensureAgentUsageLoadedAndFresh();
      service.releaseReport();
      await refresh;
      await tester.pump();

      expect(service.reportCalls, 1);
      expect(service.scanCalls, 1);
    },
  );
}

void main() => registerAgentUsageCacheScenarios();
