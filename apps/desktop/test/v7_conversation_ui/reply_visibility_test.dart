import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/product_acceptance/conversation_reply_visibility.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks/disclosures.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';

void main() {
  const reply = AgentConversationMessage(
    id: 'reply-current',
    role: 'assistant',
    text: 'Current reply',
    createdAt: '2030-01-01T00:00:00Z',
  );

  Widget body({String text = 'Current reply'}) =>
      AgentConversationMessageContent(
        identity: agentConversationMarkdownIdentity(reply),
        data: text,
        foreground: Colors.black,
        accent: Colors.blue,
        codeBackground: Colors.white,
        blockBackground: Colors.white,
        borderColor: Colors.grey,
        renderStyle: const MessageMarkdownStyle(),
      );

  Future<void> mount(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  bool visible(WidgetTester tester) =>
      hasVisibleConversationReply(tester.binding.rootElement!, const [reply]);

  testWidgets('requires the current reply body to reach the rendered view', (
    tester,
  ) async {
    await mount(tester, const Text('Current reply'));
    expect(visible(tester), isFalse);
    await mount(tester, body(text: 'Previous reply'));
    expect(visible(tester), isFalse);
    await mount(tester, body());
    expect(visible(tester), isTrue);
  });

  testWidgets('hidden and clipped replies do not count as visible output', (
    tester,
  ) async {
    await mount(tester, Offstage(child: body()));
    expect(visible(tester), isFalse);
    await mount(tester, Opacity(opacity: 0, child: body()));
    expect(visible(tester), isFalse);
    await mount(
      tester,
      SizedBox(
        height: 100,
        child: SingleChildScrollView(
          child: Column(children: [const SizedBox(height: 200), body()]),
        ),
      ),
    );
    expect(visible(tester), isFalse);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(visible(tester), isTrue);
  });

  testWidgets('a disclosure label cannot stand in for a reply body', (
    tester,
  ) async {
    const metadata = AgentConversationMessage(
      id: 'reply-current',
      role: 'assistant',
      text: '<additional_metadata>Hidden detail</additional_metadata>',
      createdAt: '2030-01-01T00:00:00Z',
    );
    await mount(tester, body(text: metadata.text));
    expect(find.byType(RichText), findsWidgets);
    expect(
      hasVisibleConversationReply(tester.binding.rootElement!, const [
        metadata,
      ]),
      isFalse,
    );
  });
}
