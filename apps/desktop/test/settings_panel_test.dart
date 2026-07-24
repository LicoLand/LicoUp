import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel.dart';
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

      expect(find.text('外观方案'), findsOneWidget);
      expect(find.byIcon(Icons.palette_outlined), findsWidgets);
      expect(find.text('选择外观'), findsNothing);
      expect(find.text('选择外框'), findsNothing);
      expect(find.text('下一个'), findsNothing);
      expect(find.bySemanticsLabel('界面布局'), findsOneWidget);
      expect(find.text('正在加载布局…'), findsOneWidget);
      expect(find.text('语言'), findsOneWidget);
      expect(find.byIcon(Icons.language_outlined), findsWidgets);
      expect(find.text('跟随系统'), findsWidgets);
    },
  );

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
      scrollable: find.byType(Scrollable).first,
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
}
