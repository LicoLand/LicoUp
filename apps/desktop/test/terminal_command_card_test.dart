import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/features/settings/ui/terminal_command_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

import 'fixtures/settings_binding_fixture.dart';
import 'fixtures/settings_presentation_fixture.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

Future<void> _pumpCard(
  WidgetTester tester,
  SettingsPresentationFixture presentation,
  RecordingSettingsIntents intents,
) async {
  final binding = settingsBindingFixture(intents: intents);
  await tester.pumpWidget(
    ProviderScope(
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
          body: SingleChildScrollView(
            child: TerminalCommandCard(binding: binding),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('not installed state offers install', (tester) async {
    final presentation = SettingsPresentationFixture();
    presentation.terminalCommand.publish(
      const SettingsTerminalCommandProjection(
        phase: TerminalCommandPhase.ready,
        supported: true,
        status: TerminalCommandLinkStatus.notInstalled,
      ),
    );
    addTearDown(presentation.dispose);
    final intents = RecordingSettingsIntents(
      onSend: (intent) {
        if (intent is InstallTerminalCommand) {
          presentation.terminalCommand.publish(
            const SettingsTerminalCommandProjection(
              phase: TerminalCommandPhase.ready,
              supported: true,
              status: TerminalCommandLinkStatus.installed,
              result: TerminalCommandResult.installed,
            ),
          );
        }
      },
    );
    await _pumpCard(tester, presentation, intents);

    expect(find.text('licoup'), findsOneWidget);
    expect(find.byKey(const Key('terminal-command-install')), findsOneWidget);
    expect(find.byKey(const Key('terminal-command-uninstall')), findsNothing);

    await tester.tap(find.byKey(const Key('terminal-command-install')));
    await tester.pumpAndSettle();

    expect(
      intents.values.whereType<InstallTerminalCommand>().isNotEmpty,
      isTrue,
    );
    expect(find.byKey(const Key('terminal-command-uninstall')), findsOneWidget);
  });

  testWidgets('installed state offers uninstall', (tester) async {
    final presentation = SettingsPresentationFixture();
    presentation.terminalCommand.publish(
      const SettingsTerminalCommandProjection(
        phase: TerminalCommandPhase.ready,
        supported: true,
        status: TerminalCommandLinkStatus.installed,
      ),
    );
    addTearDown(presentation.dispose);
    final intents = RecordingSettingsIntents();
    await _pumpCard(tester, presentation, intents);

    expect(find.byKey(const Key('terminal-command-uninstall')), findsOneWidget);
    await tester.tap(find.byKey(const Key('terminal-command-uninstall')));
    await tester.pumpAndSettle();
    expect(
      intents.values.whereType<UninstallTerminalCommand>().isNotEmpty,
      isTrue,
    );
  });

  testWidgets('occupied state shows the foreign path and no action', (
    tester,
  ) async {
    final presentation = SettingsPresentationFixture();
    presentation.terminalCommand.publish(
      const SettingsTerminalCommandProjection(
        phase: TerminalCommandPhase.ready,
        supported: true,
        status: TerminalCommandLinkStatus.occupied,
        occupiedPath: '/opt/homebrew/bin/licoup',
      ),
    );
    addTearDown(presentation.dispose);
    final intents = RecordingSettingsIntents();
    await _pumpCard(tester, presentation, intents);

    expect(find.textContaining('/opt/homebrew/bin/licoup'), findsOneWidget);
    expect(find.byKey(const Key('terminal-command-install')), findsNothing);
    expect(find.byKey(const Key('terminal-command-uninstall')), findsNothing);
  });

  testWidgets('stale state offers the repair action', (tester) async {
    final presentation = SettingsPresentationFixture();
    presentation.terminalCommand.publish(
      const SettingsTerminalCommandProjection(
        phase: TerminalCommandPhase.ready,
        supported: true,
        status: TerminalCommandLinkStatus.stale,
      ),
    );
    addTearDown(presentation.dispose);
    final intents = RecordingSettingsIntents();
    await _pumpCard(tester, presentation, intents);

    expect(find.text('Repair terminal command link'), findsOneWidget);
  });
}
