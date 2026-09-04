import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel_widgets.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/directory_path_field.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';

import 'fixtures/settings_binding_fixture.dart';
import 'layout/layout_host_test_fixtures.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('language picker dispatches a semantic locale intent', (
    tester,
  ) async {
    final fixture = _settingsFixture(locale: 'zh');
    await _pumpSettings(tester, fixture, locale: const Locale('zh'));

    expect(find.text('语言'), findsOneWidget);
    expect(find.byKey(const Key('settings-locale-dropdown')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-locale-dropdown')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('settings-locale-en')).last);
    await tester.pump();

    final localeIntent = fixture.intents.values
        .whereType<SetLocalePreference>()
        .single;
    expect(localeIntent.preference, 'en');
  });

  testWidgets('appearance and layout preserve existing control hierarchy', (
    tester,
  ) async {
    final fixture = _settingsFixture();
    await _pumpSettings(tester, fixture, locale: const Locale('zh'));

    expect(find.text('外观预设'), findsOneWidget);
    expect(
      find.byKey(const Key('settings-appearance-dropdown')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('appearance-day-night-toggle')),
      findsOneWidget,
    );
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('明亮'), findsOneWidget);
    expect(find.text('暗黑'), findsOneWidget);
    expect(find.bySemanticsLabel('界面布局'), findsOneWidget);
    final dropdowns = tester
        .widgetList<SettingsDropdownList<String>>(
          find.byType(SettingsDropdownList<String>),
        )
        .toList();
    expect(dropdowns, hasLength(2));
    expect(dropdowns.map((dropdown) => dropdown.locked).toSet(), {true, false});
  });

  testWidgets('storage paths and archive section remain reachable', (
    tester,
  ) async {
    final fixture = _settingsFixture(
      snapshotRoot: 'test-data/licoup/native-conversation-snapshots',
    );
    await _pumpSettings(tester, fixture, height: 1400);
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('settings-content-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('LicoUp Backup Directory'),
      360,
      scrollable: scrollable,
    );
    expect(find.text('LicoUp Data Directory'), findsOneWidget);
    expect(find.text('LicoUp Backup Directory'), findsOneWidget);
    expect(
      find.text('test-data/licoup/native-conversation-snapshots'),
      findsOneWidget,
    );
  });

  testWidgets('backup directory open intent retains the edited path', (
    tester,
  ) async {
    final fixture = _settingsFixture();
    await _pumpSettings(tester, fixture, height: 1400);
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('settings-content-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final backupField = find.byWidgetPredicate(
      (widget) =>
          widget is DirectoryPathField &&
          widget.title == 'LicoUp Backup Directory',
    );
    await tester.scrollUntilVisible(backupField, 360, scrollable: scrollable);
    await tester.enterText(
      find.descendant(of: backupField, matching: find.byType(TextField)),
      'test-data/licoup/edited-backups',
    );
    await tester.tap(
      find.descendant(
        of: backupField,
        matching: find.byIcon(Icons.open_in_new_outlined),
      ),
    );
    await tester.pump();

    final intent = fixture.intents.values
        .whereType<OpenSettingsDirectory>()
        .single;
    expect(intent.directory, SettingsDirectory.conversationSnapshots);
    expect(intent.path, 'test-data/licoup/edited-backups');
  });

  testWidgets('settings sidebar keeps the canonical section order', (
    tester,
  ) async {
    final fixture = _settingsFixture();
    await _pumpSettings(
      tester,
      fixture,
      locale: const Locale('zh'),
      height: 1400,
    );
    const expected = ['通用', '外观', '更新', '启动', '工具', '存储', '诊断', '归档'];
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .where((candidate) => candidate.style?.fontSize == 12.5)
        .map((candidate) => candidate.data)
        .whereType<String>()
        .toList();
    expect(labels, expected);
  });

  testWidgets('settings sidebar reaches a lazy intermediate section', (
    tester,
  ) async {
    final fixture = _settingsFixture();
    await _pumpSettings(tester, fixture, height: 720);

    await tester.tap(find.text('Startup').first);
    for (var frame = 0; frame < 8; frame += 1) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    expect(find.text('Enable auto-start'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark appearance keeps the existing brightness filter', (
    tester,
  ) async {
    final fixture = _settingsFixture(
      appearanceId: AppearancePresetIds.licoSoda,
    );
    await _pumpSettings(tester, fixture, height: 460);

    final dropdown = tester.widget<SettingsDropdownList<String>>(
      find.byKey(const Key('settings-appearance-dropdown')),
    );
    expect(dropdown.locked, isTrue);
    expect(dropdown.enabled, isTrue);
    expect(
      dropdown.items.map((item) => item.value).toSet().intersection(const {
        'default-system',
        'lico-soda',
        'lico-soda-light',
      }),
      const {'lico-soda'},
    );
    expect(find.text('LicoUp Dark'), findsOneWidget);
    expect(find.text('LicoUp Light'), findsNothing);
  });

  testWidgets('settings index follows scroll and returns to General', (
    tester,
  ) async {
    final fixture = _settingsFixture();
    await _pumpSettings(tester, fixture, height: 720);
    final colors = tester.element(find.byType(SettingsPanel)).licoColors;

    Color? indexForeground(String label) => tester
        .widgetList<Text>(find.text(label))
        .where((candidate) => candidate.style?.fontSize == 12.5)
        .firstOrNull
        ?.style
        ?.color;

    expect(indexForeground('General'), colors.textOnPrimary);
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('settings-content-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Archived conversations'),
      360,
      scrollable: scrollable,
    );
    await tester.drag(scrollable, const Offset(0, -240));
    await tester.pump(const Duration(milliseconds: 500));
    expect(indexForeground('General'), isNot(colors.textOnPrimary));

    await tester.tap(find.text('General').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(indexForeground('General'), colors.textOnPrimary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance day/night toggle remains renderer-local', (
    tester,
  ) async {
    var selection = AppearanceBrightnessSelection.dark;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(),
        home: StatefulBuilder(
          builder: (context, setState) => SettingsDayNightToggleRow(
            selection: selection,
            onChanged: (value) => setState(() => selection = value),
          ),
        ),
      ),
    );
    await tester.tap(find.text('明亮'));
    await tester.pump();
    expect(selection, AppearanceBrightnessSelection.light);
  });
}

({
  SettingsProjectionFixture source,
  RecordingSettingsIntents intents,
  SettingsBinding binding,
})
_settingsFixture({
  String appearanceId = AppearancePresetIds.licoSoda,
  String locale = 'system',
  String snapshotRoot = 'test-data/licoup/backups',
}) {
  final source = SettingsProjectionFixture(
    settingsProjectionFixture(
      appearanceId: appearanceId,
      locale: locale,
      snapshotRootPath: snapshotRoot,
    ),
  );
  final intents = RecordingSettingsIntents();
  return (
    source: source,
    intents: intents,
    binding: settingsBindingFixture(source: source, intents: intents),
  );
}

Future<void> _pumpSettings(
  WidgetTester tester,
  ({
    SettingsProjectionFixture source,
    RecordingSettingsIntents intents,
    SettingsBinding binding,
  })
  fixture, {
  Locale locale = const Locale('en'),
  double height = 900,
}) async {
  addTearDown(fixture.source.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          FixtureLayoutPresentationScope(child: child!),
      locale: locale,
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
        body: SizedBox(
          width: 980,
          height: height,
          child: SettingsPanel(
            binding: fixture.binding,
            layoutRegistry: buildFixtureLayoutRuntime().registry,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
