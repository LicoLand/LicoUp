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

  test('scan always uses the fixed 90-day cache window', () async {
    final gateway = _FakeUsageGateway();
    final controller = _controller(gateway);
    addTearDown(controller.dispose);

    expect(controller.historyDays, defaultAgentUsageDisplayHistoryDays);
    await controller.scan(showProgress: false);

    expect(gateway.scanCalls, 1);
    expect(gateway.lastHistoryDays, defaultAgentUsageScanHistoryDays);
    expect(controller.report?.windowDays, defaultAgentUsageDisplayHistoryDays);
  });

  test('display window is clamped without scanning', () async {
    final gateway = _FakeUsageGateway();
    final controller = _controller(gateway);
    addTearDown(controller.dispose);

    await controller.setHistoryDays(999);
    expect(controller.historyDays, 90);
    expect(gateway.scanCalls, 0);

    await controller.setHistoryDays(0);
    expect(controller.historyDays, 1);
    expect(gateway.scanCalls, 0);
  });

  test('window changes during a scan never schedule another scan', () async {
    final gateway = _FakeUsageGateway(
      report: _reportWithDailyUsage(windowDays: 90),
    );
    final gate = Completer<void>();
    gateway.scanGate = gate;
    final controller = _controller(gateway);
    addTearDown(controller.dispose);

    final initial = controller.scan(showProgress: false);
    await Future<void>.delayed(Duration.zero);
    await controller.setHistoryDays(7);
    expect(gateway.scanCalls, 1);
    expect(controller.historyDays, 7);

    gate.complete();
    await initial;

    expect(gateway.scanCalls, 1);
    expect(gateway.lastHistoryDays, defaultAgentUsageScanHistoryDays);
    expect(controller.report?.windowDays, 7);
  });

  test(
    '7/30/90 display switches slice a fresh 90-day cache without scanning',
    () async {
      final gateway = _FakeUsageGateway();
      final controller = _controller(gateway);
      addTearDown(controller.dispose);

      final cached = _reportWithDailyUsage(windowDays: 90);
      controller.replaceReports([cached]);

      await controller.setHistoryDays(7);
      expect(gateway.scanCalls, 0);
      expect(controller.historyDays, 7);
      expect(controller.report?.windowDays, 7);
      expect(controller.report?.totalTokens, 700);
      expect(controller.scanning, isFalse);

      await controller.setHistoryDays(30);
      expect(gateway.scanCalls, 0);
      expect(controller.report?.windowDays, 30);
      expect(controller.report?.totalTokens, 3000);

      await controller.setHistoryDays(90);
      expect(gateway.scanCalls, 0);
      expect(controller.report?.windowDays, 90);
      expect(controller.report?.totalTokens, 9000);
    },
  );

  test(
    'force refresh scans 90 days then presents the current display slice',
    () async {
      final gateway = _FakeUsageGateway(
        report: _reportWithDailyUsage(windowDays: 90),
      );
      final controller = _controller(gateway);
      addTearDown(controller.dispose);

      await controller.setHistoryDays(7);
      await controller.scan(forceRefresh: true, showProgress: false);

      expect(gateway.scanCalls, 1);
      expect(gateway.lastForceRefresh, isTrue);
      expect(gateway.lastHistoryDays, defaultAgentUsageScanHistoryDays);
      expect(controller.historyDays, 7);
      expect(controller.report?.windowDays, 7);
      expect(controller.report?.totalTokens, 700);
      expect(controller.scanCache?.windowDays, 90);
    },
  );

  test(
    'stale full cache refreshes today only on ensureLoaded; chip switch never scans',
    () async {
      final gateway = _FakeUsageGateway(
        report: _reportWithDailyUsage(windowDays: 90),
      );
      final controller = _controller(gateway);
      addTearDown(controller.dispose);

      final stale = _reportWithDailyUsage(
        windowDays: 90,
        generatedAt: DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 2))
            .toIso8601String(),
      );
      controller.replaceReports([stale]);

      await controller.setHistoryDays(7);
      expect(gateway.scanCalls, 0);
      expect(controller.report?.windowDays, 7);

      await controller.ensureLoadedAndFresh();
      expect(gateway.scanCalls, 1);
      expect(gateway.lastHistoryDays, 1);
      expect(controller.hasFreshScanCoverage, isTrue);
      expect(controller.report?.windowDays, 7);

      await controller.setHistoryDays(30);
      expect(gateway.scanCalls, 1);
      expect(controller.report?.windowDays, 30);
    },
  );

  test(
    'loadReports merges all retained reports instead of picking stale 90-day only',
    () async {
      final gateway = _FakeUsageGateway();
      final staleAnchor = DateTime.now().toLocal().subtract(
        const Duration(days: 60),
      );
      gateway.reportsResult = [
        _reportWithDailyUsage(
          windowDays: 30,
          generatedAt: DateTime.now().toUtc().toIso8601String(),
          agents: {'cursor': ('Cursor', 100), 'codex': ('Codex', 100)},
        ),
        _reportWithDailyUsage(
          windowDays: 90,
          generatedAt: staleAnchor.toUtc().toIso8601String(),
          anchor: staleAnchor,
          agentId: 'antigravity',
          agentLabel: 'Antigravity',
        ),
      ];
      final controller = _controller(gateway);
      addTearDown(controller.dispose);

      await controller.loadReports(showProgress: false);

      expect(gateway.reportCalls, 1);
      expect(controller.report?.totalTokens, 6000);
      expect(controller.report?.agent('cursor')?.totalTokens, 3000);
      expect(controller.report?.agent('codex')?.totalTokens, 3000);
      expect(controller.report?.agent('antigravity')?.totalTokens, 0);
    },
  );

  test(
    'empty cache ensureLoaded triggers 90-day scan and projects viewport',
    () async {
      final gateway = _FakeUsageGateway(
        report: _reportWithDailyUsage(windowDays: 90),
      );
      gateway.reportsResult = const [];
      final controller = _controller(gateway);
      addTearDown(controller.dispose);

      expect(controller.report, isNull);
      expect(controller.dailyCache.isEmpty, isTrue);

      await controller.ensureLoadedAndFresh();

      expect(gateway.reportCalls, 1);
      expect(gateway.scanCalls, 1);
      expect(gateway.lastHistoryDays, defaultAgentUsageScanHistoryDays);
      expect(controller.report, isNotNull);
      expect(controller.report?.agents, isNotEmpty);
      expect(
        controller.report?.windowDays,
        defaultAgentUsageDisplayHistoryDays,
      );
      expect(controller.report?.totalTokens, 3000);
    },
  );

  test('empty retained reports do not wipe an in-memory scan cache', () async {
    final gateway = _FakeUsageGateway(
      report: _reportWithDailyUsage(windowDays: 90),
    );
    gateway.reportsResult = const [];
    final controller = _controller(gateway);
    addTearDown(controller.dispose);

    await controller.scan(showProgress: false);
    expect(controller.report?.totalTokens, 3000);

    gateway.reportsResult = const [];
    await controller.loadReports(showProgress: false);

    expect(gateway.reportCalls, 1);
    expect(controller.report, isNotNull);
    expect(controller.report?.totalTokens, 3000);
    expect(controller.dailyCache.isEmpty, isFalse);
  });

  test(
    'partial retained coverage backfills with a 90-day scan on ensureLoaded',
    () async {
      final gateway = _FakeUsageGateway(
        report: _reportWithDailyUsage(windowDays: 90),
      );
      gateway.reportsResult = [
        _reportWithDailyUsage(
          windowDays: 30,
          generatedAt: DateTime.now().toUtc().toIso8601String(),
        ),
      ];
      final controller = _controller(gateway);
      addTearDown(controller.dispose);

      await controller.ensureLoadedAndFresh();

      expect(gateway.reportCalls, 1);
      expect(gateway.scanCalls, 1);
      expect(gateway.lastHistoryDays, defaultAgentUsageScanHistoryDays);
      expect(controller.report, isNotNull);
      expect(controller.report?.totalTokens, 3000);
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

AgentUsageReport _reportWithDailyUsage({
  required int windowDays,
  String? generatedAt,
  DateTime? anchor,
  String agentId = 'codex',
  String agentLabel = 'Codex',
  Map<String, (String, int)>? agents,
}) {
  final base = (anchor ?? DateTime.now()).toLocal();
  final today = DateTime(base.year, base.month, base.day);
  final resolvedAgents = agents ?? {agentId: (agentLabel, 100)};
  final agentSummaries = [
    for (final entry in resolvedAgents.entries)
      AgentUsageAgentSummary(
        agentId: entry.key,
        label: entry.value.$1,
        status: 'detected',
        history: {
          'totalTokens': windowDays * entry.value.$2,
          'promptTokens': windowDays * (entry.value.$2 * 8 ~/ 10),
          'cachedInputTokens': windowDays * (entry.value.$2 ~/ 10),
          'completionTokens': windowDays * (entry.value.$2 ~/ 5),
          'dailyUsage': [
            for (var offset = windowDays - 1; offset >= 0; offset -= 1)
              {
                'date': _dateKey(
                  DateTime(today.year, today.month, today.day - offset),
                ),
                'totalTokens': entry.value.$2,
                'promptTokens': entry.value.$2 * 8 ~/ 10,
                'cachedInputTokens': entry.value.$2 ~/ 10,
                'completionTokens': entry.value.$2 ~/ 5,
                'modelUsage': {'${entry.key}-model': entry.value.$2},
              },
          ],
          'modelUsage': {'${entry.key}-model': windowDays * entry.value.$2},
        },
        confidence: 'high',
      ),
  ];
  final totalTokens =
      windowDays *
      resolvedAgents.values.fold<int>(0, (sum, agent) => sum + agent.$2);
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: generatedAt ?? DateTime.now().toUtc().toIso8601String(),
    summary: {
      'agentCount': resolvedAgents.length,
      'sessionCount': resolvedAgents.length,
      'messageCount': windowDays * resolvedAgents.length,
      'totalTokens': totalTokens,
      'confidence': 'high',
    },
    agents: agentSummaries,
    warnings: const [],
    window: {'days': windowDays},
  );
}

String _dateKey(DateTime value) {
  final day = DateTime(value.year, value.month, value.day);
  return '${day.year}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}

final class _FakeUsageGateway implements AgentUsageGateway {
  _FakeUsageGateway({AgentUsageReport? report})
    : report = report ?? _reportWithDailyUsage(windowDays: 90);

  Completer<void>? scanGate;
  int scanCalls = 0;
  int reportCalls = 0;
  int lastHistoryDays = 0;
  bool? lastForceRefresh;
  AgentUsageReport report;
  List<AgentUsageReport>? reportsResult;

  @override
  Future<List<AgentUsageReport>> reports({int limit = 10}) async {
    reportCalls += 1;
    return reportsResult ?? [report];
  }

  @override
  Future<AgentUsageReport> scan({
    String agentId = '',
    bool forceRefresh = false,
    int historyDays = 90,
  }) async {
    scanCalls += 1;
    lastHistoryDays = historyDays;
    lastForceRefresh = forceRefresh;
    await scanGate?.future;
    return report;
  }
}
