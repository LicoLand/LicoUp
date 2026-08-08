import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
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
      expect(find.text('语言'), findsOneWidget);
      expect(find.byIcon(Icons.language_outlined), findsWidgets);
      expect(find.text('跟随系统'), findsNWidgets(2));
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
        matching: find.text('Conversation Archive Directory'),
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
    expect(find.text('Conversation Archive Directory'), findsOneWidget);
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

      await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final offeredValues = tester
          .widgetList<DropdownMenuItem<String>>(
            find.byType(DropdownMenuItem<String>),
          )
          .map((item) => item.value)
          .toSet();
      expect(
        offeredValues.intersection(const {'default-system', 'lico-soda'}),
        const {'lico-soda'},
      );
      expect(offeredValues, isNot(contains('lico-soda-light')));
      expect(find.text('LicoUp Dark'), findsWidgets);
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
            height: 460,
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
    expect(indexForeground('Appearance'), colors.textOnPrimary);
    final selectedContainer = tester
        .widgetList<Container>(
          find.ancestor(
            of: find.text('Appearance'),
            matching: find.byType(Container),
          ),
        )
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .where((decoration) => decoration.color == colors.primary);
    expect(selectedContainer, isNotEmpty);

    // Scroll to the bottom: the spy selection follows into the diagnostics
    // section (the last one, with the resource usage card), away from
    // Appearance.
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('settings-content-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Resource Usage'),
      480,
      scrollable: scrollable,
    );
    await tester.pump();
    expect(indexForeground('Diagnostics'), colors.textOnPrimary);
    expect(indexForeground('Storage'), isNot(colors.textOnPrimary));
    expect(indexForeground('Appearance'), isNot(colors.textOnPrimary));

    // Clicking the first sidebar entry animates the content back to its
    // section, and the selection follows.
    await tester.tap(find.text('Appearance').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(indexForeground('Appearance'), colors.textOnPrimary);
    expect(tester.takeException(), isNull);
  });
}
