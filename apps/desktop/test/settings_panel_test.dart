import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel_widgets.dart';
import 'package:licoup/src/frontend/shared/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('language picker switches and persists the application locale', (
    tester,
  ) async {
    final preferences = _SettingsPresentationPreferencesRepository();
    final controller = ClientController(
      agentService: FakeAgentService(),
      presentationPreferencesRepository: preferences,
    );
    addTearDown(controller.dispose);
    await controller.layoutManager.initialize();
    controller.localePreference = LocalePreference.chinese;

    await tester.pumpWidget(
      ValueListenableBuilder<int>(
        valueListenable: controller.appPresentationListenable,
        builder: (context, _, _) {
          return MaterialApp(
            builder: (context, child) =>
                FixtureLayoutPresentationScope(child: child!),
            locale: LicoStrings.localeForPreference(
              controller.localePreference,
            ),
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
                width: 1280,
                height: 900,
                child: SettingsPanel(controller: controller),
              ),
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('语言'), findsOneWidget);
    expect(find.text('通用'), findsWidgets);
    expect(find.byKey(const Key('settings-locale-dropdown')), findsOneWidget);
    expect(find.byKey(const Key('settings-locale-list')), findsNothing);
    expect(find.byKey(const Key('settings-locale-toggle')), findsNothing);
    expect(find.byType(SettingsDropdownList<String>), findsWidgets);
    final localeDropdown = tester.widget<SettingsDropdownList<String>>(
      find.byKey(const Key('settings-locale-dropdown')),
    );
    expect(localeDropdown.locked, isFalse);
    expect(localeDropdown.enabled, isTrue);
    await tester.tap(find.byKey(const Key('settings-locale-dropdown')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('系统'), findsOneWidget);
    expect(find.text('中文'), findsWidgets);
    expect(find.text('English'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-locale-en')).last);
    await tester.pumpAndSettle();

    expect(controller.localePreference, LocalePreference.english);
    expect(preferences.value.localePreference, LocalePreference.english);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('语言'), findsNothing);
  });

  testWidgets(
    'settings selects appearance and language without duplicate labels',
    (tester) async {
      final controller = ClientController(agentService: FakeAgentService());
      addTearDown(controller.dispose);
      controller.localePreference = LocalePreference.system;

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
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: SizedBox(
              width: 980,
              height: 1400,
              child: SettingsPanel(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('外观预设'), findsOneWidget);
      expect(find.byIcon(Icons.palette_outlined), findsWidgets);
      expect(find.text('选择外观'), findsNothing);
      expect(find.text('选择外框'), findsNothing);
      expect(find.text('下一个'), findsNothing);
      expect(find.bySemanticsLabel('界面布局'), findsOneWidget);
      expect(find.text('正在加载布局…'), findsOneWidget);
      expect(find.text('通用'), findsWidgets);
      expect(find.text('语言'), findsOneWidget);
      expect(find.byIcon(Icons.language_outlined), findsWidgets);
      expect(find.byKey(const Key('settings-locale-dropdown')), findsOneWidget);
      expect(
        find.byKey(const Key('settings-appearance-dropdown')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings-locale-list')), findsNothing);
      expect(find.byKey(const Key('settings-locale-toggle')), findsNothing);
      final dropdowns = tester
          .widgetList<SettingsDropdownList<String>>(
            find.byType(SettingsDropdownList<String>),
          )
          .toList();
      expect(dropdowns, hasLength(2));
      expect(
        dropdowns.map((dropdown) => dropdown.locked).toSet(),
        equals({true, false}),
      );
      expect(find.text('跟随系统'), findsOneWidget);
      expect(find.text('明亮'), findsOneWidget);
      expect(find.text('暗黑'), findsOneWidget);
      expect(find.text('明暗模式'), findsOneWidget);
    },
  );

  testWidgets('appearance day night toggle row invokes callback', (
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
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 980,
            child: StatefulBuilder(
              builder: (context, setState) {
                return SettingsDayNightToggleRow(
                  selection: selection,
                  onChanged: (value) => setState(() => selection = value),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('appearance-day-night-toggle')),
      findsOneWidget,
    );
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('明亮'), findsOneWidget);
    expect(find.text('暗黑'), findsOneWidget);

    final initialToggleWidth = tester
        .getSize(find.byKey(const Key('appearance-day-night-toggle')))
        .width;

    await tester.tap(find.text('明亮'));
    await tester.pump();
    expect(selection, AppearanceBrightnessSelection.light);

    await tester.tap(find.text('暗黑'));
    await tester.pump();
    expect(selection, AppearanceBrightnessSelection.dark);

    await tester.tap(find.text('跟随系统'));
    await tester.pump();
    expect(selection, AppearanceBrightnessSelection.system);

    final finalToggleWidth = tester
        .getSize(find.byKey(const Key('appearance-day-night-toggle')))
        .width;
    expect(finalToggleWidth, initialToggleWidth);
  });

  testWidgets('archive settings show paths with inline open icons', (
    tester,
  ) async {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);
    controller.snapshotRootController.text =
        'test-data/lico-up/native-conversation-snapshots';
    controller.conversationArchiveResult = {
      'documentCount': 729,
      'archiveRoot': 'test-data/lico-up/native-conversation-snapshots',
    };

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 980,
            height: 1400,
            child: SettingsPanel(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(PanelFrame), findsNothing);
    expect(find.text('Choose Appearance'), findsNothing);
    expect(find.text('Appearance Preset'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    expect(find.bySemanticsLabel('Interface Layout'), findsOneWidget);
    expect(find.text('Loading layouts…'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);

    final cards = find.byType(Card);
    await tester.scrollUntilVisible(
      find.descendant(
        of: cards,
        matching: find.text('LicoUp Backup Directory'),
      ),
      360,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('settings-content-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();

    expect(find.text('Archive'), findsNothing);
    expect(find.text('Archive directory'), findsNothing);
    expect(find.text('Conversation Archive Root'), findsNothing);
    expect(find.text('Conversation Archive Directory'), findsNothing);
    expect(find.text('Portable Data'), findsNothing);
    expect(find.text('LicoUp Data Directory'), findsOneWidget);
    expect(find.text('LicoUp Backup Directory'), findsOneWidget);
    expect(find.text('default'), findsNothing);
    expect(
      find.text('test-data/lico-up/native-conversation-snapshots'),
      findsWidgets,
    );
    expect(find.text('Open'), findsNothing);
    expect(find.byIcon(Icons.open_in_new_outlined), findsAtLeastNWidgets(1));
    expect(find.text('Keywords'), findsNothing);
    expect(find.text('729 records'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Archive'), findsNothing);
    expect(
      find.text(
        'Save the local client activity log without showing log contents in settings.',
      ),
      findsNothing,
    );
  });

  testWidgets(
    'appearance preset picker filters dark presets on dark platform',
    (tester) async {
      final controller = ClientController(agentService: FakeAgentService());
      addTearDown(controller.dispose);
      controller.appearancePresetId = 'lico-soda';

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(platformBrightness: Brightness.dark),
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
              body: SizedBox(
                width: 980,
                height: 460,
                child: SettingsPanel(controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('settings-appearance-dropdown')),
        findsOneWidget,
      );
      expect(find.text('LicoUp Dark'), findsOneWidget);
      expect(find.text('LicoUp Light'), findsNothing);
      final appearanceDropdown = tester.widget<SettingsDropdownList<String>>(
        find.byKey(const Key('settings-appearance-dropdown')),
      );
      expect(appearanceDropdown.locked, isTrue);
      expect(appearanceDropdown.enabled, isTrue);
      expect(
        appearanceDropdown.items.map((item) => item.value).toSet().intersection(
          const {'default-system', 'lico-soda', 'lico-soda-light'},
        ),
        const {'lico-soda'},
      );

      await tester.tap(find.byKey(const Key('settings-appearance-dropdown')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(controller.appearancePresetId, 'lico-soda');
      expect(find.text('LicoUp Light'), findsNothing);
      expect(find.text('LicoUp Dark'), findsOneWidget);
    },
  );

  testWidgets('settings index follows scroll and jumps back on tap', (
    tester,
  ) async {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
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
          body: SizedBox(
            width: 980,
            height: 720,
            child: SettingsPanel(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();

    final colors = tester.element(find.byType(SettingsPanel)).licoColors;
    Color? indexForeground(String label) {
      final candidates = tester
          .widgetList<Text>(find.text(label))
          .where((candidate) => candidate.style?.fontSize == 12.5)
          .toList();
      return candidates.isEmpty ? null : candidates.first.style?.color;
    }

    // Initially the first section is selected with the solid accent and a
    // dark foreground.
    expect(indexForeground('General'), colors.textOnPrimary);
    expect(indexForeground('Appearance'), isNot(colors.textOnPrimary));
    final selectedContainer = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('General'),
            matching: find.byType(Container),
          ),
        )
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .where((decoration) => decoration.color == colors.primary);
    expect(selectedContainer, isNotEmpty);

    // Scroll to the bottom: the spy selection follows into the archived
    // conversations section, away from Appearance.
    final contentScrollable = find
        .descendant(
          of: find.byKey(const Key('settings-content-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Archived conversations'),
      360,
      scrollable: contentScrollable,
    );
    await tester.drag(contentScrollable, const Offset(0, -240));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(indexForeground('General'), isNot(colors.textOnPrimary));
    expect(
      [
        indexForeground('Archived'),
        indexForeground('Diagnostics'),
        indexForeground('Storage'),
      ].contains(colors.textOnPrimary),
      isTrue,
    );

    // Clicking the first sidebar entry animates the content back to its
    // section, and the selection follows.
    await tester.tap(find.text('General').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(indexForeground('General'), colors.textOnPrimary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings sidebar lists sections in the canonical order', (
    tester,
  ) async {
    final controller = ClientController(agentService: FakeAgentService());
    addTearDown(controller.dispose);

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
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(
          body: SizedBox(
            width: 980,
            height: 1400,
            child: SettingsPanel(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();

    const expected = ['通用', '外观', '更新', '启动', '工具', '存储', '诊断', '归档'];
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .where((candidate) => candidate.style?.fontSize == 12.5)
        .map((candidate) => candidate.data)
        .whereType<String>()
        .toList();
    expect(labels, expected);
    expect(find.text('语言'), findsOneWidget);
    expect(find.byKey(const Key('settings-locale-dropdown')), findsOneWidget);
    expect(find.byKey(const Key('settings-locale-list')), findsNothing);
    expect(find.byKey(const Key('settings-locale-toggle')), findsNothing);
    expect(find.byKey(const Key('layout-selector-reset')), findsNothing);
    expect(find.text('恢复系统默认布局'), findsNothing);
  });
}

final class _SettingsPresentationPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences value = PresentationPreferences(
    layoutProfileId: LayoutProfileId.parse('dashboard'),
    appearancePresetId: 'lico-soda',
    localePreference: LocalePreference.chinese,
  );

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: value);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      value = value.copyWith(appearancePresetId: id);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      value = value.copyWith(layoutProfileId: id);

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => value = value.copyWith(localePreference: preference);
}
