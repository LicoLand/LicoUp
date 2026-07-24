import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_usage_window_control.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

void main() {
  testWidgets('usage window presets apply in one tap', (tester) async {
    final selected = <int>[];
    await tester.pumpWidget(
      _WindowTestApp(
        child: AgentUsageWindowControl(
          days: 30,
          busy: false,
          onChanged: selected.add,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('agent-usage-window-chip-90')));
    await tester.pump();
    expect(selected, [90]);
    expect(find.byKey(const Key('agent-usage-window-chip-7')), findsOneWidget);
  });

  testWidgets('usage window stays inert while busy', (tester) async {
    final selected = <int>[];
    await tester.pumpWidget(
      _WindowTestApp(
        child: AgentUsageWindowControl(
          days: 30,
          busy: true,
          onChanged: selected.add,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('agent-usage-window-chip-7')));
    await tester.pump();
    expect(selected, isEmpty);
  });
}

class _WindowTestApp extends StatelessWidget {
  const _WindowTestApp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: Scaffold(body: Center(child: child)),
    );
  }
}
