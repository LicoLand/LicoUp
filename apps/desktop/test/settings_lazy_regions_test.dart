import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/settings/ui/startup_autostart_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

import 'fixtures/settings_binding_fixture.dart';
import 'fixtures/settings_presentation_fixture.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('autostart source observes lazily, survives remount, and '
      'releases with the container', (tester) async {
    const ready = SettingsAutostartProjection(
      phase: SettingsAutostartPhase.ready,
      supported: true,
      desktopEnabled: false,
      desktopSilent: false,
      gatewayEnabled: false,
      mcpEnabled: false,
    );
    final presentation = SettingsPresentationFixture();
    presentation.autostart.publish(ready);
    addTearDown(presentation.dispose);
    final binding = settingsBindingFixture();
    var showCard = false;

    Widget app() => ProviderScope(
      overrides: presentation.overrides,
      child: MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        locale: const Locale('en'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TextButton(
                  key: const Key('toggle-card'),
                  onPressed: () => setState(() => showCard = !showCard),
                  child: const Text('toggle'),
                ),
                if (showCard) StartupAutostartCard(binding: binding),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump();

    // No region widget is mounted, so the source has no observation.
    expect(presentation.autostart.openCount, 0);
    expect(presentation.autostart.closeCount, 0);

    await tester.tap(find.byKey(const Key('toggle-card')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Enable auto-start'), findsOneWidget);
    expect(presentation.autostart.openCount, 1);

    // Unmounting and remounting the card reuses the open observation: the
    // re-mounted region renders its installed value in the same frame instead
    // of collapsing to a loading gap that would shift the scroll extent.
    await tester.tap(find.byKey(const Key('toggle-card')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Enable auto-start'), findsNothing);
    await tester.tap(find.byKey(const Key('toggle-card')));
    await tester.pump();
    expect(find.text('Enable auto-start'), findsOneWidget);
    expect(presentation.autostart.openCount, 1);
    expect(presentation.autostart.closeCount, 0);

    // Disposing the provider container releases the observation.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(presentation.autostart.closeCount, 1);
  });
}
