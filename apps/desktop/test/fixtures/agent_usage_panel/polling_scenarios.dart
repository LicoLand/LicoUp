import 'package:flutter/material.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'usage_agent_service_fakes.dart';
import 'usage_panel_fixtures.dart';

void registerAgentUsagePollingScenarios() {
  testWidgets('agent usage panel polls local tokens without status churn', (
    tester,
  ) async {
    final service = UsageAgentService();
    final controller = ClientController(agentService: service)
      ..scannedTargets = testTargets(['codex'])
      ..agentUsageReport = snapshotOnlyReport(
        generatedAt: DateTime.now().toUtc().toIso8601String(),
        totalTokens: 140,
      )
      ..statusMessage = 'steady status'
      ..lastError = 'previous error';
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      usageTestApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 980,
          height: 620,
          child: AgentUsagePanel(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(service.reportCalls, 0);
    expect(service.scanCalls, 0);

    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();

    expect(service.scanCalls, 1);
    expect(controller.statusMessage, 'steady status');
    expect(controller.lastError, 'previous error');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));

    expect(service.scanCalls, 1);
  });
}

void main() => registerAgentUsagePollingScenarios();
