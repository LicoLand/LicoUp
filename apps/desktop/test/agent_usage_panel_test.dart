import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('agent usage panel formats large numbers with compact units', (
    tester,
  ) async {
    final service = _UsageAgentService();
    final controller = ClientController(agentService: service);
    controller.scannedTargets = _testTargets([
      'claude-code',
      'codex',
      'opencode',
    ]);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            return SizedBox(
              width: 980,
              height: 620,
              child: AgentUsagePanel(controller: controller),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('231.9M'), findsAtLeastNWidgets(1));
    expect(service.reportCalls, 1);
    expect(service.scanCalls, 0);
    expect(find.text('7.9M'), findsAtLeastNWidgets(1));
    expect(find.text('670.7K'), findsAtLeastNWidgets(1));
    expect(find.text('Token Usage'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('240.4M'), findsOneWidget);
    expect(find.text('Report Totals'), findsNothing);
    expect(find.text('Metered Traffic'), findsNothing);
    expect(find.text('Estimated History'), findsNothing);
    expect(find.text('Usage Over Time'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Usage Over Time')).dx, lessThan(40));
    expect(find.text('By Agent'), findsOneWidget);
    expect(find.text('By Model'), findsOneWidget);

    await tester.tap(find.text('By Model'));
    await tester.pumpAndSettle();

    const tokenShareKey = ValueKey('agent-usage-token-share');
    final tokenShare = find.byKey(tokenShareKey);
    final claudeModel = find.descendant(
      of: tokenShare,
      matching: find.text('Claude Sonnet 4'),
    );
    final gptModel = find.descendant(
      of: tokenShare,
      matching: find.text('GPT 5.4'),
    );
    final deepseekModel = find.descendant(
      of: tokenShare,
      matching: find.text('DeepSeek V4 Pro'),
    );

    expect(claudeModel, findsOneWidget);
    expect(gptModel, findsOneWidget);
    expect(deepseekModel, findsOneWidget);
    expect(
      tester.getTopLeft(claudeModel).dy,
      lessThan(tester.getTopLeft(gptModel).dy),
    );
    expect(
      tester.getTopLeft(gptModel).dy,
      lessThan(tester.getTopLeft(deepseekModel).dy),
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('Claude Code - CLI')),
      findsNothing,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('ChatGPT - Desktop')),
      findsNothing,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('OpenCode - CLI')),
      findsNothing,
    );
    expect(find.textContaining('{"id"'), findsNothing);

    await tester.tap(find.text('By Agent'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: tokenShare, matching: find.text('Claude Code - CLI')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('ChatGPT - Desktop')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('OpenCode - CLI')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('GPT 5.4')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
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

    expect(service.reportCalls, 1);
    expect(service.scanCalls, 0);
  });

  testWidgets('agent usage timeline shows thirty day daily usage buckets', (
    tester,
  ) async {
    final service = _DeltaUsageAgentService();
    final controller = ClientController(agentService: service);
    controller.scannedTargets = _testTargets(['claude-code', 'codex']);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            return SizedBox(
              width: 980,
              height: 620,
              child: AgentUsagePanel(controller: controller),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Usage Over Time'), findsOneWidget);
    expect(find.text('Last 30 days'), findsOneWidget);
    expect(find.text('ChatGPT - Desktop'), findsAtLeastNWidgets(1));
    expect(find.text('40'), findsAtLeastNWidgets(1));
    expect(service.reportCalls, 1);
    expect(service.scanCalls, 0);
  });

  testWidgets('snapshot-only reports do not masquerade as daily usage deltas', (
    tester,
  ) async {
    final controller = ClientController(agentService: _UsageAgentService());
    controller.scannedTargets = _testTargets(['codex']);
    final now = DateTime.now().toUtc();
    final latest = _snapshotOnlyReport(
      generatedAt: now.toIso8601String(),
      totalTokens: 140,
    );
    controller
      ..agentUsageReport = latest
      ..agentUsageReports = [
        latest,
        _snapshotOnlyReport(
          generatedAt: now.subtract(const Duration(days: 1)).toIso8601String(),
          totalTokens: 100,
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 980,
          height: 620,
          child: AgentUsagePanel(controller: controller, autoLoad: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Daily usage breakdown unavailable'), findsOneWidget);
    expect(find.text('40'), findsNothing);

    await tester.tap(find.text('By Model'));
    await tester.pumpAndSettle();

    expect(find.text('Daily usage breakdown unavailable'), findsOneWidget);
    // Snapshot-only reports carry model-usage data from the report summary;
    // the token share section shows the model breakdown when data is present.
    expect(find.text('No model usage in the latest report'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('agent-usage-token-share')),
        matching: find.text('GPT 5.4'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('agent-usage-token-share')),
        matching: find.text('ChatGPT - Desktop'),
      ),
      findsNothing,
    );
  });

  testWidgets('model share keeps a stable top ten and full model denominator', (
    tester,
  ) async {
    final controller = ClientController(agentService: _UsageAgentService());
    controller
      ..scannedTargets = _testTargets(['codex'])
      ..agentUsageReport = _equalModelUsageReport();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 980,
          height: 620,
          child: AgentUsagePanel(controller: controller, autoLoad: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('By Model'));
    await tester.pumpAndSettle();

    final tokenShare = find.byKey(const ValueKey('agent-usage-token-share'));
    final firstModel = find.descendant(
      of: tokenShare,
      matching: find.text('Model A'),
    );
    final secondModel = find.descendant(
      of: tokenShare,
      matching: find.text('Model B'),
    );

    expect(firstModel, findsOneWidget);
    expect(secondModel, findsOneWidget);
    expect(
      tester.getTopLeft(firstModel).dy,
      lessThan(tester.getTopLeft(secondModel).dy),
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('Model J')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('Model K')),
      findsNothing,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('9%')),
      findsNWidgets(10),
    );
  });

  testWidgets(
    'usage names models formally and excludes the generic VS Code host',
    (tester) async {
      final controller = ClientController(agentService: _UsageAgentService())
        ..scannedTargets = _testTargets([
          'code',
          'codex',
          'cursor',
          'kimi-code',
        ])
        ..agentUsageReport = _formalNamingUsageReport();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: SizedBox(
            width: 980,
            height: 720,
            child: AgentUsagePanel(controller: controller, autoLoad: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      const tokenShareKey = ValueKey('agent-usage-token-share');
      final tokenShare = find.byKey(tokenShareKey);
      expect(
        find.descendant(
          of: tokenShare,
          matching: find.text('ChatGPT - Desktop'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tokenShare, matching: find.text('Cursor - IDE')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tokenShare, matching: find.text('Kimi Code - CLI')),
        findsOneWidget,
      );
      expect(find.text('VS Code'), findsNothing);

      await tester.tap(find.text('By Model'));
      await tester.pumpAndSettle();

      for (final label in const [
        'GPT 5.5',
        'GPT 5.6 Sol',
        'Claude Opus 4.6',
        'DeepSeek V4 Flash',
        'DeepSeek V4 Pro',
        'Others',
      ]) {
        expect(
          find.descendant(of: tokenShare, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(find.text('Codex CLI'), findsNothing);
      expect(find.text('Fake Vscode Model'), findsNothing);
      expect(
        find.descendant(of: tokenShare, matching: find.text('550')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'usage chart tooltip follows the active agent or model grouping',
    (tester) async {
      final controller = ClientController(agentService: _UsageAgentService())
        ..scannedTargets = _testTargets(['codex', 'cursor', 'kimi-code'])
        ..agentUsageReport = _formalNamingUsageReport();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: SizedBox(
            width: 980,
            height: 720,
            child: AgentUsagePanel(controller: controller, autoLoad: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final chart = find.byKey(const ValueKey('usage-wave-chart-interaction'));
      final chartRect = tester.getRect(chart);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: chartRect.centerLeft);
      await mouse.moveTo(Offset(chartRect.right - 12, chartRect.top + 60));
      await tester.pumpAndSettle();

      final tooltip = find.byKey(const ValueKey('usage-wave-tooltip'));
      expect(tooltip, findsOneWidget);
      expect(
        find.descendant(of: tooltip, matching: find.text('ChatGPT - Desktop')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tooltip, matching: find.text('Cursor - IDE')),
        findsNothing,
      );
      expect(
        find.descendant(of: tooltip, matching: find.text('Kimi Code - CLI')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tooltip, matching: find.text(_dayKeyForNow())),
        findsOneWidget,
      );

      await tester.tap(find.text('By Model'));
      await tester.pumpAndSettle();
      await mouse.moveTo(Offset(chartRect.right - 24, chartRect.top + 70));
      await mouse.moveTo(Offset(chartRect.right - 12, chartRect.top + 60));
      await tester.pumpAndSettle();

      final modelTooltip = find.byKey(const ValueKey('usage-wave-tooltip'));
      expect(modelTooltip, findsOneWidget);
      expect(
        find.descendant(of: modelTooltip, matching: find.text('GPT 5.5')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: modelTooltip,
          matching: find.text('DeepSeek V4 Flash'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: modelTooltip, matching: find.text('Others')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: modelTooltip, matching: find.text('Cursor Auto')),
        findsNothing,
      );

      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usage-wave-tooltip')), findsNothing);
    },
  );

  testWidgets(
    'usage share shows compact bars and complete API price estimates',
    (tester) async {
      final controller = ClientController(agentService: _UsageAgentService())
        ..scannedTargets = _testTargets(['codex', 'cursor'])
        ..agentUsageReport = _pricedModelUsageReport();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: SizedBox(
            width: 1200,
            height: 720,
            child: AgentUsagePanel(controller: controller, autoLoad: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Estimated API Price'), findsOneWidget);
      // Price may appear in both total row and agent detail row.
      expect(find.text(r'$7.10'), findsAtLeastNWidgets(1));
      expect(find.text(r'$0.0002'), findsOneWidget);
      expect(find.text('Unavailable'), findsNothing);
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('usage-progress-ChatGPT - Desktop')),
            )
            .width,
        lessThanOrEqualTo(460),
      );

      await tester.tap(find.text('By Model'));
      await tester.pumpAndSettle();

      expect(find.text(r'$7.10'), findsAtLeastNWidgets(1));
      expect(find.text(r'$0.0002'), findsOneWidget);
      expect(find.text('Unavailable'), findsNothing);
      expect(find.text(r'$0.00'), findsNothing);
    },
  );

  testWidgets(
    'usage share bars scale to total share for agent and model rows',
    (tester) async {
      final controller = ClientController(agentService: _UsageAgentService())
        ..scannedTargets = _testTargets(['codex', 'claude-code'])
        ..agentUsageReport = _shareFractionUsageReport();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: SizedBox(
            width: 1200,
            height: 720,
            child: AgentUsagePanel(controller: controller, autoLoad: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_progressFillFactor(tester, 'Total'), closeTo(1.0, 0.01));
      expect(
        _progressFillFactor(tester, 'ChatGPT - Desktop'),
        closeTo(0.55, 0.01),
      );
      expect(
        _progressFillFactor(tester, 'Claude Code - CLI'),
        closeTo(0.45, 0.01),
      );
      expect(find.text('55%'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);

      await tester.tap(find.text('By Model'));
      await tester.pumpAndSettle();

      expect(_progressFillFactor(tester, 'Total'), closeTo(1.0, 0.01));
      expect(_progressFillFactor(tester, 'GPT 5.5'), closeTo(0.55, 0.01));
      expect(
        _progressFillFactor(tester, 'Claude Sonnet 4'),
        closeTo(0.45, 0.01),
      );
      expect(find.text('55%'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);
    },
  );

  testWidgets('estimated token records never masquerade as API billing', (
    tester,
  ) async {
    final controller = ClientController(agentService: _UsageAgentService())
      ..scannedTargets = _testTargets(['codex', 'cursor'])
      ..agentUsageReport = _pricedModelUsageReport(estimated: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 1200,
          height: 720,
          child: AgentUsagePanel(controller: controller, autoLoad: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(r'$7.10'), findsNothing);
    expect(find.text('Unavailable'), findsWidgets);
  });

  testWidgets(
    'agent usage panel polls token and traffic without status churn',
    (tester) async {
      final service = _UsageAgentService();
      final controller = ClientController(agentService: service)
        ..scannedTargets = _testTargets(['codex'])
        ..agentUsageReport = _snapshotOnlyReport(
          generatedAt: DateTime.now().toUtc().toIso8601String(),
          totalTokens: 140,
        )
        ..statusMessage = 'steady status'
        ..lastError = 'previous error';
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
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
    },
  );

  testWidgets('agent usage panel refreshes stale retained data once', (
    tester,
  ) async {
    final service = _UsageAgentService(
      reportGeneratedAt: DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 2))
          .toIso8601String(),
    );
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
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

    expect(service.reportCalls, 1);
    expect(service.scanCalls, 1);
  });

  testWidgets(
    'stale retained refresh survives a fast panel unload and re-entry',
    (tester) async {
      final service = _DelayedStaleUsageAgentService();
      final controller = ClientController(agentService: service);
      addTearDown(controller.dispose);

      Widget panel() => MaterialApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 980,
          height: 620,
          child: AgentUsagePanel(controller: controller),
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

List<TargetCandidate> _testTargets(List<String> agentIds) {
  return [
    for (final agentId in agentIds)
      TargetCandidate(
        target: agentId,
        label: switch (agentId) {
          'claude-code' => 'Claude Code',
          'codex' => 'Codex',
          'opencode' => 'OpenCode',
          _ => agentId,
        },
        kind: 'agent',
        status: 'detected',
        configured: true,
        confidence: 1,
        adapterStatus: 'available',
      ),
  ];
}

AgentUsageReport _snapshotOnlyReport({
  required String generatedAt,
  required int totalTokens,
}) {
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: generatedAt,
    summary: {
      'agentCount': 1,
      'totalTokens': totalTokens,
      'meteredTotalBytes': 0,
      'estimatedHistoricalBytes': 0,
      'attribution': '',
      'confidence': 'high',
    },
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: {
          'totalTokens': totalTokens,
          'modelUsage': {
            'gpt-5.4': {'totalTokens': totalTokens},
          },
        },
        traffic: const {},
        allowances: const [],
        confidence: 'high',
      ),
    ],
    warnings: const [],
  );
}

AgentUsageReport _equalModelUsageReport() {
  final now = DateTime.now();
  final date =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final modelUsage = {
    for (var index = 0; index < 11; index += 1)
      'model-${String.fromCharCode('a'.codeUnitAt(0) + index)}': 100,
  };
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: now.toUtc().toIso8601String(),
    summary: const {
      'agentCount': 1,
      'totalTokens': 1100,
      'meteredTotalBytes': 0,
      'estimatedHistoricalBytes': 0,
      'attribution': '',
      'confidence': 'high',
    },
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: {
          'totalTokens': 1100,
          'dailyUsage': [
            {'date': date, 'totalTokens': 1100, 'modelUsage': modelUsage},
          ],
          'modelUsage': modelUsage,
        },
        traffic: const {},
        allowances: const [],
        confidence: 'high',
      ),
    ],
    warnings: const [],
  );
}

AgentUsageReport _formalNamingUsageReport() {
  final date = _dayKeyForNow();
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    summary: const {
      'agentCount': 4,
      'totalTokens': 2799,
      'meteredTotalBytes': 0,
      'estimatedHistoricalBytes': 0,
      'attribution': '',
      'confidence': 'high',
    },
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: {
          'totalTokens': 1600,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 1600,
              'modelUsage': [
                {'model': 'openai/gpt-5.5', 'totalTokens': 500},
                {'model': 'GPT_5.5', 'totalTokens': 50},
                {'model': 'gpt-5.6-sol', 'totalTokens': 400},
                {'model': 'claude-opus-4.6', 'totalTokens': 300},
                {'model': 'deepseek-v4-flash', 'totalTokens': 200},
                {'model': 'deepseek_v4_pro', 'totalTokens': 100},
                {'model': 'Others', 'totalTokens': 50},
              ],
            },
          ],
        },
        traffic: const {},
        allowances: const [],
        confidence: 'high',
      ),
      AgentUsageAgentSummary(
        agentId: 'cursor',
        label: 'Cursor',
        status: 'detected',
        history: {
          'totalTokens': 75,
          'dailyUsage': [
            {
              'date': _dayKeyForOffset(-1),
              'totalTokens': 75,
              'modelUsage': {'cursor-auto': 75},
            },
          ],
        },
        traffic: const {},
        allowances: const [],
        confidence: 'high',
      ),
      AgentUsageAgentSummary(
        agentId: 'kimi-code',
        label: 'Kimi Code',
        status: 'detected',
        history: {
          'totalTokens': 125,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 125,
              'modelUsage': {'kimi-k2.5': 125},
            },
          ],
        },
        traffic: const {},
        allowances: const [],
        confidence: 'high',
      ),
      AgentUsageAgentSummary(
        agentId: 'code',
        label: 'VS Code',
        status: 'detected',
        history: {
          'totalTokens': 999,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 999,
              'modelUsage': {'fake-vscode-model': 999},
            },
          ],
        },
        traffic: const {},
        allowances: const [],
        confidence: 'low',
      ),
    ],
    warnings: const [],
  );
}

AgentUsageReport _pricedModelUsageReport({bool estimated = false}) {
  final date = _dayKeyForNow();
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    summary: const {
      'agentCount': 2,
      'totalTokens': 1100100,
      'meteredTotalBytes': 0,
      'estimatedHistoricalBytes': 0,
      'attribution': '',
      'confidence': 'high',
    },
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: {
          'promptTokens': 1000000,
          'cachedInputTokens': 200000,
          'completionTokens': 100000,
          'totalTokens': 1100000,
          'dailyUsage': [
            {
              'date': date,
              'promptTokens': 1000000,
              'cachedInputTokens': 200000,
              'completionTokens': 100000,
              'totalTokens': 1100000,
              'estimatedRecords': estimated ? 1 : 0,
              'modelUsage': {'gpt-5.5': 1100000},
              'modelTokenUsage': {
                'gpt-5.5': {
                  'promptTokens': 1000000,
                  'cachedInputTokens': 200000,
                  'completionTokens': 100000,
                  'totalTokens': 1100000,
                },
              },
            },
          ],
        },
        traffic: const {},
        allowances: const [],
        confidence: 'high',
      ),
      AgentUsageAgentSummary(
        agentId: 'cursor',
        label: 'Cursor',
        status: 'detected',
        history: {
          'promptTokens': 80,
          'completionTokens': 20,
          'totalTokens': 100,
          'dailyUsage': [
            {
              'date': date,
              'promptTokens': 80,
              'completionTokens': 20,
              'totalTokens': 100,
              'modelUsage': {'cursor-auto': 100},
              'modelTokenUsage': {
                'cursor-auto': {
                  'promptTokens': 80,
                  'completionTokens': 20,
                  'totalTokens': 100,
                },
              },
            },
          ],
        },
        traffic: const {},
        allowances: const [],
        confidence: 'high',
      ),
    ],
    warnings: const [],
  );
}

AgentUsageReport _shareFractionUsageReport() {
  final date = _dayKeyForNow();
  return AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    summary: const {
      'agentCount': 2,
      'totalTokens': 1000,
      'meteredTotalBytes': 0,
      'estimatedHistoricalBytes': 0,
      'attribution': '',
      'confidence': 'high',
    },
    agents: [
      AgentUsageAgentSummary(
        agentId: 'codex',
        label: 'Codex',
        status: 'detected',
        history: {
          'totalTokens': 550,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 550,
              'modelUsage': {'gpt-5.5': 550},
              'modelTokenUsage': {
                'gpt-5.5': {'totalTokens': 550},
              },
            },
          ],
        },
        traffic: const {},
        allowances: const [],
        confidence: 'high',
      ),
      AgentUsageAgentSummary(
        agentId: 'claude-code',
        label: 'Claude Code',
        status: 'detected',
        history: {
          'totalTokens': 450,
          'dailyUsage': [
            {
              'date': date,
              'totalTokens': 450,
              'modelUsage': {'claude-sonnet-4': 450},
              'modelTokenUsage': {
                'claude-sonnet-4': {'totalTokens': 450},
              },
            },
          ],
        },
        traffic: const {},
        allowances: const [],
        confidence: 'high',
      ),
    ],
    warnings: const [],
  );
}

double _progressFillFactor(WidgetTester tester, String label) {
  final progress = find.byKey(ValueKey('usage-progress-$label'));
  final track = find.descendant(
    of: progress,
    matching: find.byKey(const ValueKey('usage-progress-track')),
  );
  final fill = find.descendant(
    of: progress,
    matching: find.byKey(const ValueKey('usage-progress-fill')),
  );
  final trackWidth = tester.getSize(track).width;
  expect(trackWidth, greaterThan(0));
  return tester.getSize(fill).width / trackWidth;
}

String _dayKeyForNow() {
  return _dayKeyForOffset(0);
}

String _dayKeyForOffset(int days) {
  final now = DateTime.now().add(Duration(days: days));
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

class _UsageAgentService extends AgentService {
  _UsageAgentService({String? reportGeneratedAt})
    : reportGeneratedAt =
          reportGeneratedAt ?? DateTime.now().toUtc().toIso8601String(),
      super(runCliExecutable: null);

  final String reportGeneratedAt;
  int reportCalls = 0;
  int scanCalls = 0;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'targets' && args[1] == 'scan') {
      return _targets(['claude-code', 'codex', 'opencode']);
    }
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'report') {
      reportCalls += 1;
      return jsonDecode(
            jsonEncode({
              'ok': true,
              'schemaVersion': 2,
              'reports': [
                {
                  'schemaVersion': 2,
                  'generatedAt': reportGeneratedAt,
                  'summary': {
                    'agentCount': 3,
                    'totalTokens': 240448446,
                    'meteredTotalBytes': 0,
                    'estimatedHistoricalBytes': 961793784,
                    'attribution': '',
                    'confidence': '',
                  },
                  'agents': [
                    {
                      'agentId': 'claude-code',
                      'label': 'Claude Code',
                      'status': 'detected',
                      'history': {
                        'totalTokens': 231917287,
                        'dailyUsage': [
                          {
                            'date': _dayKey(),
                            'totalTokens': 231917287,
                            'modelUsage': {'claude-sonnet-4': 231917287},
                          },
                        ],
                        'modelUsage': [
                          {
                            'model': 'claude-sonnet-4',
                            'totalTokens': 231917287,
                          },
                        ],
                      },
                      'traffic': {'estimatedHistoricalBytes': 927669148},
                    },
                    {
                      'agentId': 'codex',
                      'label': 'Codex',
                      'status': 'detected',
                      'history': {
                        'totalTokens': 7860433,
                        'dailyUsage': [
                          {
                            'date': _dayKey(),
                            'totalTokens': 7860433,
                            'modelUsage': {'gpt-5.4': 7860433},
                          },
                        ],
                        'modelUsage': {
                          'gpt-5.4': {'totalTokens': 7860433},
                        },
                      },
                      'traffic': {'estimatedHistoricalBytes': 31441732},
                    },
                    {
                      'agentId': 'opencode',
                      'label': 'OpenCode',
                      'status': 'detected',
                      'history': {
                        'totalTokens': 670726,
                        'dailyUsage': [
                          {
                            'date': _dayKey(),
                            'totalTokens': 670726,
                            'modelUsage': {'deepseek-v4-pro': 670726},
                          },
                        ],
                      },
                      'traffic': {'estimatedHistoricalBytes': 2682904},
                    },
                  ],
                },
              ],
            }),
          )
          as Map<String, dynamic>;
    }
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'scan') {
      scanCalls += 1;
      final agentId = _argValue(args, '--agent');
      final tokens = switch (agentId) {
        'claude-code' => 231917287,
        'codex' => 7860433,
        'opencode' => 670726,
        _ => 0,
      };
      final label = switch (agentId) {
        'claude-code' => 'Claude Code',
        'codex' => 'Codex',
        'opencode' => 'OpenCode',
        _ => agentId,
      };
      return jsonDecode(
            jsonEncode({
              'ok': true,
              'schemaVersion': 2,
              'generatedAt': '2026-07-02T00:00:00Z',
              'summary': {
                'agentCount': 1,
                'totalTokens': tokens,
                'meteredTotalBytes': 0,
                'estimatedHistoricalBytes': tokens * 4,
                'attribution': '',
                'confidence': '',
              },
              'agents': [
                {
                  'agentId': agentId,
                  'label': label,
                  'status': 'detected',
                  'history': {
                    'totalTokens': tokens,
                    'dailyUsage': [
                      {
                        'date': _dayKey(),
                        'totalTokens': tokens,
                        'modelUsage': _modelUsage(agentId, tokens),
                      },
                    ],
                    'modelUsage': _modelUsage(agentId, tokens),
                  },
                  'traffic': {'estimatedHistoricalBytes': tokens * 4},
                },
              ],
            }),
          )
          as Map<String, dynamic>;
    }
    return {'ok': true};
  }

  String _argValue(List<String> args, String flag, {String fallback = ''}) {
    final index = args.indexOf(flag);
    if (index < 0 || index + 1 >= args.length) {
      return fallback;
    }
    return args[index + 1];
  }

  Object _modelUsage(String agentId, int tokens) {
    if (tokens <= 0) {
      return const [];
    }
    return switch (agentId) {
      'claude-code' => [
        {'model': 'claude-sonnet-4', 'totalTokens': tokens - 31917287},
        {'model': 'claude-haiku', 'totalTokens': 31917287},
      ],
      'codex' => {
        'gpt-5.4': {'totalTokens': tokens - 1000},
        'deepseek-v4-pro': {'totalTokens': 1000},
      },
      'opencode' => [
        {
          'model':
              '{"id":"deepseek-v4-pro","providerID":"deepseek","variant":"max"}',
          'promptTokens': tokens,
        },
      ],
      _ => const [],
    };
  }

  Map<String, dynamic> _targets(List<String> agentIds) {
    return {
      'ok': true,
      'candidates': [
        for (final agentId in agentIds)
          {
            'target': agentId,
            'label': switch (agentId) {
              'claude-code' => 'Claude Code',
              'codex' => 'Codex',
              'opencode' => 'OpenCode',
              _ => agentId,
            },
            'kind': 'agent',
            'status': 'detected',
            'configured': true,
            'confidence': 1,
          },
      ],
    };
  }

  String _dayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}

class _DelayedStaleUsageAgentService extends _UsageAgentService {
  _DelayedStaleUsageAgentService()
    : super(
        reportGeneratedAt: DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 2))
            .toIso8601String(),
      );

  final Completer<void> _reportRelease = Completer<void>();
  int reportRequests = 0;

  void releaseReport() {
    if (!_reportRelease.isCompleted) {
      _reportRelease.complete();
    }
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'report') {
      reportRequests += 1;
      await _reportRelease.future;
    }
    return super.runCli(args);
  }
}

class _DeltaUsageAgentService extends AgentService {
  _DeltaUsageAgentService() : super(runCliExecutable: null);

  int reportCalls = 0;
  int scanCalls = 0;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    if (args.length >= 2 && args[0] == 'targets' && args[1] == 'scan') {
      return _targets(['claude-code', 'codex']);
    }
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'report') {
      reportCalls += 1;
      return jsonDecode(
            jsonEncode({
              'ok': true,
              'schemaVersion': 2,
              'reports': [
                _report(
                  generatedAt: DateTime.now().toUtc().toIso8601String(),
                  agents: {
                    'claude-code': ('Claude Code', 100),
                    'codex': ('Codex', 40),
                  },
                ),
              ],
            }),
          )
          as Map<String, dynamic>;
    }
    if (args.length >= 2 && args[0] == 'agent-usage' && args[1] == 'scan') {
      scanCalls += 1;
      final agentId = _argValue(args, '--agent');
      final tokens = switch (agentId) {
        'claude-code' => 100,
        'codex' => 40,
        _ => 0,
      };
      final label = switch (agentId) {
        'claude-code' => 'Claude Code',
        'codex' => 'Codex',
        _ => agentId,
      };
      return jsonDecode(
            jsonEncode(
              _report(
                generatedAt: '2026-07-02T00:00:00Z',
                agents: {agentId: (label, tokens)},
              ),
            ),
          )
          as Map<String, dynamic>;
    }
    return {'ok': true};
  }

  Map<String, dynamic> _report({
    required String generatedAt,
    required Map<String, (String, int)> agents,
  }) {
    final total = agents.values.fold<int>(0, (sum, agent) => sum + agent.$2);
    return {
      'ok': true,
      'schemaVersion': 2,
      'generatedAt': generatedAt,
      'summary': {
        'agentCount': agents.length,
        'totalTokens': total,
        'meteredTotalBytes': 0,
        'estimatedHistoricalBytes': total * 4,
        'attribution': '',
        'confidence': '',
      },
      'agents': [
        for (final entry in agents.entries)
          {
            'agentId': entry.key,
            'label': entry.value.$1,
            'status': 'detected',
            'history': {
              'totalTokens': entry.value.$2,
              'dailyUsage': [
                {
                  'date': _dayKey(),
                  'totalTokens': entry.value.$2,
                  'modelUsage': {'${entry.key}-model': entry.value.$2},
                },
              ],
              'modelUsage': {
                '${entry.key}-model': {'totalTokens': entry.value.$2},
              },
            },
            'traffic': {'estimatedHistoricalBytes': entry.value.$2 * 4},
          },
      ],
    };
  }

  String _argValue(List<String> args, String flag, {String fallback = ''}) {
    final index = args.indexOf(flag);
    if (index < 0 || index + 1 >= args.length) {
      return fallback;
    }
    return args[index + 1];
  }

  Map<String, dynamic> _targets(List<String> agentIds) {
    return {
      'ok': true,
      'candidates': [
        for (final agentId in agentIds)
          {
            'target': agentId,
            'label': switch (agentId) {
              'claude-code' => 'Claude Code',
              'codex' => 'Codex',
              _ => agentId,
            },
            'kind': 'agent',
            'status': 'detected',
            'configured': true,
            'confidence': 1,
          },
      ],
    };
  }

  String _dayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}
