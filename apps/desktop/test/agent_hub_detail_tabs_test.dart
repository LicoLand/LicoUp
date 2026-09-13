import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_detail_tabs.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('detail selector works with keyboard and narrow large text', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            textScaler: TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 250,
                child: StatefulBuilder(
                  builder: (context, setState) => AgentHubDetailTabs(
                    labels: const ['Overview', 'Plugins', 'Skills'],
                    selectedIndex: selected,
                    onSelected: (index) => setState(() => selected = index),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selected, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(selected, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(selected, 0);
    expect(
      tester
          .widget<AnimatedPositionedDirectional>(
            find.byType(AnimatedPositionedDirectional),
          )
          .duration,
      Duration.zero,
    );
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detail switching preserves page edits and hidden focus stays excluded',
    (tester) async {
      var selected = 0;
      const pageKey = Key('retained-page-input');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  AgentHubDetailTabs(
                    labels: const ['Overview', 'Plugins'],
                    selectedIndex: selected,
                    onSelected: (index) => setState(() => selected = index),
                  ),
                  Expanded(
                    child: AgentHubDetailTabView(
                      selectedIndex: selected,
                      children: const [
                        TextField(key: pageKey),
                        Text('Plugin catalog'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(pageKey), 'Preserve this filter');
      final original = tester.state(find.byKey(pageKey));
      await tester.tap(find.byKey(const Key('agent-hub-detail-tab-1')));
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.context?.widget.key,
        isNot(pageKey),
      );
      await tester.tap(find.byKey(const Key('agent-hub-detail-tab-0')));
      await tester.pumpAndSettle();
      expect(tester.state(find.byKey(pageKey)), same(original));
      expect(find.text('Preserve this filter'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
