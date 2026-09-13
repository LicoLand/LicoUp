import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_usage_gateway.dart';
import 'package:licoup/src/application/features/agents/controller/agent_usage_controller.dart';
import 'package:licoup/src/application/features/agents/controller/agent_usage_daily_cache.dart';
import 'package:licoup/src/backend/features/agents/services/agent_usage_service.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

AgentUsageReport _report({String? parserRevision}) =>
    AgentUsageReport.fromJson({
      'schemaVersion': AgentUsageReport.currentSchemaVersion,
      'mode': AgentUsageReport.currentMode,
      'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
      'usageParserRevision':
          parserRevision ?? AgentUsageReport.currentUsageParserRevision,
      'modelRegistryRevision': 'registry-fixture-2',
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'window': {'days': 90},
      'summary': {'totalTokens': 120, 'agentCount': 1},
      'agents': [],
    });

void main() {
  test(
    'native revisions survive viewport projection and old parser data requires local extraction',
    () async {
      final old = _report(parserRevision: '');
      final sliced = projectViewport(old, 7)!;
      expect(sliced.usageParserRevision, '');
      expect(sliced.modelRegistryRevision, 'registry-fixture-2');
      final gateway = _Gateway();
      final controller = _controller(gateway);
      addTearDown(controller.dispose);
      controller.replaceReport(old);
      expect(controller.hasFreshScanCoverage, isFalse);
      await controller.ensureLoadedAndFresh();
      expect(gateway.calls, ['scan:false', 'read']);
      expect(controller.hasFreshScanCoverage, isTrue);
    },
  );

  test(
    'empty directory bootstraps once after cached statistics are visible without blocking them',
    () async {
      final gateway = _Gateway()
        ..registryEmpty = true
        ..refreshGate = Completer<void>();
      final controller = _controller(gateway);
      addTearDown(controller.dispose);
      controller.replaceReport(_report());
      await controller.ensureLoadedAndFresh();
      await Future<void>.delayed(Duration.zero);
      expect(controller.report, isNotNull);
      expect(controller.scanning, isFalse);
      expect(gateway.calls, ['read', 'models']);
      await controller.ensureLoadedAndFresh();
      expect(gateway.calls, ['read', 'models']);
      gateway.refreshGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(gateway.calls, ['read', 'models', 'scan:true']);
      await controller.ensureLoadedAndFresh();
      expect(gateway.calls, ['read', 'models', 'scan:true']);
    },
  );

  test(
    'existing directories never bootstrap network refresh and failed bootstrap waits for manual retry',
    () async {
      final ready = _Gateway();
      final existing = _controller(ready)..replaceReport(_report());
      addTearDown(existing.dispose);
      await existing.ensureLoadedAndFresh();
      await existing.ensureLoadedAndFresh();
      expect(ready.calls, ['read']);

      final absent = _Gateway()
        ..registryEmpty = true
        ..refreshFails = true;
      final bootstrap = _controller(absent)..replaceReport(_report());
      addTearDown(bootstrap.dispose);
      await bootstrap.ensureLoadedAndFresh();
      await Future<void>.delayed(Duration.zero);
      await bootstrap.ensureLoadedAndFresh();
      expect(absent.calls, ['read', 'models', 'scan:true']);
      await bootstrap.refreshModelDirectoryAndScan();
      expect(absent.calls, [
        'read',
        'models',
        'scan:true',
        'models',
        'scan:true',
      ]);
    },
  );

  test(
    'explicit refresh joins a running local scan then refreshes models before rescanning once',
    () async {
      final gateway = _Gateway()..firstScan = Completer<void>();
      final controller = _controller(gateway);
      addTearDown(controller.dispose);
      final automatic = controller.scan(
        forceRefresh: false,
        showProgress: false,
      );
      final manual = controller.refreshModelDirectoryAndScan();
      expect(
        identical(manual, controller.refreshModelDirectoryAndScan()),
        isTrue,
      );
      expect(
        identical(
          manual,
          controller.scan(forceRefresh: false, showProgress: false),
        ),
        isTrue,
      );
      expect(gateway.calls, ['scan:false']);
      gateway.firstScan!.complete();
      await Future.wait([automatic, manual]);
      expect(gateway.calls, ['scan:false', 'models', 'scan:true']);
      expect(controller.scanning, isFalse);
      expect(controller.report?.modelRegistryRevision, 'registry-fixture-2');
    },
  );

  test(
    'failed model refresh still scans with the local registry and reports its real limitation',
    () async {
      for (final throws in [false, true]) {
        final gateway = _Gateway()
          ..refreshFails = true
          ..refreshThrows = throws;
        final statuses = <String>[];
        final controller = _controller(gateway, statuses: statuses);
        addTearDown(controller.dispose);
        await controller.refreshModelDirectoryAndScan();
        expect(gateway.calls, ['models', 'scan:true']);
        expect(controller.report, isNotNull);
        expect(statuses.last, 'model_registry_refresh_unavailable');
        expect(controller.scanning, isFalse);
      }
    },
  );

  test(
    'late retained report cannot overwrite a completed model refresh scan',
    () async {
      AgentUsageReport revision(String registry, int tokens) =>
          _report().copyWith(
            modelRegistryRevision: registry,
            agents: [
              AgentUsageAgentSummary(
                agentId: 'codex',
                label: 'Codex',
                status: 'detected',
                confidence: 'high',
                history: {'totalTokens': tokens},
              ),
            ],
          );
      final old = revision('registry-R0', 120);
      final refreshed = revision('registry-R1', 240);
      final gate = Completer<List<AgentUsageReport>>();
      final gateway = _Gateway()
        ..reportsGate = gate
        ..scanResult = refreshed;
      final controller = _controller(gateway);
      addTearDown(controller.dispose);

      final initialLoad = controller.ensureLoadedAndFresh();
      expect(gateway.calls, ['reports']);
      await controller.refreshModelDirectoryAndScan();
      expect(controller.report!.modelRegistryRevision, 'registry-R1');
      expect(controller.report!.totalTokens, 240);
      expect(controller.reports.single.modelRegistryRevision, 'registry-R1');

      // R0 is otherwise fresh, so accepting it would also skip a corrective scan.
      expect(old.hasCurrentParserRevision && old.isFresh(), isTrue);
      gate.complete([old]);
      await initialLoad;
      expect(controller.report!.modelRegistryRevision, 'registry-R1');
      expect(controller.report!.totalTokens, 240);
      expect(controller.reports.single.modelRegistryRevision, 'registry-R1');
      expect(gateway.calls.where((call) => call.startsWith('scan:')), [
        'scan:true',
      ]);
      expect(controller.scanning, isFalse);
    },
  );

  test(
    'manual join promotes a silent bootstrap and reports its failure without duplicate work',
    () async {
      final gate = Completer<void>();
      final gateway = _Gateway()
        ..registryEmpty = true
        ..refreshFails = true
        ..refreshGate = gate;
      final statuses = <String>[];
      final controller = _controller(gateway, statuses: statuses)
        ..replaceReport(_report());
      addTearDown(controller.dispose);

      await controller.ensureLoadedAndFresh();
      await Future<void>.delayed(Duration.zero);
      expect(gateway.calls, ['read', 'models']);
      expect(controller.scanning, isFalse);
      expect(statuses, isEmpty);

      final manual = controller.refreshModelDirectoryAndScan();
      expect(controller.scanning, isTrue);
      expect(statuses, ['']);
      expect(
        identical(manual, controller.refreshModelDirectoryAndScan()),
        isTrue,
      );
      expect(gateway.calls, ['read', 'models']);

      gate.complete();
      await manual;
      expect(gateway.calls, ['read', 'models', 'scan:true']);
      expect(controller.report, isNotNull);
      expect(controller.scanning, isFalse);
      expect(statuses, ['', 'model_registry_refresh_unavailable']);
    },
  );

  test(
    'model registry refresh crosses the existing local command boundary with typed metadata',
    () async {
      final calls = <List<String>>[];
      final runner = AgentService(
        runCliExecutable: (_, args, _) async {
          calls.add(args);
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'status': 'refreshed',
              'revision': 'registry-fixture-2',
              'modelCount': 12,
              'providerCount': 3,
              'source': 'fixture',
              'fetchedAt': '2026-09-13T00:00:00Z',
            }),
            '',
          );
        },
      );
      final result = await const AgentUsageService().refreshModelRegistry(
        agentService: runner,
      );
      expect(calls, [
        ['model-registry', 'refresh'],
      ]);
      expect(result.ok, isTrue);
      expect(result.revision, 'registry-fixture-2');
      expect(result.modelCount, 12);
      expect(result.providerCount, 3);
    },
  );

  test(
    'canonical model IDs aggregate sources and variants without merging equal display names',
    () {
      final report = AgentUsageReport.fromAgents(
        generatedAt: '2026-09-13T00:00:00Z',
        agents: [
          for (final agentId in ['codex', 'cursor'])
            AgentUsageAgentSummary(
              agentId: agentId,
              label: agentId,
              status: 'detected',
              confidence: 'high',
              history: {
                'dailyUsage': [
                  {
                    'date': '2026-09-13',
                    'totalTokens': 120,
                    'modelTokenUsage': {
                      'provider/model-one': {
                        'displayName': 'Official Model',
                        'totalTokens': 100,
                        'variants': {
                          'Extra High Fast': {
                            'totalTokens': 40,
                            'requestCount': 2,
                          },
                        },
                        'unattributedVariantUsage': {'totalTokens': 60},
                      },
                      'provider/model-two': {
                        'displayName': 'Official Model',
                        'totalTokens': 20,
                      },
                    },
                  },
                ],
              },
            ),
        ],
      );
      final timeline = buildAgentUsageTimelineData(
        report,
        AgentUsageChartGrouping.model,
        {'codex', 'cursor'},
        anchor: DateTime(2026, 9, 13),
      );
      expect(timeline.seriesTotals, {
        'provider/model-one': 200,
        'provider/model-two': 40,
      });
      expect(timeline.groupTotal, 240);
      expect(timeline.series.map((series) => series.displayName), [
        'Official Model',
        'Official Model',
      ]);
      expect(timeline.displayNameFor('provider/model-one'), 'Official Model');
      final source = timeline.modelSources['provider/model-one']!.first;
      expect(source.usage.variants['Extra High Fast']!.totalTokens, 40);
      expect(source.usage.unattributedVariantUsage!.totalTokens, 60);
      expect(source.usage.totalTokens, 100);
      final unknown = AgentUsageModelUsage.fromJson('~vendor/custom_high', {
        'totalTokens': 1 << 33,
      });
      expect(unknown.canonicalId, '~vendor/custom_high');
      expect(unknown.displayName, '~vendor/custom_high');
      expect(unknown.totals.totalTokens, 1 << 33);
    },
  );
}

AgentUsageController _controller(_Gateway gateway, {List<String>? statuses}) =>
    AgentUsageController(
      gateway: gateway,
      selectedAgentId: () => 'codex',
      onStatus:
          ({
            required chinese,
            required english,
            required caption,
            errorCode = '',
          }) => statuses?.add(errorCode),
    );

final class _Gateway implements AgentUsageGateway {
  final calls = <String>[];
  Completer<void>? firstScan;
  Completer<void>? refreshGate;
  Completer<List<AgentUsageReport>>? reportsGate;
  AgentUsageReport? scanResult;
  bool registryEmpty = false;
  bool refreshFails = false;
  bool refreshThrows = false;

  @override
  Future<AgentModelRegistryResult> readModelRegistry() async {
    calls.add('read');
    return AgentModelRegistryResult(
      ok: true,
      status: registryEmpty ? 'empty' : 'ready',
      revision: registryEmpty ? '' : 'fixture',
    );
  }

  @override
  Future<AgentModelRegistryResult> refreshModelRegistry() async {
    calls.add('models');
    if (refreshThrows) {
      throw const FormatException('synthetic failure');
    }
    await refreshGate?.future;
    return AgentModelRegistryResult(
      ok: !refreshFails,
      status: refreshFails ? 'unavailable' : 'refreshed',
      revision: 'registry-fixture-2',
    );
  }

  @override
  Future<List<AgentUsageReport>> reports({int limit = 10}) async {
    final gate = reportsGate;
    if (gate != null) {
      calls.add('reports');
      return gate.future;
    }
    return [_report()];
  }

  @override
  Future<AgentUsageReport> scan({
    String agentId = '',
    bool forceRefresh = false,
    int historyDays = 90,
  }) async {
    calls.add('scan:$forceRefresh');
    if (calls.length == 1) {
      await firstScan?.future;
    }
    return scanResult ?? _report();
  }
}
