import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_summary_widgets.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

AgentUsageReport report({bool revised = false}) => AgentUsageReport.fromAgents(
  generatedAt: '2026-09-13T10:00:00Z',
  agents: [
    for (final agent in ['cursor', 'kimi-code'])
      AgentUsageAgentSummary(
        agentId: agent,
        label: agent == 'cursor' ? 'Cursor' : 'Kimi Code',
        status: 'detected',
        confidence: 'high',
        history: {
          'totalTokens': agent == 'cursor' ? 750 : 250,
          'dailyUsage': [
            {
              'date': '2026-09-13',
              'totalTokens': agent == 'cursor' ? 750 : 250,
              'modelTokenUsage': {
                'kimi-k3': {
                  'displayName': 'Kimi K3',
                  'totalTokens': agent == 'cursor' ? 750 : 250,
                  'variants': agent == 'cursor'
                      ? {
                          'High': {'totalTokens': revised ? 100 : 250},
                          'Extra High': {'totalTokens': revised ? 300 : 150},
                          'Extra High Fast': {'totalTokens': 350},
                        }
                      : {},
                  if (agent != 'cursor')
                    'unattributedVariantUsage': {'totalTokens': 250},
                },
              },
            },
          ],
        },
      ),
  ],
);

AgentUsageTimelineData timeline(AgentUsageReport source) =>
    buildAgentUsageTimelineData(source, AgentUsageChartGrouping.model, const {
      'cursor',
      'kimi-code',
    }, anchor: DateTime(2026, 9, 13));

Widget surface(AgentUsageReport source) {
  final data = timeline(source);
  return MaterialApp(
    theme: buildLicoTheme(),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: AgentUsageBarSection(
          rows: [
            AgentUsageBarData(
              seriesKey: 'kimi-k3',
              label: 'Kimi K3',
              value: '1K',
              trailing: '100%',
              fraction: 1,
              sources: data.modelSources['kimi-k3']!,
            ),
          ],
          emptyLabel: 'No usage',
        ),
      ),
    ),
  );
}

void main() {
  test(
    'canonical model shares combine sources and keep every native variant',
    () {
      final data = timeline(report());
      expect(data.shareSeriesLabels, ['kimi-k3']);
      expect(data.totalFor('kimi-k3'), 1000);
      final sources = data.modelSources['kimi-k3']!;
      expect(sources.map((source) => source.agentId), ['cursor', 'kimi-code']);
      expect(sources.first.usage.variants.keys, [
        'High',
        'Extra High',
        'Extra High Fast',
      ]);
      expect(sources.first.usage.variants['Extra High Fast']!.totalTokens, 350);
    },
  );

  testWidgets(
    'source shares expand, show proportional segments and refresh variant hover',
    (tester) async {
      await tester.pumpWidget(surface(report()));
      expect(
        find.byKey(const ValueKey('usage-model-sources-kimi-k3')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('usage-model-expand-kimi-k3')),
      );
      await tester.pumpAndSettle();
      final cursorSegment = find.byKey(
        const ValueKey('usage-source-segment-kimi-k3-cursor'),
      );
      final kimiSegment = find.byKey(
        const ValueKey('usage-source-segment-kimi-k3-kimi-code'),
      );
      expect(
        tester.getSize(cursorSegment).width / tester.getSize(kimiSegment).width,
        closeTo(3, 0.01),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(cursorSegment));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      final hover = find.byKey(
        const ValueKey('usage-source-hover-card-cursor'),
      );
      expect(hover, findsOneWidget);
      expect(
        find.descendant(of: hover, matching: find.text('Extra High Fast')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: hover, matching: find.text('350')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: hover, matching: find.text('750')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: hover, matching: find.textContaining(' · ')),
        findsNothing,
      );
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      await tester.pumpWidget(surface(report(revised: true)));
      await tester.pumpAndSettle();
      await mouse.moveTo(tester.getCenter(cursorSegment));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.descendant(of: hover, matching: find.text('100')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: hover, matching: find.text('300')),
        findsOneWidget,
      );
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(hover, findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('usage-model-expand-kimi-k3')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('usage-model-sources-kimi-k3')),
        findsNothing,
      );
      await mouse.removePointer();
    },
  );
}
