import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

/// One message entity in the integration assembly.
final class TestMessage {
  const TestMessage({
    required this.id,
    required this.author,
    required this.text,
    this.isStreaming = false,
  });

  final String id;
  final String author;
  final String text;
  final bool isStreaming;
}

class ConversationNotifier extends Notifier<List<TestMessage>> {
  @override
  List<TestMessage> build() => [
    const TestMessage(
      id: 'msg-1',
      author: 'user',
      text: 'Hello, what can you do?',
    ),
    const TestMessage(
      id: 'msg-2',
      author: 'assistant',
      text:
          '# Capabilities\n\nI can help you build Flutter apps.\n\n```dart\nvoid code() {}\n```',
    ),
  ];

  void addUserMessage(String text) {
    final newId = 'msg-${state.length + 1}';
    state = [...state, TestMessage(id: newId, author: 'user', text: text)];
  }

  void appendStreamingTokens(String messageId, String additionalTokens) {
    state = [
      for (final m in state)
        if (m.id == messageId)
          TestMessage(
            id: m.id,
            author: m.author,
            text: '${m.text}$additionalTokens',
            isStreaming: true,
          )
        else
          m,
    ];
  }
}

final conversationProvider =
    NotifierProvider<ConversationNotifier, List<TestMessage>>(
      ConversationNotifier.new,
    );

class SessionStatusNotifier extends Notifier<AsyncValue<String>> {
  @override
  AsyncValue<String> build() =>
      const AsyncData<String>('Session active: Project LicoUp');

  void revoke() => state = const AsyncData<String>('REVOKED');
}

final sessionStatusProvider =
    NotifierProvider<SessionStatusNotifier, AsyncValue<String>>(
      SessionStatusNotifier.new,
    );

void main() {
  testWidgets(
    'F01.4e Assembly: Region, AsyncRegion, CollectionView, StreamingText, and InputField',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  // 1. Header with AsyncRegion for session status
                  AsyncRegion<String, void Function()>(
                    source: sessionStatusProvider,
                    actions: () {},
                    isRevoked: (data) => data == 'REVOKED',
                    revoked: (context, actions) => Container(
                      key: const ValueKey('revocation-banner'),
                      color: Colors.red,
                      padding: const EdgeInsets.all(8),
                      child: const Text(
                        'Access Revoked',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    data: (context, data, actions) => Container(
                      key: const ValueKey('session-banner'),
                      color: Colors.blueGrey,
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        data,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),

                  // 2. Transcript with CollectionView + Region + StreamingText
                  Expanded(
                    child: Consumer(
                      builder: (context, ref, child) {
                        final messages = ref.watch(conversationProvider);
                        // Reverse order: newest at index 0
                        final reversed = messages.reversed.toList();

                        return CollectionView<TestMessage>(
                          reverse: true,
                          items: reversed,
                          itemKey: (msg) => msg.id,
                          itemBuilder: (context, msg, index) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 6,
                                horizontal: 12,
                              ),
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        msg.author.toUpperCase(),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      StreamingText(
                                        document: msg.text,
                                        isStreaming: msg.isStreaming,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),

                  // 3. Composer with Region + InputField
                  Consumer(
                    builder: (context, ref, child) {
                      return Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: InputField(
                          hintText: 'Ask a question...',
                          onSubmit: (text) {
                            ref
                                .read(conversationProvider.notifier)
                                .addUserMessage(text);
                          },
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Initial state check
      expect(find.byKey(const ValueKey('session-banner')), findsOneWidget);
      expect(find.text('Session active: Project LicoUp'), findsOneWidget);
      expect(find.text('Capabilities'), findsOneWidget);
      expect(find.text('Hello, what can you do?'), findsOneWidget);

      // Enter new message via InputField
      await tester.enterText(find.byType(TextField), 'Implement F01.4 now');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // New user message appears in CollectionView
      expect(find.text('Implement F01.4 now'), findsOneWidget);

      // Simulate assistant streaming response tokens
      final element = tester.element(find.byType(Scaffold));
      final container = ProviderScope.containerOf(element);
      container
          .read(conversationProvider.notifier)
          .appendStreamingTokens('msg-3', ' - streaming verification');
      await tester.pump();

      expect(
        find.text('Implement F01.4 now - streaming verification'),
        findsOneWidget,
      );

      // Revoke session: AsyncRegion must IMMEDIATELY show revocation banner and drop session banner
      container.read(sessionStatusProvider.notifier).revoke();
      await tester.pump();

      expect(find.byKey(const ValueKey('revocation-banner')), findsOneWidget);
      expect(find.text('Access Revoked'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-banner')), findsNothing);
    },
  );
}
