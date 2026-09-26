import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_presentation_source.dart';

/// The conversation prepared pipeline over the real runtime, engine, and
/// workers. Every case here is synthetic and local: no account, network, or
/// product fixture is involved.
void main() {
  late PresentationRuntime runtime;
  late ConversationMarkdownPreparation preparation;

  setUp(() {
    runtime = PresentationRuntime();
    preparation = ConversationMarkdownPreparation(
      runtime: runtime,
      engineFactory: _spawnEngine,
    );
  });

  tearDown(() async {
    await preparation.dispose();
    runtime.dispose();
  });

  ResourceFieldGroup<PreparedValue<MessageMarkdownBlock>> preparedField(
    String identity,
  ) => ResourceFieldGroup<PreparedValue<MessageMarkdownBlock>>(
    resource: conversationMarkdownFieldGroupFor(identity).resource,
    name: conversationMarkdownPreparedField,
  );

  test('one revision is decomposed off-thread and installed prepared', () async {
    const text = '# Title\n\nbody **bold** and `code`\n\n- one\n- two\n';
    final position = preparation.publish(identity: 'm1', text: text);
    expect(position, isNotNull);
    expect(position!.isInitial, isTrue, reason: 'the first revision is v0');

    final value = await _waitForValue(preparation, 'm1');
    final reference = parseMessageMarkdownBlocks(text);
    expect(
      value.blocks.map((block) => block.value.contentHash).toList(),
      reference.map((block) => block.contentHash).toList(),
      reason: 'the prepared blocks equal the full-document reference parse',
    );
    expect(value.position, position);
    expect(
      preparation.workerFor('m1')?.runsInCallerIsolate,
      isFalse,
      reason: 'the scan ran on a real worker isolate',
    );
    expect(
      preparation.workerFor('m1')?.isolateDebugName,
      startsWith('licoup-preparation'),
    );
    expect(preparation.planFor('m1')?.trigger, PreparationTrigger.initial);
    expect(preparation.failureFor('m1'), isNull);

    // The install carries the source's consistency group, so the group
    // identity survives from the source read to the prepared value while its
    // changed entry names the field the preparation installs.
    final installed = runtime
        .preparedDisplay<PreparedValue<MessageMarkdownBlock>>()
        .current(preparedField('m1'));
    expect(installed, isNotNull);
    final group = installed!.request.consistencyGroup;
    expect(group, isNotNull);
    expect(group!.position, position);
    expect(group.id, ConsistencyGroupId('conversation-markdown:m1'));
    expect(group.affects(preparedField('m1')), isTrue);
  });

  test('an append reuses frozen blocks and parses only what changed', () async {
    const first = '# Title\n\nintro text\n\nalpha\n\n';
    preparation.publish(identity: 'm2', text: first);
    final firstValue = await _waitForValue(preparation, 'm2');

    const grown = '# Title\n\nintro text\n\nalpha\n\nbeta\n\n';
    preparation.publish(identity: 'm2', text: grown);
    final grownValue = await _waitForValue(
      preparation,
      'm2',
      differentFrom: firstValue,
    );

    expect(
      identical(firstValue.blocks.first.value, grownValue.blocks.first.value),
      isTrue,
      reason: 'an unchanged sealed block reuses the identical payload',
    );
    expect(preparation.planFor('m2')?.reusableBlocks, isNotEmpty);
    expect(
      preparation.planFor('m2')?.blocksToParse,
      contains(grownValue.blocks.last.id),
      reason: 'the appended block is parsed',
    );
    final reference = parseMessageMarkdownBlocks(grown);
    expect(
      grownValue.blocks.map((block) => block.value.contentHash).toList(),
      reference.map((block) => block.contentHash).toList(),
    );
    expect(
      preparation.preparationsFor('m2'),
      2,
      reason: 'one attempt per real revision',
    );
  });

  test('publishing the revision already held prepares nothing', () async {
    const text = 'stable body\n\n';
    preparation.publish(identity: 'm3', text: text);
    await _waitForValue(preparation, 'm3');
    final position = preparation.positionFor('m3');
    preparation.publish(identity: 'm3', text: text);
    expect(preparation.positionFor('m3'), position);
    expect(preparation.preparationsFor('m3'), 1);
  });

  test('a changed definition re-parses its dependent block', () async {
    const first = '[site]: https://one.test\n\nsee [site] here\n\n';
    preparation.publish(identity: 'm4', text: first);
    final firstValue = await _waitForValue(preparation, 'm4');
    expect(
      firstValue.blocks[1].block.references,
      isNotEmpty,
      reason: 'the second block reads the link definition',
    );

    const changed = '[site]: https://two.test\n\nsee [site] here\n\n';
    preparation.publish(identity: 'm4', text: changed);
    await _waitForValue(preparation, 'm4', differentFrom: firstValue);
    expect(
      preparation.planFor('m4')?.trigger,
      PreparationTrigger.blockDependencyChanged,
    );
    expect(
      preparation.planFor('m4')?.blocksToParse,
      containsAll(<BlockId>[
        firstValue.blocks[0].id,
        firstValue.blocks[1].id,
      ]),
      reason: 'the definition and the block that cites it re-parse together',
    );
  });

  test('retire withdraws the visible value and the source at once', () async {
    preparation.publish(identity: 'm5', text: 'withdraw me\n\n');
    final value = await _waitForValue(preparation, 'm5');
    expect(value.blocks, isNotEmpty);

    preparation.retire('m5');
    expect(preparation.valueFor('m5'), isNull);
    expect(registrySource(preparation, 'm5')?.retired, isTrue);
    expect(registrySource(preparation, 'm5')?.current.text, isEmpty);
    expect(
      runtime.preparedDisplay<PreparedValue<MessageMarkdownBlock>>().current(
        preparedField('m5'),
      ),
      isNull,
      reason: 'the runtime stops showing the revoked prepared value',
    );
    expect(runtime.current(conversationMarkdownFieldGroupFor('m5')), isNull);
  });

  test('a retired identity comes back in a new epoch', () async {
    preparation.publish(identity: 'm6', text: 'first incarnation\n\n');
    final first = await _waitForValue(preparation, 'm6');
    preparation.retire('m6');

    preparation.publish(identity: 'm6', text: 'second incarnation\n\n');
    final second = await _waitForValue(preparation, 'm6');
    expect(
      second.position.epoch,
      isNot(first.position.epoch),
      reason: 'a rebuilt source opens a new epoch',
    );
    expect(
      second.blocks.single.value.text,
      'second incarnation',
      reason: 'only the new incarnation is visible',
    );
  });

  test('retention bounds unwatched bodies', () async {
    preparation = ConversationMarkdownPreparation(
      runtime: runtime,
      engineFactory: _spawnEngine,
      maxRetainedBodies: 2,
    );
    preparation.publish(identity: 'a', text: 'body a\n\n');
    await _waitForValue(preparation, 'a');
    preparation.publish(identity: 'b', text: 'body b\n\n');
    await _waitForValue(preparation, 'b');
    preparation.publish(identity: 'c', text: 'body c\n\n');
    await _waitForValue(preparation, 'c');

    expect(preparation.valueFor('a'), isNull, reason: 'oldest body retired');
    expect(preparation.valueFor('b'), isNotNull);
    expect(preparation.valueFor('c'), isNotNull);
    expect(registrySource(preparation, 'a')?.retired, isTrue);
    expect(registrySource(preparation, 'a')?.current.text, isEmpty);
  });

  test('a watched body is never evicted by retention', () async {
    preparation = ConversationMarkdownPreparation(
      runtime: runtime,
      engineFactory: _spawnEngine,
      maxRetainedBodies: 2,
    );
    final events = <ConversationMarkdownBodyState>[];
    final releaseWatch = preparation.watch('watched', events.add);
    preparation.publish(identity: 'watched', text: 'watched body\n\n');
    await _waitForValue(preparation, 'watched');
    preparation.publish(identity: 'other-0', text: 'other 0\n\n');
    await _waitForValue(preparation, 'other-0');
    preparation.publish(identity: 'other-1', text: 'other 1\n\n');
    await _waitForValue(preparation, 'other-1');
    expect(
      preparation.valueFor('watched'),
      isNotNull,
      reason: 'a watched body keeps its prepared value',
    );
    expect(preparation.valueFor('other-0'), isNull);
    expect(preparation.valueFor('other-1'), isNotNull);
    expect(events, isNotEmpty);
    releaseWatch();
  });

  test('authority withdrawal is recorded and a repeated read never re-enters', () async {
    preparation.publish(identity: 'rev', text: 'first body\n\n');
    await _waitForValue(preparation, 'rev');
    expect(preparation.stateFor('rev'), isA<ConversationMarkdownInstalled>());
    final preparations = preparation.preparationsFor('rev');

    // The application withdraws authority over the body.
    runtime.revoke(conversationMarkdownFieldGroupFor('rev').resource);
    expect(
      preparation.stateFor('rev'),
      isA<ConversationMarkdownWithdrawn>().having(
        (state) => state.reason,
        'reason',
        ConversationMarkdownWithdrawal.revoked,
      ),
    );
    expect(preparation.valueFor('rev'), isNull);
    expect(preparation.positionFor('rev'), isNotNull);

    // Repeating the withdrawn revision is not a new read.
    preparation.publish(identity: 'rev', text: 'first body\n\n');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(preparation.stateFor('rev'), isA<ConversationMarkdownWithdrawn>());
    expect(
      preparation.preparationsFor('rev'),
      preparations,
      reason: 'a repeated read of the withdrawn revision never re-enters',
    );

    // A later controlled revision opens a fresh incarnation.
    preparation.publish(identity: 'rev', text: 'second body\n\n');
    final fresh = await _waitForValue(preparation, 'rev');
    expect(preparation.stateFor('rev'), isA<ConversationMarkdownInstalled>());
    expect(fresh.blocks.single.value.text, 'second body');
    expect(
      runtime.current(conversationMarkdownFieldGroupFor('rev')),
      isNotNull,
      reason: 'the fresh incarnation is admitted',
    );
  });

  test('a cache retire reports its own reason and allows a fresh read', () async {
    preparation.publish(identity: 'cache', text: 'cached body\n\n');
    await _waitForValue(preparation, 'cache');

    preparation.retire('cache');
    expect(
      preparation.stateFor('cache'),
      isA<ConversationMarkdownWithdrawn>().having(
        (state) => state.reason,
        'reason',
        ConversationMarkdownWithdrawal.retired,
      ),
    );

    // A retired body is a bounded-cache decision, not withdrawn authority: the
    // same text is a legitimate fresh read.
    preparation.publish(identity: 'cache', text: 'cached body\n\n');
    final value = await _waitForValue(preparation, 'cache');
    expect(preparation.stateFor('cache'), isA<ConversationMarkdownInstalled>());
    expect(value.blocks.single.value.text, 'cached body');
  });

  test('a release stops the pipeline and its workers', () async {
    preparation.publish(identity: 'm7', text: 'body\n\n');
    await _waitForValue(preparation, 'm7');
    await preparation.dispose();
    expect(preparation.disposed, isTrue);
    expect(preparation.valueFor('m7'), isNull);
    expect(preparation.publish(identity: 'm8', text: 'later\n\n'), isNull);
  });
}

Future<MarkdownPreparationEngine> _spawnEngine() async {
  final pool = await PreparationWorkerPool.spawn(
    name: 'conversation-markdown-test',
    operations: MarkdownPreparationEngine.workerOperations,
    workers: 2,
  );
  return MarkdownPreparationEngine(
    workers: pool,
    cache: MarkdownPreparationCache(),
  );
}

ConversationMarkdownSource? registrySource(
  ConversationMarkdownPreparation preparation,
  String identity,
) => preparation.registry.sourceFor(identity);

Future<PreparedValue<MessageMarkdownBlock>> _waitForValue(
  ConversationMarkdownPreparation preparation,
  String identity, {
  PreparedValue<MessageMarkdownBlock>? differentFrom,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = preparation.valueFor(identity);
    if (value != null && !identical(value, differentFrom)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  final failure = preparation.failureFor(identity);
  fail(
    'no prepared value for $identity within ${timeout.inSeconds}s'
    '${failure == null ? '' : ' (failure: $failure)'}',
  );
}
