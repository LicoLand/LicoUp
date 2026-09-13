import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_chart_controls.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_source_hover.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline/agent_usage_token_breakdown.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

AgentUsageModelSource hoverSource({
  bool attributed = true,
  int highTokens = 250000,
}) => AgentUsageModelSource(
  agentId: 'cursor',
  label: 'Cursor',
  usage: AgentUsageModelTokens(
    totalTokens: 750000,
    breakdown: const AgentUsageTokenBreakdown.unavailable(totalTokens: 750000),
    variants: {
      if (attributed) ...{
        'High': AgentUsageModelVariant(label: 'High', totalTokens: highTokens),
        'Extra High Fast': const AgentUsageModelVariant(
          label: 'Extra High Fast',
          totalTokens: 150000,
        ),
      },
    },
  ),
);

Widget hoverApp({
  required Widget child,
  bool light = false,
  double scale = 1,
}) => MaterialApp(
  theme: buildLicoTheme(presetId: light ? 'lico-soda-light' : 'lico-soda-dark'),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: Center(child: child)),
);

Widget sourceHoverTarget(AgentUsageModelSource source) => AgentUsageSourceHover(
  source: source,
  child: Container(
    key: const ValueKey('synthetic-source-segment'),
    width: 220,
    height: 14,
    color: Colors.indigo,
  ),
);

Future<TestGesture> showSourceHover(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(
    tester.getCenter(find.byKey(const ValueKey('synthetic-source-segment'))),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 200));
  return mouse;
}

void main() {
  testWidgets(
    'source hover uses independent glass rows and preserves unassigned total',
    (tester) async {
      await tester.pumpWidget(
        hoverApp(child: sourceHoverTarget(hoverSource())),
      );
      final mouse = await showSourceHover(tester);
      final card = find.byKey(const ValueKey('usage-source-hover-card-cursor'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.byType(BackdropFilter)),
        findsWidgets,
      );
      expect(
        find.descendant(of: card, matching: find.text('750K')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('High')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('250K')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Extra High Fast')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('150K')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.textContaining(' · ')),
        findsNothing,
      );
      expect(
        tester.getRect(find.text('250K')).right,
        closeTo(tester.getRect(find.text('150K')).right, 0.01),
      );
      final host = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(host.message, isNull);
      expect(host.richMessage, isA<WidgetSpan>());
      await tester.pumpWidget(
        hoverApp(child: sourceHoverTarget(hoverSource(highTokens: 100000))),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: card, matching: find.text('100K')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('250K')),
        findsNothing,
      );
      expect(
        find.descendant(of: card, matching: find.text('750K')),
        findsOneWidget,
      );
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      await mouse.removePointer();
    },
  );

  testWidgets('source without effort shows only its complete header', (
    tester,
  ) async {
    await tester.pumpWidget(
      hoverApp(child: sourceHoverTarget(hoverSource(attributed: false))),
    );
    final mouse = await showSourceHover(tester);
    final card = find.byKey(const ValueKey('usage-source-hover-card-cursor'));
    expect(
      find.descendant(of: card, matching: find.byType(Text)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: card, matching: find.text('Cursor')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('750K')),
      findsOneWidget,
    );
    expect(
      find.textContaining(RegExp('Unspecified|default|unknown')),
      findsNothing,
    );
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  for (final light in [false, true]) {
    for (final size in [const Size(800, 640), const Size(300, 640)]) {
      testWidgets(
        'source glass hover stays bounded in ${light ? 'light' : 'dark'} at ${size.width}',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          await tester.pumpWidget(
            hoverApp(
              child: sourceHoverTarget(hoverSource()),
              light: light,
              scale: 1.5,
            ),
          );
          final mouse = await showSourceHover(tester);
          final card = find.byKey(
            const ValueKey('usage-source-hover-card-cursor'),
          );
          final bounds = tester.getRect(card);
          expect(bounds.left, greaterThanOrEqualTo(8));
          expect(bounds.right, lessThanOrEqualTo(size.width - 8));
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(size.height));
          expect(tester.takeException(), isNull);
          final fill = tester.widget<ColoredBox>(
            find.byKey(
              const ValueKey('usage-source-hover-card-cursor-glass-fill'),
            ),
          );
          expect(fill.color.a, closeTo(light ? 0.84 : 0.72, 0.01));
          await mouse.removePointer();
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets('daily card keeps date, full total and aligned series rows', (
    tester,
  ) async {
    final snapshot = AgentUsageSnapshot(
      time: DateTime(2026, 9, 8),
      values: const {'grok-4.6': 652200000, 'gpt-6-astra': 604600000},
    );
    final timeline = AgentUsageTimelineData(
      displayNames: const {
        'grok-4.6': 'Grok 4.6',
        'gpt-6-astra': 'GPT-6 Astra',
      },
      snapshots: [snapshot],
      series: const [
        AgentUsageSeries(label: 'grok-4.6'),
        AgentUsageSeries(label: 'gpt-6-astra'),
      ],
      seriesTotals: snapshot.values,
      shareSeriesLabels: snapshot.values.keys.toList(),
      groupTotal: snapshot.total,
      hasDailyBreakdown: true,
      grouping: AgentUsageChartGrouping.model,
    );
    await tester.pumpWidget(
      hoverApp(
        child: SizedBox(
          width: 340,
          child: AgentUsageChartTooltip(timeline: timeline, snapshot: snapshot),
        ),
      ),
    );
    final card = find.byKey(const ValueKey('usage-wave-tooltip'));
    expect(card, findsOneWidget);
    expect(find.text('2026-09-08'), findsOneWidget);
    expect(find.text('1.3B'), findsOneWidget);
    expect(find.text('Grok 4.6'), findsOneWidget);
    expect(find.text('GPT-6 Astra'), findsOneWidget);
    expect(
      tester.getRect(find.text('652.2M')).right,
      closeTo(tester.getRect(find.text('604.6M')).right, 0.01),
    );
  });
}
