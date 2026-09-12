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
                  'totalTokens': agent == 'cursor' ? 750 : 250,
                  'variants': agent == 'cursor'
                      ? {
                          'High': {'totalTokens': revised ? 100 : 250},
                          'Extra High': {'totalTokens': revised ? 300 : 150},
                          'Extra High Fast': {'totalTokens': 350},
                        }
                      : {
                          'Unspecified': {'totalTokens': 250},
                        },
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
              label: 'Kimi K3',
              value: '1K',
              trailing: '100%',
              fraction: 1,
              sources: data.modelSources['Kimi K3']!,
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
      expect(data.shareSeriesLabels, ['Kimi K3']);
      expect(data.totalFor('Kimi K3'), 1000);
      final sources = data.modelSources['Kimi K3']!;
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
        find.byKey(const ValueKey('usage-model-sources-Kimi K3')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('usage-model-expand-Kimi K3')),
      );
      await tester.pumpAndSettle();
      final cursorSegment = find.byKey(
        const ValueKey('usage-source-segment-Kimi K3-cursor'),
      );
      final kimiSegment = find.byKey(
        const ValueKey('usage-source-segment-Kimi K3-kimi-code'),
      );
      expect(
        tester.getSize(cursorSegment).width / tester.getSize(kimiSegment).width,
        closeTo(3, 0.01),
      );
      final tooltip = tester.widget<Tooltip>(
        find.byKey(const ValueKey('usage-source-tooltip-Kimi K3-cursor')),
      );
      expect(tooltip.message, contains('Extra High Fast · 350'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(cursorSegment));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('Extra High Fast · 350'), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      await tester.pumpWidget(surface(report(revised: true)));
      await tester.pumpAndSettle();
      final revised = tester.widget<Tooltip>(
        find.byKey(const ValueKey('usage-source-tooltip-Kimi K3-cursor')),
      );
      expect(revised.message, contains('High · 100'));
      expect(revised.message, contains('Extra High · 300'));
      await tester.tap(
        find.byKey(const ValueKey('usage-model-expand-Kimi K3')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('usage-model-sources-Kimi K3')),
        findsNothing,
      );
      await mouse.removePointer();
    },
  );
}
