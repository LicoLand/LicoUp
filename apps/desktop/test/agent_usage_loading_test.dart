import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/monitoring/monitoring_feature_composition.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_summary_widgets.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_globe.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'fixtures/agent_usage_panel/usage_agent_service_fakes.dart';

void main() {
  testWidgets(
    'cold usage keeps the shared globe through cache, scan, and directory read',
    (tester) async {
      final service = _LoadingUsageService();
      final controller = ClientController(agentService: service);
      final monitoring = MonitoringFeatureComposition(controller);
      addTearDown(() async {
        await monitoring.close();
        controller.dispose();
      });
      await tester.pumpWidget(
        _app(AgentUsagePanel(binding: monitoring.binding), chinese: true),
      );
      expect(find.byType(ConversationParticleGlobe), findsOneWidget);
      expect(find.text('正在加载中'), findsOneWidget);
      expect(find.text('暂无用量报表'), findsNothing);

      service.reportGate.complete();
      await tester.pump();
      expect(find.byType(ConversationParticleGlobe), findsOneWidget);
      service.emptyScan = true;
      service.scanGate.complete();
      await tester.pump();
      expect(find.byType(ConversationParticleGlobe), findsOneWidget);
      expect(find.text('最新报表中没有智能体用量'), findsNothing);

      service.registryGate.complete();
      await tester.pump();
      expect(find.byType(ConversationParticleGlobe), findsNothing);
      expect(find.text('最新报表中没有智能体用量'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cached usage stays visible during initial refresh and directory read',
    (tester) async {
      final service = _LoadingUsageService()..cached = true;
      final controller = ClientController(agentService: service);
      final monitoring = MonitoringFeatureComposition(controller);
      addTearDown(() async {
        await monitoring.close();
        controller.dispose();
      });
      await tester.pumpWidget(
        _app(AgentUsagePanel(binding: monitoring.binding)),
      );
      expect(find.byType(AgentUsageLoadingState), findsOneWidget);
      service.reportGate.complete();
      await tester.pump();
      expect(controller.agentUsageController.loading, isTrue);
      expect(find.byType(AgentUsageLoadingState), findsNothing);
      expect(find.byType(AgentUsageCharts), findsOneWidget);
      service.scanGate.complete();
      await tester.pump();
      expect(controller.agentUsageController.loading, isTrue);
      expect(find.byType(AgentUsageCharts), findsOneWidget);
      service.registryGate.complete();
      await tester.pump();
      expect(controller.agentUsageController.loading, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed first scan ends the globe with a retry message, not empty data',
    (tester) async {
      final service = _LoadingUsageService()..failScan = true;
      final controller = ClientController(agentService: service);
      final monitoring = MonitoringFeatureComposition(controller);
      addTearDown(() async {
        await monitoring.close();
        controller.dispose();
      });
      await tester.pumpWidget(
        _app(AgentUsagePanel(binding: monitoring.binding), chinese: true),
      );
      service.reportGate.complete();
      service.scanGate.complete();
      service.registryGate.complete();
      await tester.pump();
      expect(find.byType(ConversationParticleGlobe), findsNothing);
      expect(find.text('用量加载失败，请刷新重试'), findsOneWidget);
      expect(find.text('暂无用量报表'), findsNothing);
      expect(find.byKey(const Key('agent-usage-refresh')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('loading fits a narrow reduced-motion pane at 200 percent text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 220);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(const AgentUsageLoadingState(), chinese: true, reducedMotion: true),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('正在加载中'), findsOneWidget);
    expect(find.byType(ConversationParticleGlobe), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an unavailable native source is represented once while real warnings remain',
    (tester) async {
      AgentUsageReport report(List<String> warnings) =>
          AgentUsageReport.fromAgents(
            generatedAt: DateTime.now().toUtc().toIso8601String(),
            agents: const [
              AgentUsageAgentSummary(
                agentId: 'antigravity',
                label: 'Antigravity',
                status: 'detected',
                history: {'source': 'native-usage-source-unavailable'},
                confidence: '',
              ),
            ],
            warnings: warnings,
          );
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: AgentUsageCharts(
              report: report(['native_usage_source_unavailable']),
              detectedAgentIds: const {'antigravity'},
              windowDays: 30,
              windowBusy: false,
              onWindowChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.text('Unrecognized usage warning'), findsNothing);
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: AgentUsageCharts(
              report: report([
                'native_usage_source_unavailable',
                'native_history_scan_failed',
                'native_usage_source_migration_incomplete',
                'native_usage_cache_schema_unsupported',
                'native_usage_source_read_failed',
              ]),
              detectedAgentIds: const {'antigravity'},
              windowDays: 30,
              windowBusy: false,
              onWindowChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.textContaining('Native history scan failed'), findsOneWidget);
      expect(
        find.textContaining('prior usage totals are preserved'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Usage cache version is unsupported'),
        findsOneWidget,
      );
      expect(find.textContaining('Unrecognized'), findsNothing);
      expect(
        find.textContaining('Unable to read Agent usage history'),
        findsOneWidget,
      );
    },
  );
}

Widget _app(Widget body, {bool chinese = false, bool reducedMotion = false}) =>
    MaterialApp(
      locale: Locale(chinese ? 'zh' : 'en'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildLicoTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reducedMotion,
          textScaler: TextScaler.linear(reducedMotion ? 2 : 1),
        ),
        child: child!,
      ),
      home: Scaffold(body: body),
    );

final class _LoadingUsageService extends UsageAgentService {
  final reportGate = Completer<void>();
  final scanGate = Completer<void>();
  final registryGate = Completer<void>();
  bool cached = false;
  bool emptyScan = false;
  bool failScan = false;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'report') {
      await reportGate.future;
      final response = await super.runCli(args);
      return cached ? response : {...response, 'reports': <Object>[]};
    }
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'scan') {
      await scanGate.future;
      if (failScan) {
        throw const FormatException('synthetic usage failure');
      }
      final response = await super.runCli(args);
      return emptyScan
          ? {
              ...response,
              'agents': <Object>[],
              'summary': {'agentCount': 0, 'totalTokens': 0},
            }
          : response;
    }
    if (args.length >= 2 && args[0] == 'model-registry' && args[1] == 'read') {
      await registryGate.future;
      return {'ok': true, 'status': 'ready', 'revision': 'synthetic-registry'};
    }
    return super.runCli(args);
  }
}
