import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'usage_agent_service_fakes.dart';
import 'usage_panel_fixtures.dart';

void registerAgentUsageTimelineScenarios() {
  testWidgets('agent usage timeline shows thirty day daily usage buckets', (
    tester,
  ) async {
    final service = DeltaUsageAgentService();
    final controller = ClientController(agentService: service);
    controller.scannedTargets = testTargets(['claude-code', 'codex']);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      usageTestApp(
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

    expect(find.text('Token Usage'), findsOneWidget);
    expect(find.text('Usage Over Time'), findsNothing);
    expect(find.text('Last 30 days'), findsNothing);
    expect(find.byKey(const Key('agent-usage-window-chip-30')), findsOneWidget);
    expect(find.text('Codex'), findsAtLeastNWidgets(1));
    expect(find.text('40'), findsAtLeastNWidgets(1));
    expect(service.reportCalls, 1);
    expect(service.scanCalls, 1);
  });

  testWidgets('snapshot-only reports do not masquerade as daily usage deltas', (
    tester,
  ) async {
    final controller = ClientController(agentService: UsageAgentService());
    controller.scannedTargets = testTargets(['codex']);
    final now = DateTime.now().toUtc();
    final latest = snapshotOnlyReport(
      generatedAt: now.toIso8601String(),
      totalTokens: 140,
    );
    controller
      ..agentUsageReport = latest
      ..agentUsageReports = [
        latest,
        snapshotOnlyReport(
          generatedAt: now.subtract(const Duration(days: 1)).toIso8601String(),
          totalTokens: 100,
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      usageTestApp(
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
        matching: find.text('Codex'),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'usage chart tooltip follows the active agent or model grouping',
    (tester) async {
      final controller = ClientController(agentService: UsageAgentService())
        ..scannedTargets = testTargets(['codex', 'cursor', 'kimi-code'])
        ..agentUsageReport = formalNamingUsageReport();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        usageTestApp(
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
        find.descendant(of: tooltip, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      final glassFill = tester.widget<ColoredBox>(
        find.descendant(
          of: tooltip,
          matching: find.byKey(const ValueKey('usage-wave-tooltip-glass-fill')),
        ),
      );
      expect(glassFill.color.a, closeTo(0.72, 0.01));
      expect(glassFill.color.r, closeTo(0x17 / 255, 0.01));
      expect(glassFill.color.g, closeTo(0x19 / 255, 0.01));
      expect(glassFill.color.b, closeTo(0x1c / 255, 0.01));
      expect(
        find.descendant(of: tooltip, matching: find.text('Codex')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tooltip, matching: find.text('Cursor')),
        findsNothing,
      );
      expect(
        find.descendant(of: tooltip, matching: find.text('Kimi Code')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tooltip, matching: find.text(dayKeyForNow())),
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
}

void main() => registerAgentUsageTimelineScenarios();
