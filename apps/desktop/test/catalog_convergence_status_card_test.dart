import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/frontend/features/settings/ui/catalog_convergence_status_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/settings_binding_fixture.dart';

void main() {
  testWidgets(
    'status card projects bounded facts without opaque partition keys',
    (tester) async {
      final source = SettingsProjectionFixture(
        settingsProjectionFixture(
          catalog: const SettingsCatalogProjection(
            phase: SettingsCatalogPhase.ready,
            reasonCode: 'catalog_current',
            busy: false,
            partitionCount: 1,
            pendingInvalidationCount: 0,
            appliedCohortCount: 1,
            uiObservedRevision: 7,
          ),
        ),
      );
      final binding = settingsBindingFixture(source: source);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: Scaffold(body: CatalogConvergenceStatusCard(binding: binding)),
        ),
      );

      expect(find.text('Tool catalog sync'), findsOneWidget);
      expect(find.textContaining('Partitions: 1'), findsOneWidget);
      expect(find.textContaining('UI revision: 7'), findsOneWidget);
      expect(find.textContaining('opaque-private-partition'), findsNothing);
    },
  );
}
