import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/settings/ui/archived_conversations_settings_section.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_effect.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

import 'fixtures/settings_binding_fixture.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('searches and dispatches restore for an archived conversation', (
    tester,
  ) async {
    final archived = const ArchivedConversationProjection(
      id: 'conversation:archived-group',
      title: '设计评审群',
      isGroup: true,
      membershipCount: 3,
      updatedAtUnixMs: 1767234600000,
    );
    final source = SettingsProjectionFixture(
      settingsProjectionFixture(archived: [archived]),
    );
    final intents = RecordingSettingsIntents();
    final effects = RecordingSettingsEffects();
    final binding = settingsBindingFixture(
      source: source,
      intents: intents,
      effects: effects,
    );
    addTearDown(source.dispose);
    addTearDown(effects.dispose);

    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
          body: SingleChildScrollView(
            child: ArchivedConversationsSettingsSection(binding: binding),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('已归档对话'), findsOneWidget);
    expect(find.text('设计评审群'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && widget.data?.startsWith('3 位成员 ·') == true,
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
    expect(
      intents.values.whereType<RefreshArchivedConversations>(),
      hasLength(1),
    );

    await tester.enterText(
      find.byKey(const Key('archived-conversation-search')),
      '不存在',
    );
    await tester.pump();
    expect(find.text('没有匹配的已归档对话'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('archived-conversation-search')),
      '设计',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '恢复'));
    await tester.pump();
    final restore = intents.values
        .whereType<RestoreArchivedConversation>()
        .single;
    expect(restore.conversationId, archived.id);

    source.publish(settingsProjectionFixture());
    effects.emit(
      ArchivedConversationRestoreCompleted(
        conversationId: archived.id,
        restored: true,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('archived-conversation-list')), findsNothing);
    expect(find.textContaining('设计评审群'), findsOneWidget);
  });
}
