import 'package:flutter/material.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_summary_widgets.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('summary section renders rows and proportional progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: const SizedBox(
          width: 640,
          child: AgentUsageBarSection(
            title: 'Usage fixture',
            valueHeader: 'Tokens',
            emptyLabel: 'No usage fixture',
            rows: [
              AgentUsageBarData(
                label: 'Agent A',
                value: '750',
                trailing: '75%',
                fraction: 0.75,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Usage fixture'), findsOneWidget);
    expect(find.text('Agent A'), findsOneWidget);
    expect(find.text('750'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('usage-progress-Agent A')),
      findsOneWidget,
    );
  });

  testWidgets('summary and report empty states are independently renderable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: const Column(
          children: [
            AgentUsageEmptyState(),
            AgentUsageBarSection(
              title: 'Empty fixture',
              rows: [],
              emptyLabel: 'No rows fixture',
            ),
          ],
        ),
      ),
    );

    expect(find.text('No usage report yet'), findsOneWidget);
    expect(find.text('No rows fixture'), findsOneWidget);
  });
}
