import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';

import '../presentation/conversation_markdown/prepared_message_markdown_harness.dart';
import '../support/bundled_font_loader.dart';
import 'support/participant_flow_test_support.dart';

void main() {
  testWidgets('user bubble inline code matches macOS golden baseline', (
    tester,
  ) async {
    await loadBundledVisualFonts();
    final runtime = PresentationRuntime();
    final preparation = conversationMarkdownTestPreparation(runtime: runtime);
    addTearDown(() {
      unawaited(preparation.dispose());
      runtime.dispose();
    });
    await pumpParticipantFlowTest(tester, [
      participantFlowMessageItem(
        'k1',
        'assistant',
        'see `agent-thing` here',
        participantFlowAt(10, 0),
      ),
      participantFlowMessageItem(
        'k2',
        'user',
        '**Changed** `path/to/output`: refresh `sha256:abc` complete',
        participantFlowAt(10, 1),
      ),
    ], preparation: preparation);

    await waitForConversationMarkdown(
      tester,
      () => preparedInlineCodeSpanVisible(tester, 'path/to/output'),
      description: 'the prepared user code span',
    );

    await expectLater(
      find.byType(MessagingUserBubbleGlass),
      matchesGoldenFile('goldens/user_bubble_inline_code.png'),
    );
    expect(tester.takeException(), isNull);
    await finishConversationMarkdownTest(tester, preparation, runtime);
  });
}
