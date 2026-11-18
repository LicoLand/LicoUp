import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_presentation_source.dart';

/// The production composition installs the prepared conversation path.
///
/// These cases bind the actual [ClientAppComposition] overrides into a
/// container, so a port that silently stays disabled - the failure a view
/// cannot distinguish from a slow preparation - fails here.
void main() {
  test(
    'the composition binds the prepared conversation port to its runtime',
    () async {
      final composition = ClientAppComposition(controller: ClientController());
      final container = ProviderContainer(
        overrides: composition.presentationOverrides,
      );
      addTearDown(() async {
        container.dispose();
        await composition.dispose();
      });

      final port = container.read(conversationMarkdownPortProvider);
      expect(
        port,
        isA<ConversationMarkdownPreparation>(),
        reason: 'an unbound port would leave every view on its own text',
      );
      final preparation = port as ConversationMarkdownPreparation;
      expect(
        preparation.runtime,
        same(container.read(presentationRuntimeProvider)),
        reason: 'the preparation owner shares the container runtime',
      );
      expect(preparation.disposed, isFalse);

      final position = preparation.publish(
        identity: 'composed-body',
        text: '# Title\n\nbody **bold**\n\n',
      );
      expect(position, isNotNull);
      final value = await _waitForValue(preparation, 'composed-body');
      expect(
        value.blocks.map((block) => block.value.contentHash).toList(),
        parseMessageMarkdownBlocks(
          '# Title\n\nbody **bold**\n\n',
        ).map((block) => block.contentHash).toList(),
        reason: 'the composition prepares through the real runtime and workers',
      );
      expect(
        container
            .read(presentationRuntimeProvider)
            .current(conversationMarkdownFieldGroupFor('composed-body')),
        isNotNull,
        reason: 'the admitted body is visible to the container scope',
      );

      container.dispose();
      expect(
        preparation.disposed,
        isTrue,
        reason: 'the preparation owner and its workers end with the container',
      );
    },
  );

  test(
    'a container without the composition override keeps the disabled port',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(conversationMarkdownPortProvider),
        isA<DisabledConversationMarkdownPort>(),
      );
      expect(
        container
            .read(conversationMarkdownPortProvider)
            .publish(identity: 'unwired', text: 'body\n\n'),
        isNull,
      );
    },
  );
}

Future<PreparedValue<MessageMarkdownBlock>> _waitForValue(
  ConversationMarkdownPreparation preparation,
  String identity, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = preparation.valueFor(identity);
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  final failure = preparation.failureFor(identity);
  fail(
    'no prepared value for $identity within ${timeout.inSeconds}s'
    '${failure == null ? '' : ' (failure: $failure)'}',
  );
}
