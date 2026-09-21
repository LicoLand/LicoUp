import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/src/cache/markdown_preparation_cache.dart';
import 'package:presentation_runtime/src/preparation/markdown/markdown_preparation_engine.dart';
import 'package:presentation_runtime/src/preparation/markdown/message_markdown_decomposition.dart';
import 'package:presentation_runtime/src/preparation/markdown/message_markdown_models.dart';
import 'package:presentation_runtime/src/preparation/markdown/message_markdown_parser.dart';
import 'package:presentation_runtime/src/scheduling/preparation_cancellation.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker_pool.dart';
import 'package:test/test.dart';

const ResourceScope _scope = ResourceScope('v7-markdown');

ResourceKey _message(String id) => ResourceKey(scope: _scope, stableKey: id);

ResourceFieldGroup<PreparedValue<MessageMarkdownBlock>> _preparedField(
  ResourceKey resource,
) => ResourceFieldGroup(resource: resource, name: 'preparedBody');

SourcePosition _position(int version, {String epoch = 'epoch-a'}) =>
    SourcePosition(epoch: SourceEpoch(epoch), version: SourceVersion(version));

MessageMarkdownDecomposition _revise({
  required ResourceKey resource,
  required SourcePosition position,
  required String text,
  MessageMarkdownDecomposition? previous,
  MarkdownLabelReferenceResolver? resolveExternalLabel,
}) => decomposeMessageMarkdown(
  resource: resource,
  position: position,
  text: text,
  previous: previous,
  resolveExternalLabel: resolveExternalLabel,
);

MarkdownPreparationRequest _request(
  MessageMarkdownDecomposition revision, {
  int generation = 1,
  SyntaxConfig? syntaxConfig,
  ConsistencyGroup? consistencyGroup,
}) => MarkdownPreparationRequest(
  preparedField: _preparedField(revision.resource),
  revision: revision,
  generation: RequestGeneration(generation),
  syntaxConfig: syntaxConfig,
  consistencyGroup: consistencyGroup,
);

/// Compares prepared output with the full-document reference parser.
void _expectMatchesReference(
  MessageMarkdownDecomposition revision,
  PreparedValue<MessageMarkdownBlock> value,
) {
  final reference = parseMessageMarkdownBlocks(revision.text);
  expect(
    value.blocks.map((block) => block.value.contentHash).toList(),
    reference.map((block) => block.contentHash).toList(),
    reason: 'incremental output must equal the full parse of ${revision.text}',
  );
  expect(value.blockIds, hasLength(reference.length));
}

Future<MarkdownPreparationEngine> _engine({
  int capacityBytes = defaultMarkdownPreparationCacheBytes,
  int workers = 1,
  int yieldBudgetBytes = 64 * 1024,
  bool strictTextVerification = false,
}) async {
  final pool = await PreparationWorkerPool.spawn(
    name: 'markdown-test',
    operations: MarkdownPreparationEngine.workerOperations,
    workers: workers,
  );
  return MarkdownPreparationEngine(
    workers: pool,
    cache: MarkdownPreparationCache(capacityBytes: capacityBytes),
    yieldBudgetBytes: yieldBudgetBytes,
    strictTextVerification: strictTextVerification,
  );
}

void main() {
  test('a sealed block re-parses only when its own text changes', () async {
    final engine = await _engine();
    final resource = _message('append');
    final first = _revise(
      resource: resource,
      position: _position(1),
      text: '# Title\n\nintro text\n\nalpha\n\nbeta\n',
    );
    final firstOutcome = await engine.prepare(_request(first));

    expect(first.blocks, hasLength(4));
    expect(first.blocks.last.isSealed, isFalse, reason: 'open tail');
    expect(firstOutcome.parsedBlocks, 4);
    expect(firstOutcome.plan.trigger, PreparationTrigger.initial);
    expect(firstOutcome.plan.scope, PreparationScope.global);
    expect(firstOutcome.value.mutableTail, hasLength(1));
    _expectMatchesReference(first, firstOutcome.value);

    final second = _revise(
      resource: resource,
      position: _position(2),
      text: '# Title\n\nintro changed\n\nalpha\n\nbeta\n',
      previous: first,
    );
    final secondOutcome = await engine.prepare(_request(second));

    expect(second.blocks.first.id, first.blocks.first.id);
    expect(
      secondOutcome.parsedBlocks,
      2,
      reason: 'the edited block and the open tail',
    );
    expect(
      secondOutcome.plan.blocksToParse,
      containsAll(<BlockId>[second.blocks[1].id, second.blocks[3].id]),
    );
    expect(
      secondOutcome.plan.changedBlocks,
      contains(second.blocks[1].id),
      reason: 'an open block is always reported as changed',
    );
    expect(secondOutcome.plan.reusableBlocks, hasLength(2));
    expect(secondOutcome.plan.trigger, PreparationTrigger.blocksChanged);
    expect(secondOutcome.plan.scope, PreparationScope.incremental);
    expect(
      secondOutcome.plan.estimatedInputBytes,
      lessThan(second.text.length),
    );
    _expectMatchesReference(second, secondOutcome.value);

    // The reused blocks keep the identical prepared payload instances.
    expect(
      identical(
        secondOutcome.value.blocks.first.value,
        firstOutcome.value.blocks.first.value,
      ),
      isTrue,
    );

    final third = _revise(
      resource: resource,
      position: _position(3),
      text: '# Title\n\nintro changed\n\nalpha\n\nbeta\n\ngamma\n',
      previous: second,
    );
    final thirdOutcome = await engine.prepare(_request(third));
    expect(
      thirdOutcome.plan.changedBlocks,
      isNot(contains(third.blocks[1].id)),
    );
    expect(thirdOutcome.value.mutableTail, hasLength(1));
    _expectMatchesReference(third, thirdOutcome.value);

    await engine.workers.dispose();
  });

  test('an unchanged revision is reused with zero parses', () async {
    final engine = await _engine();
    final resource = _message('reuse');
    final revision = _revise(
      resource: resource,
      position: _position(1),
      text: 'one\n\ntwo\n\nthree\n',
    );
    final first = await engine.prepare(_request(revision));
    final second = await engine.prepare(_request(revision));

    expect(second.reusedExistingValue, isTrue);
    expect(second.plan.reusedValue, isTrue);
    expect(second.plan.requiresRePreparation, isFalse);
    expect(second.plan.trigger, isNull);
    expect(second.parsedBlocks, 0);
    expect(identical(second.value, first.value), isTrue);
    expect(identical(second.value.key, first.value.key), isTrue);
    await engine.workers.dispose();
  });

  test('an open fence stays in the mutable tail until it closes', () async {
    final engine = await _engine();
    final resource = _message('fence');
    final open = _revise(
      resource: resource,
      position: _position(1),
      text: '```dart\nint a = 1;\n',
    );
    expect(open.blocks.single.isSealed, isFalse);
    final openOutcome = await engine.prepare(_request(open));
    expect(openOutcome.value.immutablePrefix, isEmpty);
    expect(openOutcome.value.mutableTail, hasLength(1));
    _expectMatchesReference(open, openOutcome.value);

    final growing = _revise(
      resource: resource,
      position: _position(2),
      text: '```dart\nint a = 1;\nint b = 2;\n',
      previous: open,
    );
    final growingOutcome = await engine.prepare(_request(growing));
    expect(growingOutcome.parsedBlocks, 1);
    expect(growing.blocks.single.version.value, greaterThan(0));
    _expectMatchesReference(growing, growingOutcome.value);

    final closed = _revise(
      resource: resource,
      position: _position(3),
      text: '```dart\nint a = 1;\nint b = 2;\n```\n\nafter\n',
      previous: growing,
    );
    expect(closed.blocks.first.isSealed, isTrue);
    final closedOutcome = await engine.prepare(_request(closed));
    expect(closedOutcome.value.immutablePrefix, hasLength(1));
    expect(closedOutcome.value.mutableTail, hasLength(1));
    _expectMatchesReference(closed, closedOutcome.value);

    // A sealed fence is final: the next attempt parses nothing new.
    final afterOutcome = await engine.prepare(_request(closed));
    expect(afterOutcome.reusedExistingValue, isTrue);
    await engine.workers.dispose();
  });

  test('a table continuation re-parses the whole table frame', () async {
    final engine = await _engine();
    final resource = _message('table');
    final first = _revise(
      resource: resource,
      position: _position(1),
      text: '| a | b |\n| --- | --- |\n| 1 | 2 |\n\nend\n\n',
    );
    expect(first.blocks.first.isSealed, isTrue);
    expect(first.blocks.last.isSealed, isTrue);
    expect(first.blocks.first, isA<SourceBlock>());
    final tableSpan = scanMessageMarkdownBlockSpans(first.text).first;
    expect(tableSpan.block.type, MessageMarkdownBlockType.table);
    final firstOutcome = await engine.prepare(_request(first));
    _expectMatchesReference(first, firstOutcome.value);

    final grown = _revise(
      resource: resource,
      position: _position(2),
      text: '| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n\nend\n\n',
      previous: first,
    );
    final grownOutcome = await engine.prepare(_request(grown));
    expect(grownOutcome.plan.reusedValue, isFalse);
    expect(grownOutcome.plan.blocksToParse, contains(grown.blocks.first.id));
    expect(grown.blocks.first.version.value, greaterThan(0));
    // The unchanged paragraph after the table is still reused.
    expect(grownOutcome.plan.reusableBlocks, contains(grown.blocks.last.id));
    final table = grownOutcome.value.blocks.first.value;
    expect(table.rows, hasLength(3), reason: 'header and two data rows');
    expect(table.rows.last, <String>['3', '4']);
    _expectMatchesReference(grown, grownOutcome.value);

    // A table that could still absorb a following row is never sealed.
    final trailing = _revise(
      resource: _message('table-open'),
      position: _position(1),
      text: '| a | b |\n| --- | --- |\n| 1 | 2 |\n',
    );
    expect(trailing.blocks.single.isSealed, isFalse);
    final trailingOutcome = await engine.prepare(_request(trailing));
    expect(trailingOutcome.value.mutableTail, hasLength(1));
    _expectMatchesReference(trailing, trailingOutcome.value);
    await engine.workers.dispose();
  });

  test('a cross-block reference re-parses its dependent block', () async {
    final engine = await _engine();
    final resource = _message('links');
    final first = _revise(
      resource: resource,
      position: _position(1),
      text: '[site]: https://one.test\n\nsee [site] here\n\nunrelated tail\n',
    );
    final definition = first.blocks.first;
    final dependent = first.blocks[1];
    expect(dependent.references, hasLength(1));
    expect(dependent.references.single.blockId, definition.id);
    final firstOutcome = await engine.prepare(_request(first));
    expect(firstOutcome.plan.trigger, PreparationTrigger.initial);
    _expectMatchesReference(first, firstOutcome.value);

    final changed = _revise(
      resource: resource,
      position: _position(2),
      text: '[site]: https://two.test\n\nsee [site] here\n\nunrelated tail\n',
      previous: first,
    );
    expect(changed.blocks[1].version, dependent.version);
    final outcome = await engine.prepare(_request(changed));

    expect(outcome.plan.trigger, PreparationTrigger.blockDependencyChanged);
    expect(
      outcome.plan.blocksToParse,
      containsAll(<BlockId>[definition.id, dependent.id]),
    );
    expect(outcome.plan.changedBlocks, contains(definition.id));
    expect(outcome.plan.cause!.changed, contains(definition.id));
    _expectMatchesReference(changed, outcome.value);
    await engine.workers.dispose();
  });

  test(
    'a linked message invalidates dependents in the other message',
    () async {
      final engine = await _engine();
      final messageA = _message('message-a');
      final messageB = _message('message-b');

      BlockReference? resolve(String label, ResourceKey resource) =>
          label == 'shared'
          ? BlockReference(
              resource: messageB,
              blockId: const BlockId('block-0'),
            )
          : null;

      final definitionB = _revise(
        resource: messageB,
        position: _position(1),
        text: 'shared definition body\n\n',
      );
      final outcomeB = await engine.prepare(_request(definitionB));
      expect(outcomeB.parsedBlocks, 1);

      final firstA = _revise(
        resource: messageA,
        position: _position(1),
        text: 'uses [shared] label\n\nunrelated\n',
        resolveExternalLabel: resolve,
      );
      expect(firstA.blocks.first.references.single.resource, messageB);
      final firstOutcomeA = await engine.prepare(_request(firstA));
      expect(firstOutcomeA.value.blocks.first.block.references, hasLength(1));

      // The other message changes; this engine never prepares it.
      engine.invalidateBlock(messageB, const BlockId('block-0'));
      final outcomeA = await engine.prepare(_request(firstA));
      expect(outcomeA.plan.trigger, PreparationTrigger.blockDependencyChanged);
      expect(outcomeA.plan.blocksToParse, contains(firstA.blocks.first.id));
      expect(
        outcomeA.plan.reusableBlocks,
        isNot(contains(firstA.blocks.first.id)),
        reason: 'the dependent re-parsed instead of being reused',
      );
      _expectMatchesReference(firstA, outcomeA.value);

      // One memo per sealed block: message B's definition and message A's first
      // block. Message A's open tail is never memoized.
      expect(engine.cache.blockMemos, 2);
      await engine.workers.dispose();
    },
  );

  test('a replaced source re-preparses everything under a new epoch', () async {
    final engine = await _engine();
    final resource = _message('replaced');
    final first = _revise(
      resource: resource,
      position: _position(1),
      text: 'alpha\n\nbeta\n\ngamma\n',
    );
    await engine.prepare(_request(first));
    final oldIds = first.blockIds;
    final bytesBefore = engine.cache.residentBytes;
    expect(bytesBefore, greaterThan(0));

    engine.replaceSource(resource, const SourceEpoch('epoch-b'));
    final second = _revise(
      resource: resource,
      position: _position(1, epoch: 'epoch-b'),
      text: 'alpha\n\nbeta\n\ngamma\n',
      previous: first,
    );
    final plan = engine.plan(_request(second));
    expect(plan.trigger, PreparationTrigger.sourceReplaced);
    expect(plan.scope, PreparationScope.global);
    expect(plan.blocksToParse, hasLength(3));
    expect(
      second.blockIds.toSet().intersection(oldIds.toSet()),
      isEmpty,
      reason: 'a replaced source issues new block identities',
    );
    expect(
      first.blocks.first.text.isValidIn(second.position),
      isFalse,
      reason: 'old offsets do not address the new source',
    );

    final outcome = await engine.prepare(_request(second));
    expect(outcome.parsedBlocks, 3);
    expect(outcome.value.position, second.position);
    _expectMatchesReference(second, outcome.value);
    await engine.workers.dispose();
  });

  test('semantic config changes re-parse; styling cannot', () async {
    final engine = await _engine();
    final resource = _message('config');
    final revision = _revise(
      resource: resource,
      position: _position(1),
      text: 'first\n\nsecond\n',
    );
    final featureless = SyntaxConfig(revision: 'v1');
    final styled = SyntaxConfig(
      revision: 'v1',
      features: <String>[], // an equal set built from another instance
    );
    final first = await engine.prepare(
      _request(revision, syntaxConfig: featureless),
    );
    final restyled = await engine.prepare(
      _request(revision, syntaxConfig: styled),
    );
    expect(restyled.plan.reusedValue, isTrue);
    expect(restyled.parsedBlocks, 0);
    expect(identical(restyled.value, first.value), isTrue);

    final semantic = SyntaxConfig(revision: 'v2');
    final plan = engine.plan(_request(revision, syntaxConfig: semantic));
    expect(plan.trigger, PreparationTrigger.parserConfigChanged);
    expect(plan.scope, PreparationScope.global);
    expect(plan.blocksToParse, hasLength(2));

    final outcome = await engine.prepare(
      _request(revision, syntaxConfig: semantic),
    );
    expect(outcome.parsedBlocks, 2);
    expect(outcome.value.key.syntaxConfig, semantic);
    expect(
      outcome.value.blocks.map((block) => block.value.contentHash).toList(),
      first.value.blocks.map((block) => block.value.contentHash).toList(),
    );
    await engine.workers.dispose();
  });

  test('the byte bound is real, and an evicted block re-parses', () async {
    final engine = await _engine(capacityBytes: 200);
    final resource = _message('bounded');
    final first = _revise(
      resource: resource,
      position: _position(1),
      text: [
        for (var index = 0; index < 6; index++)
          'paragraph number $index with a reasonably long body\n',
      ].join('\n'),
    );
    final firstOutcome = await engine.prepare(_request(first));
    expect(engine.cache.residentBytes, lessThanOrEqualTo(200));
    expect(engine.cache.evictions, greaterThan(0));
    expect(
      firstOutcome.parsedBlocks,
      first.blocks.length,
      reason: 'every block is parsed once',
    );
    _expectMatchesReference(first, firstOutcome.value);

    final plan = engine.plan(_request(first));
    expect(plan.trigger, PreparationTrigger.cacheEvicted);
    expect(plan.blocksToParse, isNotEmpty);
    final secondOutcome = await engine.prepare(_request(first));
    expect(secondOutcome.parsedBlocks, greaterThan(0));
    expect(engine.cache.residentBytes, lessThanOrEqualTo(200));
    _expectMatchesReference(first, secondOutcome.value);
    await engine.workers.dispose();
  });

  test('a block larger than the whole budget is never admitted', () async {
    final engine = await _engine(capacityBytes: 16);
    final resource = _message('oversized');
    final revision = _revise(
      resource: resource,
      position: _position(1),
      text: 'a single paragraph that is much larger than the budget\n',
    );
    final outcome = await engine.prepare(_request(revision));
    expect(engine.cache.blockMemos, 0);
    expect(engine.cache.residentBytes, 0);
    expect(outcome.parsedBlocks, 1);
    _expectMatchesReference(revision, outcome.value);
    await engine.workers.dispose();
  });

  test('strict verification catches a source that reuses a version', () async {
    final resource = _message('strict');
    final first = _revise(
      resource: resource,
      position: _position(1),
      text: 'one\n\ntwo\n\n',
    );
    expect(first.blocks.every((block) => block.isSealed), isTrue);

    /// A lying source: new text, the declared version and range unchanged.
    MessageMarkdownDecomposition lyingSource(String text) =>
        MessageMarkdownDecomposition.fromBlocks(
          resource: resource,
          position: _position(2),
          text: text,
          blocks: <SourceBlock>[
            for (final block in first.blocks)
              SourceBlock(
                id: block.id,
                version: block.version,
                text: block.text,
                isSealed: true,
              ),
          ],
        );

    final trusting = await _engine();
    await trusting.prepare(_request(first));
    final trustingPlan = trusting.plan(_request(lyingSource('ONE\n\ntwo\n\n')));
    expect(
      trustingPlan.blocksToParse,
      isEmpty,
      reason: 'the default trust level is the source version contract',
    );
    await trusting.workers.dispose();

    final strict = await _engine(strictTextVerification: true);
    await strict.prepare(_request(first));
    final lying = lyingSource('ONE\n\ntwo\n\n');
    final strictPlan = strict.plan(_request(lying));
    expect(strictPlan.blocksToParse, <BlockId>[first.blocks.first.id]);
    final outcome = await strict.prepare(_request(lying));
    expect(outcome.parsedBlocks, 1);
    expect(
      outcome.value.blocks.first.value.text,
      'ONE',
      reason: 'strict mode re-reads the text it was told to trust',
    );
    _expectMatchesReference(lying, outcome.value);
    await strict.workers.dispose();
  });

  test('the UI isolate keeps running during a real preparation', () async {
    final engine = await _engine(workers: 2, yieldBudgetBytes: 2048);
    final resource = _message('responsive');
    final text = <String>[
      for (var index = 0; index < 400; index++)
        'paragraph $index with enough body text to parse\n',
    ].join('\n');
    final revision = _revise(
      resource: resource,
      position: _position(1),
      text: text,
    );

    var done = false;
    final job = engine.prepare(_request(revision));
    unawaited(job.then<void>((_) => done = true));
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (!done) ticks++;
    });
    final outcome = await job;
    timer.cancel();

    expect(ticks, greaterThan(0), reason: 'the calling isolate stayed alive');
    expect(outcome.parsedBlocks, revision.blocks.length);
    expect(outcome.worker, isNotNull);
    expect(outcome.worker!.runsInCallerIsolate, isFalse);
    expect(outcome.worker!.isolateDebugName, startsWith('licoup-preparation'));
    expect(engine.workers.workerStats.workBytes, greaterThan(0));
    expect(engine.workers.workerStats.yields, greaterThan(0));
    _expectMatchesReference(revision, outcome.value);
    await engine.workers.dispose();
  });

  test('a cancelled preparation never installs and never parses', () async {
    final engine = await _engine();
    final resource = _message('cancelled');
    final revision = _revise(
      resource: resource,
      position: _position(1),
      text: 'alpha\n\nbeta\n',
    );
    final token = PreparationCancellationToken();
    final job = engine.prepare(_request(revision), cancel: token);
    token.cancel(PreparationCancellationReason.superseded);

    await expectLater(
      job,
      throwsA(
        isA<PreparationCancelledException>()
            .having(
              (error) => error.reason,
              'reason',
              PreparationCancellationReason.superseded,
            )
            .having((error) => error.stage, 'stage', isNot('install')),
      ),
    );
    expect(engine.workers.workerStats.handled, 0);
    expect(engine.workers.workerStats.workBytes, 0);
    expect(engine.cache.blockMemos, 0);
    expect(engine.plan(_request(revision)).reusedValue, isFalse);
    await engine.workers.dispose();
  });

  test('a superseded attempt cannot install its late result', () async {
    final engine = await _engine();
    final resource = _message('superseded');
    final first = _revise(
      resource: resource,
      position: _position(1),
      text: 'alpha\n\nbeta\n',
    );
    final second = _revise(
      resource: resource,
      position: _position(2),
      text: 'alpha\n\nbeta changed\n',
      previous: first,
    );
    final stale = PreparationCancellationToken();
    final staleJob = engine.prepare(
      _request(first, generation: 1),
      cancel: stale,
    );
    stale.cancel(PreparationCancellationReason.superseded);
    await expectLater(staleJob, throwsA(isA<PreparationCancelledException>()));

    final fresh = await engine.prepare(_request(second, generation: 2));
    expect(fresh.request.generation, const RequestGeneration(2));
    expect(fresh.request.source, second.position);
    expect(fresh.value.position, second.position);
    expect(stale.isCancelled, isTrue);
    _expectMatchesReference(second, fresh.value);
    await engine.workers.dispose();
  });

  test('CRLF text keeps the same blocks and the same spans', () async {
    final engine = await _engine();
    final resource = _message('crlf');
    final text =
        '# Head\r\n\r\npara one\r\n\r\n```dart\r\ncode\r\n```\r\n\r\npara two\r\n';
    final revision = _revise(
      resource: resource,
      position: _position(1),
      text: text,
    );
    final outcome = await engine.prepare(_request(revision));
    _expectMatchesReference(revision, outcome.value);
    final code = revision.blocks
        .map((block) => revision.textOf(block))
        .firstWhere((slice) => slice.contains('```'));
    expect(code.startsWith('```dart'), isTrue);
    expect(code.contains('\r'), isTrue, reason: 'raw source offsets');
    await engine.workers.dispose();
  });

  test('a long single block is parsed whole and never truncated', () async {
    final engine = await _engine(yieldBudgetBytes: 0);
    final resource = _message('long-block');
    final body = StringBuffer('one long paragraph ');
    while (body.length < 200000) {
      body.write('with more words to make it genuinely long, ');
    }
    final text = '${body}\n\nafter\n\n';
    final revision = _revise(
      resource: resource,
      position: _position(1),
      text: text,
    );
    expect(revision.blocks.first.text.range.length, body.length + 1);

    final outcome = await engine.prepare(_request(revision));
    expect(outcome.parsedBlocks, 2);
    expect(outcome.bytes, greaterThan(200000));
    expect(engine.cache.residentBytes, greaterThan(200000));
    expect(
      outcome.value.blocks.first.value.text,
      body.toString().trim(),
      reason: 'the whole block text survives the round trip',
    );
    _expectMatchesReference(revision, outcome.value);
    expect(
      engine.workers.workerStats.yields,
      revision.blocks.length,
      reason:
          'one yield per region and none inside a region: a single huge '
          'block is parsed as one atomic unit',
    );

    // Re-preparing only what changed does not re-read the long block.
    final grown = _revise(
      resource: resource,
      position: _position(2),
      text: '${body}\n\nafter more\n\n',
      previous: revision,
    );
    final grownOutcome = await engine.prepare(_request(grown));
    expect(grownOutcome.plan.reusedValue, isFalse);
    expect(grownOutcome.parsedBlocks, 1);
    expect(grownOutcome.plan.estimatedInputBytes, lessThan(100));
    _expectMatchesReference(grown, grownOutcome.value);
    await engine.workers.dispose();
  });

  test('a measured engine sizes its own worker pool', () async {
    final engine = await MarkdownPreparationEngine.spawnMeasured(
      name: 'measured-engine',
      probeJobs: 2,
      maxCandidates: 2,
    );
    final measurement = engine.workers.measurement!;
    expect(measurement.workers, greaterThanOrEqualTo(1));
    expect(engine.workers.workers, measurement.workers);

    final revision = _revise(
      resource: _message('measured'),
      position: _position(1),
      text: '# Measured\n\nbody\n',
    );
    final outcome = await engine.prepare(_request(revision));
    expect(outcome.worker, isNotNull);
    expect(outcome.worker!.runsInCallerIsolate, isFalse);
    _expectMatchesReference(revision, outcome.value);
    await engine.workers.dispose();
  });

  test('a bad region is a typed error, not a wrong prepared block', () async {
    final engine = await _engine();
    final resource = _message('bad-region');
    final text = 'first\n\nsecond\n';
    final lyingBlock = SourceBlock(
      id: const BlockId('ambiguous'),
      version: const BlockVersion(0),
      text: SourceTextReference(
        resource: resource,
        position: _position(1),
        range: const SourceTextRange(start: 0, end: 6),
      ),
      isSealed: true,
    );
    final revision = MessageMarkdownDecomposition.fromBlocks(
      resource: resource,
      position: _position(1),
      text: text,
      blocks: <SourceBlock>[lyingBlock],
    );
    final outcome = await engine.prepare(_request(revision));

    await expectLater(
      engine.prepare(
        _request(
          MessageMarkdownDecomposition.fromBlocks(
            resource: resource,
            position: _position(2),
            text: text,
            blocks: <SourceBlock>[
              SourceBlock(
                id: lyingBlock.id,
                version: const BlockVersion(1),
                text: SourceTextReference(
                  resource: resource,
                  position: _position(2),
                  range: SourceTextRange(start: 0, end: text.length),
                ),
                isSealed: true,
              ),
            ],
          ),
        ),
      ),
      throwsA(
        isA<PreparationWorkerException>().having(
          (error) => error.code,
          'code',
          'markdown.region_not_single_block',
        ),
      ),
    );
    expect(outcome.value.blocks, hasLength(1));
    await engine.workers.dispose();
  });
}
