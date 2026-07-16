import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/application/features/agents/contracts/agent_usage_gateway.dart';
import 'package:flutter_client/src/application/features/agents/controller/agent_usage_controller.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';

void main() {
  test('shares one in-flight scan and keeps bounded report history', () async {
    final gateway = _FakeUsageGateway();
    final gate = Completer<void>();
    gateway.scanGate = gate;
    final controller = _controller(gateway);
    addTearDown(controller.dispose);

    final first = controller.scan(showProgress: false);
    await Future<void>.delayed(Duration.zero);
    final second = controller.scan(showProgress: false);

    expect(identical(first, second), isTrue);
    expect(gateway.scanCalls, 1);
    gate.complete();
    await Future.wait([first, second]);
    expect(controller.reports, hasLength(1));
  });

  test('polling owners acquire and release independent leases', () {
    final controller = _controller(_FakeUsageGateway());
    addTearDown(controller.dispose);
    final panel = Object();
    final shell = Object();

    controller.acquirePollingOwner(panel);
    controller.acquirePollingOwner(shell);
    controller.releasePollingOwner(panel);

    expect(controller.pollingOwnerCount, 1);
    controller.releasePollingOwner(shell);
    expect(controller.pollingOwnerCount, 0);
  });

  test(
    'manual 1-365 day window is clamped and forwarded to the gateway',
    () async {
      final gateway = _FakeUsageGateway();
      final controller = _controller(gateway);
      addTearDown(controller.dispose);

      await controller.setHistoryDays(999);
      expect(controller.historyDays, 365);
      expect(gateway.lastHistoryDays, 365);

      await controller.setHistoryDays(0);
      expect(controller.historyDays, 1);
      expect(gateway.lastHistoryDays, 1);
    },
  );

  test(
    'window changes during a scan schedule one fresh bounded scan',
    () async {
      final gateway = _FakeUsageGateway();
      final gate = Completer<void>();
      gateway.scanGate = gate;
      final controller = _controller(gateway);
      addTearDown(controller.dispose);

      final initial = controller.scan(showProgress: false);
      await Future<void>.delayed(Duration.zero);
      final changed = controller.setHistoryDays(365);
      expect(gateway.scanCalls, 1);

      gate.complete();
      await Future.wait([initial, changed]);

      expect(gateway.scanCalls, 2);
      expect(gateway.lastHistoryDays, 365);
    },
  );
}

AgentUsageController _controller(_FakeUsageGateway gateway) {
  return AgentUsageController(
    gateway: gateway,
    selectedAgentId: () => 'codex',
    onStatus:
        ({
          required chinese,
          required english,
          required caption,
          errorCode = '',
        }) {},
  );
}

AgentUsageReport _report() {
  return AgentUsageReport.fromAgents(
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: const {},
        confidence: 'high',
      ),
    ],
  );
}

final class _FakeUsageGateway implements AgentUsageGateway {
  Completer<void>? scanGate;
  int scanCalls = 0;
  int lastHistoryDays = 0;
  AgentUsageReport report = _report();

  @override
  Future<List<AgentUsageReport>> reports({int limit = 10}) async => [report];

  @override
  Future<AgentUsageReport> scan({
    String agentId = '',
    bool forceRefresh = false,
    int historyDays = 30,
  }) async {
    scanCalls += 1;
    lastHistoryDays = historyDays;
    await scanGate?.future;
    return report;
  }
}
