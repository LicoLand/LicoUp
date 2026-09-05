import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_search.dart';

import '../../../fixtures/layout_palette_fixture.dart';

void main() {
  testWidgets('selecting a search result navigates exactly once', (
    tester,
  ) async {
    final selections = <ClientSection>[];
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: LayoutPaletteScope(
          palette: fixtureDarkLayoutPalette,
          child: Scaffold(
            body: Center(
              child: DashboardDesktopSearch(
                current: ClientSection.agents,
                availableSections: ClientSection.values,
                onSelect: selections.add,
                width: 240,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'settings');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(selections, [ClientSection.settings]);
    expect(tester.takeException(), isNull);
  });
}
