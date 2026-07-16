import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_window_control.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

void main() {
  testWidgets('usage window exposes every day from 1 through 365', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: Scaffold(
          body: AgentUsageWindowControl(
            days: 30,
            busy: false,
            onChanged: selected.add,
          ),
        ),
      ),
    );

    final slider = tester.widget<Slider>(
      find.byKey(const Key('agent-usage-history-days')),
    );
    expect(slider.min, 1);
    expect(slider.max, 365);
    expect(slider.divisions, 364);
    slider.onChangeEnd!(365);
    expect(selected, [365]);
  });
}
