import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/frontend/features/settings/ui/archived_conversations_settings_section.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('searches and restores an archived canonical conversation', (
    tester,
  ) async {
    final runner = _ArchivedConversationRunner();
    final controller = ClientConversationController(runner: runner);
    addTearDown(controller.dispose);

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
            child: ArchivedConversationsSettingsSection(controller: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已归档对话'), findsOneWidget);
    expect(find.text('设计评审群'), findsOneWidget);
    expect(find.byKey(const Key('archived-conversation-list')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && widget.data?.startsWith('3 位成员 ·') == true,
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, '恢复'), findsOneWidget);

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
    await tester.pumpAndSettle();

    final restore = runner.requests.singleWhere(
      (request) => request['action'] == 'conversation.archive',
    );
    expect(restore['conversationId'], 'conversation:archived-group');
    expect(restore['archived'], isFalse);
    expect(controller.archivedConversations, isEmpty);
    expect(
      controller.groupConversations.single.id,
      'conversation:archived-group',
    );
    expect(find.byKey(const Key('archived-conversation-list')), findsNothing);
    expect(find.text('没有匹配的已归档对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _ArchivedConversationRunner implements AgentCommandRunner {
  final requests = <Map<String, dynamic>>[];
  bool archived = true;

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    requests.add(request);
    if (request['action'] == 'conversation.archive') {
      archived = request['archived'] == true;
    }
    return {
      'ok': true,
      'result': switch (request['action']) {
        'conversation.list' => [
          if (!archived || request['includeArchived'] == true)
            {
              'id': 'conversation:archived-group',
              'title': '设计评审群',
              'archived': archived,
              'pinned': false,
              'isGroup': true,
              'revision': 2,
              'updatedAtUnixMs': DateTime(
                2026,
                1,
                1,
                10,
                30,
              ).millisecondsSinceEpoch,
              'membershipCount': 3,
              'eventCount': 8,
            },
        ],
        _ => <String, dynamic>{},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnimplementedError();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
