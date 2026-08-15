import 'package:flutter/material.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'usage_agent_service_fakes.dart';
import 'usage_panel_fixtures.dart';

void registerAgentUsageFormattingScenarios() {
  testWidgets('agent usage panel formats large numbers with compact units', (
    tester,
  ) async {
    final service = UsageAgentService();
    final controller = ClientController(agentService: service);
    controller.scannedTargets = testTargets([
      'claude-code',
      'codex',
      'opencode',
    ]);
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

    expect(find.text('231.9M'), findsAtLeastNWidgets(1));
    expect(service.reportCalls, 1);
    expect(service.scanCalls, 1);
    expect(find.text('7.9M'), findsAtLeastNWidgets(1));
    expect(find.text('670.7K'), findsAtLeastNWidgets(1));
    expect(find.text('Token Usage'), findsOneWidget);
    expect(find.byKey(const Key('agent-usage-exit-button')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('agent-usage-exit-button'))).dx,
      lessThan(tester.getTopLeft(find.text('Token Usage')).dx),
    );
    controller.selectSection(ClientSection.monitoring);
    await tester.tap(find.byKey(const Key('agent-usage-exit-button')));
    await tester.pump();
    expect(controller.currentSection, ClientSection.agents);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('240.4M'), findsOneWidget);
    expect(find.text('Report Totals'), findsNothing);
    expect(find.text('Metered Traffic'), findsNothing);
    expect(find.text('Estimated History'), findsNothing);
    expect(find.text('Usage Over Time'), findsNothing);
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
      find.descendant(of: tokenShare, matching: find.text('Claude Code')),
      findsNothing,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('Codex')),
      findsNothing,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('OpenCode')),
      findsNothing,
    );
    expect(find.textContaining('{"id"'), findsNothing);

    await tester.tap(find.text('By Agent'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: tokenShare, matching: find.text('Claude Code')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('Codex')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('OpenCode')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tokenShare, matching: find.text('GPT 5.4')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
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

    expect(service.reportCalls, 1);
    expect(service.scanCalls, 1);
  });
}

void main() => registerAgentUsageFormattingScenarios();
