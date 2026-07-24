import 'package:flutter/material.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'usage_agent_service_fakes.dart';
import 'usage_panel_fixtures.dart';

void registerAgentUsageModelShareScenarios() {
  testWidgets('model share keeps a stable top ten and full model denominator', (
    tester,
  ) async {
    final controller = ClientController(agentService: UsageAgentService());
    controller
      ..scannedTargets = testTargets(['codex'])
      ..agentUsageReport = equalModelUsageReport();
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
      final controller = ClientController(agentService: UsageAgentService())
        ..scannedTargets = testTargets(['code', 'codex', 'cursor', 'kimi-code'])
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

      const tokenShareKey = ValueKey('agent-usage-token-share');
      final tokenShare = find.byKey(tokenShareKey);
      expect(
        find.descendant(of: tokenShare, matching: find.text('Codex')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tokenShare, matching: find.text('Cursor')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tokenShare, matching: find.text('Kimi Code')),
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
    'usage share bars scale to total share for agent and model rows',
    (tester) async {
      final controller = ClientController(agentService: UsageAgentService())
        ..scannedTargets = testTargets(['codex', 'claude-code'])
        ..agentUsageReport = shareFractionUsageReport();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        usageTestApp(
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

      expect(progressFillFactor(tester, 'Total'), closeTo(1.0, 0.01));
      expect(progressFillFactor(tester, 'Codex'), closeTo(0.55, 0.01));
      expect(progressFillFactor(tester, 'Claude Code'), closeTo(0.45, 0.01));
      expect(find.text('55%'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);

      await tester.tap(find.text('By Model'));
      await tester.pumpAndSettle();

      expect(progressFillFactor(tester, 'Total'), closeTo(1.0, 0.01));
      expect(progressFillFactor(tester, 'GPT 5.5'), closeTo(0.55, 0.01));
      expect(
        progressFillFactor(tester, 'Claude Sonnet 4'),
        closeTo(0.45, 0.01),
      );
      expect(find.text('55%'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);
    },
  );
}

void main() => registerAgentUsageModelShareScenarios();
