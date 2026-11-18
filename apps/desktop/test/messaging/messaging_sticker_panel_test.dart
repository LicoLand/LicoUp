import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_message_group.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_sticker_panel.dart';

import 'support/messaging_sticker_test_support.dart';

void main() {
  test('wire codes round-trip between composer and transcript', () {
    expect(stickerWireCode('celebrate'), '[sticker:lico-celebrate]');
    expect(
      stickerExpressionIdFromCode('[sticker:lico-celebrate]'),
      'celebrate',
    );
    expect(stickerExpressionIdFromCode('[sticker:celebrate]'), 'celebrate');
    expect(stickerExpressionIdFromCode('[sticker:lico-nope]'), isNull);
    expect(stickerExpressionIdFromCode('plain text'), isNull);
  });

  test('preview renders the localized sticker name, not the code', () {
    expect(
      conversationMessagePreviewText('[sticker:lico-celebrate]'),
      '[sticker: Celebrate]',
    );
    expect(
      conversationMessagePreviewText('[sticker:lico-celebrate]', chinese: true),
      '[表情：庆祝]',
    );
    expect(conversationMessagePreviewText('hello'), 'hello');
  });

  testWidgets('composer smiley opens the sticker panel in demo order', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MessagingStickerTestApp(child: MessagingStickerComposerHost()),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('agent-conversation-composer-sticker')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('messaging-sticker-panel')), findsOneWidget);
    expect(find.byKey(const Key('sticker-cell-happy')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('sticker-cell-neutral')),
      80,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.byKey(const Key('sticker-cell-neutral')), findsOneWidget);
  });

  testWidgets('tapping a sticker sends the stable wire code', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MessagingStickerTestApp(child: MessagingStickerComposerHost(sent: sent)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('agent-conversation-composer-sticker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sticker-cell-celebrate')));
    await tester.pumpAndSettle();

    expect(sent, ['[sticker:lico-celebrate]']);
    expect(find.byKey(const Key('messaging-sticker-panel')), findsNothing);
    // The pick lands on the recent tab.
    await tester.tap(
      find.byKey(const Key('agent-conversation-composer-sticker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recent'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sticker-recent-empty')), findsNothing);
  });

  testWidgets('emoji tab inserts the glyph into the draft', (tester) async {
    await tester.pumpWidget(
      const MessagingStickerTestApp(child: MessagingStickerComposerHost()),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('agent-conversation-composer-sticker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emoji'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('😀'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '😀');
  });

  testWidgets('a sticker message renders the expression, not raw code', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MessagingStickerTestApp(
        child: MessagingMessageGroup(
          authorIsUser: true,
          participantLabel: 'You',
          participantRole: 'user',
          participantTarget: null,
          messages: [
            AgentConversationMessage(
              id: 's1',
              role: 'user',
              text: '[sticker:lico-celebrate]',
              createdAt: DateTime(2026, 1, 1, 10).toIso8601String(),
            ),
            AgentConversationMessage(
              id: 't1',
              role: 'user',
              text: 'plain text stays text',
              createdAt: DateTime(2026, 1, 1, 10, 1).toIso8601String(),
            ),
          ],
          target: messagingStickerTestTarget,
          adapter: AgentRenderAdapter.fallback(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('messaging-sticker-message')), findsOneWidget);
    expect(find.byKey(const Key('messaging-sticker-note')), findsNothing);
    expect(find.text('[sticker:lico-celebrate]'), findsNothing);
    expect(find.text('plain text stays text'), findsOneWidget);
    expect(find.byKey(const Key('messaging-message-bubble')), findsNWidgets(1));
  });
}
