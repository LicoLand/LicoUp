import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'fixtures/agent_usage_panel/usage_panel_fixtures.dart';

void main() {
  test('current workflow envelope exposes one immutable 52-token tree', () {
    final report = syntheticWorkflowUsageReport();
    expect(report.workflows, hasLength(1));
    final workflow = report.workflows.single;
    expect(workflow.totalTokens, 52);
    expect(workflow.promptTokens, 41);
    expect(workflow.cachedInputTokens, 8);
    expect(workflow.completionTokens, 11);
    expect(workflow.exactCount, 4);
    expect(workflow.estimatedCount, 0);
    expect(workflow.exactCoverage, 1);
    expect(workflow.roots, hasLength(1));
    expect(workflow.roots.single.children, hasLength(3));
    expect(() => report.workflows.add(workflow), throwsUnsupportedError);

    final serialized = workflow.toJson().toString();
    expect(serialized, isNot(contains('path-canary')));
    expect(serialized, isNot(contains('prompt-canary')));
    expect(serialized, isNot(contains('reply-canary')));
    expect(serialized, isNot(contains('tool-canary')));
  });

  test('old and malformed workflow generations fail closed', () {
    expect(
      () => syntheticWorkflowUsageReport(workflowSchema: 'v0'),
      throwsA(isA<FormatException>()),
    );
    final oldReport = AgentUsageReport.fromJson({
      'schemaVersion': AgentUsageReport.currentSchemaVersion,
      'mode': AgentUsageReport.currentMode,
      'tokenSourceMode': AgentUsageReport.currentTokenSourceMode,
      'generatedAt': '2026-08-09T00:00:00Z',
      'summary': const {'totalTokens': 7},
      'agents': const [],
    });
    expect(oldReport.workflows, isEmpty);
  });

  testWidgets(
    'English workflow view progressively discloses Plan, Task, dispatch',
    (tester) async {
      final report = syntheticWorkflowUsageReport();
      await tester.pumpWidget(_app(report));
      await tester.tap(find.byKey(const Key('agent-usage-grouping-workflow')));
      await tester.pumpAndSettle();

      expect(find.text('Workflow Usage'), findsOneWidget);
      expect(find.text('52'), findsAtLeastNWidgets(1));
      expect(find.text('8'), findsAtLeastNWidgets(1));
      expect(find.text('Exact 4/4 (100%)'), findsOneWidget);
      expect(find.text('Main'), findsAtLeastNWidgets(1));
      expect(find.text('Subordinate'), findsAtLeastNWidgets(1));
      expect(find.text('Main conversation'), findsNothing);
      expect(find.text('Task · DESIGN'), findsNothing);

      final planRow = find.byKey(
        const ValueKey('agent-usage-workflow-plan-row'),
      );
      await tester.ensureVisible(planRow);
      await tester.tap(planRow);
      await tester.pumpAndSettle();
      expect(find.text('Main conversation'), findsOneWidget);
      expect(find.text('Task · DESIGN'), findsOneWidget);
      expect(find.text('Task · IMPLEMENT'), findsOneWidget);
      expect(find.text('Task · REVIEW'), findsOneWidget);

      final designTask = find.text('Task · DESIGN');
      await tester.ensureVisible(designTask);
      await tester.tap(designTask);
      await tester.pumpAndSettle();
      expect(find.text('Dispatch 1'), findsOneWidget);
      expect(find.text('Designer'), findsOneWidget);
      expect(find.text('Agent Designer'), findsOneWidget);
      expect(find.text('Model Designer'), findsOneWidget);
      expect(find.text('Completed'), findsAtLeastNWidgets(1));
      expect(find.textContaining('private-'), findsNothing);
    },
  );

  testWidgets(
    'Simplified Chinese labels remain localized and Agent view survives empty workflow',
    (tester) async {
      final emptyWorkflowReport = AgentUsageReport.fromAgents(
        generatedAt: '2026-08-09T00:00:00Z',
        agents: const [
          AgentUsageAgentSummary(
            agentId: 'codex',
            label: 'Codex',
            status: 'detected',
            history: {'totalTokens': 12},
            confidence: 'high',
          ),
        ],
      );
      await tester.pumpWidget(
        _app(emptyWorkflowReport, locale: const Locale('zh')),
      );
      await tester.tap(find.byKey(const Key('agent-usage-grouping-workflow')));
      await tester.pumpAndSettle();
      expect(find.text('工作流用量'), findsOneWidget);
      expect(find.text('暂无工作流用量'), findsOneWidget);

      await tester.tap(find.byKey(const Key('agent-usage-grouping-agent')));
      await tester.pumpAndSettle();
      expect(find.text('Codex'), findsAtLeastNWidgets(1));
      expect(find.text('工作流'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'Simplified Chinese workflow components and dispatch are localized',
    (tester) async {
      await tester.pumpWidget(
        _app(syntheticWorkflowUsageReport(), locale: const Locale('zh')),
      );
      await tester.tap(find.byKey(const Key('agent-usage-grouping-workflow')));
      await tester.pumpAndSettle();
      expect(find.text('工作流用量'), findsOneWidget);
      expect(find.textContaining('提示词'), findsOneWidget);
      expect(find.textContaining('补全'), findsOneWidget);
      expect(find.textContaining('Prompt'), findsNothing);
      expect(find.textContaining('Completion'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('agent-usage-workflow-plan-row')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('任务 · DESIGN'));
      await tester.pumpAndSettle();
      expect(find.text('派发 1'), findsOneWidget);
      expect(find.text('设计者'), findsOneWidget);
      expect(find.text('Agent Designer'), findsOneWidget);
      expect(find.text('Model Designer'), findsOneWidget);
      expect(find.text('已完成'), findsAtLeastNWidgets(1));
    },
  );
}

Widget _app(AgentUsageReport report, {Locale? locale}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: const [Locale('en'), Locale('zh')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: buildLicoTheme(platformBrightness: Brightness.dark),
    home: Material(
      child: SingleChildScrollView(
        child: SizedBox(
          width: 980,
          child: AgentUsageCharts(
            report: report,
            detectedAgentIds: const {'codex'},
            windowDays: 30,
            windowBusy: false,
            onWindowChanged: (_) {},
          ),
        ),
      ),
    ),
  );
}
