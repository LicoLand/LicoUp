import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/src/cache/markdown_preparation_cache.dart';
import 'package:presentation_runtime/src/preparation/markdown/markdown_preparation_engine.dart';
import 'package:presentation_runtime/src/preparation/markdown/message_markdown_decomposition.dart';
import 'package:presentation_runtime/src/preparation/markdown/message_markdown_models.dart';
import 'package:presentation_runtime/src/preparation/markdown/message_markdown_parser.dart';
import 'package:presentation_runtime/src/scheduling/preparation_cancellation.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker_pool.dart';
import 'package:test/test.dart';

const ResourceScope _scope = ResourceScope('v7-offthread');

ResourceKey _message(String id) => ResourceKey(scope: _scope, stableKey: id);

ResourceFieldGroup<PreparedValue<MessageMarkdownBlock>> _preparedField(
  ResourceKey resource,
) => ResourceFieldGroup(resource: resource, name: 'preparedBody');

SourcePosition _position(int version, {String epoch = 'epoch-a'}) =>
    SourcePosition(epoch: SourceEpoch(epoch), version: SourceVersion(version));

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

Future<MarkdownPreparationEngine> _engine({int workers = 1}) async {
  final pool = await PreparationWorkerPool.spawn(
    name: 'offthread-scan',
    operations: MarkdownPreparationEngine.workerOperations,
    workers: workers,
  );
  return MarkdownPreparationEngine(
    workers: pool,
    cache: MarkdownPreparationCache(),
  );
}

/// A synthetic message long enough that a scan is real work.
String _longText(int blocks) => <String>[
  for (var index = 0; index < blocks; index++)
    'paragraph $index with enough body text to make the scan real work\n',
].join('\n');

/// Compares prepared output with the full-document reference parser.
void _expectMatchesReference(
  MessageMarkdownDecomposition revision,
  PreparedValue<MessageMarkdownBlock> value,
) {
  final reference = parseMessageMarkdownBlocks(revision.text);
  expect(
    value.blocks.map((block) => block.value.contentHash).toList(),
    reference.map((block) => block.contentHash).toList(),
    reason: 'prepared output must equal the full parse of ${revision.text}',
  );
  expect(value.blockIds, hasLength(reference.length));
}

/// The synchronous contract must survive the move into a worker: identity,
/// version, type, range, sealed state, references, and the ordinal all agree.
void _expectSameRevision(
  MessageMarkdownDecomposition expected,
  MessageMarkdownDecomposition actual,
) {
  expect(actual.resource, expected.resource);
  expect(actual.position, expected.position);
  expect(actual.text, expected.text);
  expect(actual.nextOrdinal, expected.nextOrdinal);
  expect(actual.blocks, hasLength(expected.blocks.length));
  for (var index = 0; index < expected.blocks.length; index++) {
    final before = expected.blocks[index];
    final after = actual.blocks[index];
    expect(after.id, before.id, reason: 'block $index id');
    expect(after.version, before.version, reason: 'block $index version');
    expect(after.text.range, before.text.range, reason: 'block $index range');
    expect(after.isSealed, before.isSealed, reason: 'block $index sealed');
    expect(after.references, before.references, reason: 'block $index refs');
    expect(actual.typeOf(after.id), expected.typeOf(before.id));
  }
}

/// Burns CPU in yielding chunks, so the worker can receive a cancel message
/// between chunks: the same cooperative boundary a real handler uses.
Future<Object?> _busyChunked(Object? payload, WorkerJobContext context) async {
  final config = payload! as List<Object?>;
  final chunks = config[0]! as int;
  final microsPerChunk = config[1]! as int;
  for (var chunk = 0; chunk < chunks; chunk++) {
    final watch = Stopwatch()..start();
    while (watch.elapsedMicroseconds < microsPerChunk) {}
    await context.yieldToControl();
  }
  return null;
}

void main() {
  test('an off-thread scan matches the synchronous decomposition', () async {
    final engine = await _engine();
    final message = _message('shapes');
    final texts = <String>[
      '# Title\n\nintro text\n\nalpha\n\nbeta\n',
      '```dart\nint a = 1;\n',
      '```dart\nint a = 1;\n```\n\nafter\n',
      '| a | b |\n| --- | --- |\n| 1 | 2 |\n',
      '| a | b |\n| --- | --- |\n| 1 | 2 |\n\nend\n\n',
      '- one\n- two\n\n1. first\n2. second\n\n> quote\n\nplain\n',
      '[site]: https://one.test\n\nsee [site] here\n',
      'a\r\n\r\nb\r\n',
      'alpha\n\nbeta',
      '',
    ];
    for (var index = 0; index < texts.length; index++) {
      final text = texts[index];
      final position = _position(index + 1);
      final expected = decomposeMessageMarkdown(
        resource: message,
        position: position,
        text: text,
      );
      final outcome = await engine.decompose(
        resource: message,
        position: position,
        text: text,
      );
      _expectSameRevision(expected, outcome.revision);
      expect(outcome.scannedBlocks, expected.blocks.length);
      expect(outcome.inputLength, text.length);
      expect(
        outcome.worker.runsInCallerIsolate,
        isFalse,
        reason: 'the scan must run on a real worker isolate',
      );
    }
    await engine.workers.dispose();
  });

  test('carried identity survives the off-thread scan', () async {
    final engine = await _engine();
    final message = _message('carried');
    final first = decomposeMessageMarkdown(
      resource: message,
      position: _position(1),
      text: '# Title\n\nintro\n\nalpha\n\nbeta\n\n',
    );
    final secondText = '# Title\n\nintro changed\n\nalpha\n\nbeta\n\ngamma\n';
    final expected = decomposeMessageMarkdown(
      resource: message,
      position: _position(2),
      text: secondText,
      previous: first,
    );
    final outcome = await engine.decompose(
      resource: message,
      position: _position(2),
      text: secondText,
      previous: first,
    );
    _expectSameRevision(expected, outcome.revision);
    expect(
      outcome.revision.blocks.first.id,
      first.blocks.first.id,
      reason: 'an append keeps earlier block identity',
    );
    expect(
      outcome.revision.blocks[1].version.value,
      greaterThan(0),
      reason: 'the changed block still advances its version',
    );
    await engine.workers.dispose();
  });

  test('external label resolution stays on the caller contract', () async {
    final engine = await _engine();
    final messageA = _message('scan-message-a');
    final messageB = _message('scan-message-b');
    final external = BlockReference(
      resource: messageB,
      blockId: const BlockId('block-0'),
    );
    BlockReference? resolve(String label, ResourceKey resource) =>
        label == 'shared' ? external : null;
    const text = 'uses [shared] label\n\nunrelated\n';
    final expected = decomposeMessageMarkdown(
      resource: messageA,
      position: _position(1),
      text: text,
      resolveExternalLabel: resolve,
    );
    final outcome = await engine.decompose(
      resource: messageA,
      position: _position(1),
      text: text,
      resolveExternalLabel: resolve,
    );
    _expectSameRevision(expected, outcome.revision);
    expect(expected.blocks.first.references.single.resource, messageB);
    await engine.workers.dispose();
  });

  test(
    'the off-thread scan keeps the caller responsive while the sync scan blocks it',
    () async {
      final engine = await _engine();
      final message = _message('responsive');
      final text = _longText(4000);

      // The off-thread path: the calling isolate keeps running its own events.
      var done = false;
      final job = engine
          .decompose(resource: message, position: _position(1), text: text)
          .then((outcome) {
            done = true;
            return outcome;
          });
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (!done) ticks++;
      });
      final outcome = await job;
      timer.cancel();

      expect(ticks, greaterThan(0), reason: 'the calling isolate stayed alive');
      expect(outcome.worker.runsInCallerIsolate, isFalse);
      expect(
        outcome.worker.isolateDebugName,
        startsWith('licoup-preparation'),
        reason: 'the identity is reported by the worker itself',
      );
      expect(outcome.scannedBlocks, greaterThan(0));

      // Negative control: the same text through the synchronous contract cannot
      // tick, because that path parses on the calling isolate.
      var localDone = false;
      var localTicks = 0;
      final localTimer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (!localDone) localTicks++;
      });
      final local = decomposeMessageMarkdown(
        resource: message,
        position: _position(2),
        text: text,
      );
      localDone = true;
      localTimer.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(localTicks, 0, reason: 'the sync scan occupies the caller');
      expect(local.blocks, hasLength(outcome.scannedBlocks));
      await engine.workers.dispose();
    },
  );

  test('off-thread revisions drive the incremental engine', () async {
    final engine = await _engine(workers: 2);
    final message = _message('incremental');
    final first = (await engine.decompose(
      resource: message,
      position: _position(1),
      text: '# Title\n\nintro text\n\nalpha\n\nbeta\n',
    )).revision;
    final firstOutcome = await engine.prepare(_request(first));
    expect(firstOutcome.parsedBlocks, first.blocks.length);
    expect(firstOutcome.plan.trigger, PreparationTrigger.initial);
    _expectMatchesReference(first, firstOutcome.value);

    final second = (await engine.decompose(
      resource: message,
      position: _position(2),
      text: '# Title\n\nintro changed\n\nalpha\n\nbeta\n',
      previous: first,
    )).revision;
    final secondOutcome = await engine.prepare(_request(second));
    expect(
      secondOutcome.parsedBlocks,
      2,
      reason: 'the edited block and the open tail',
    );
    expect(secondOutcome.plan.reusableBlocks, hasLength(2));
    expect(
      identical(
        secondOutcome.value.blocks.first.value,
        firstOutcome.value.blocks.first.value,
      ),
      isTrue,
      reason: 'an unchanged block reuses the identical prepared payload',
    );
    _expectMatchesReference(second, secondOutcome.value);
    await engine.workers.dispose();
  });

  test('cross-block invalidation works through the off-thread path', () async {
    final engine = await _engine();
    final message = _message('offthread-links');
    final first = (await engine.decompose(
      resource: message,
      position: _position(1),
      text: '[site]: https://one.test\n\nsee [site] here\n\nunrelated tail\n',
    )).revision;
    expect(first.blocks[1].references.single.blockId, first.blocks[0].id);
    await engine.prepare(_request(first));

    final changed = (await engine.decompose(
      resource: message,
      position: _position(2),
      text: '[site]: https://two.test\n\nsee [site] here\n\nunrelated tail\n',
      previous: first,
    )).revision;
    expect(
      changed.blocks[1].version,
      first.blocks[1].version,
      reason: 'the dependent text did not change by itself',
    );
    final outcome = await engine.prepare(_request(changed));
    expect(outcome.plan.trigger, PreparationTrigger.blockDependencyChanged);
    expect(
      outcome.plan.blocksToParse,
      containsAll(<BlockId>[changed.blocks[0].id, changed.blocks[1].id]),
    );
    _expectMatchesReference(changed, outcome.value);

    // A referenced block in another message still invalidates its dependents:
    // this message has no local definition, so the label resolves externally.
    final messageB = _message('offthread-other');
    final definitionB = (await engine.decompose(
      resource: messageB,
      position: _position(1),
      text: 'shared definition body\n\n',
    )).revision;
    await engine.prepare(_request(definitionB));

    final messageC = _message('offthread-dependent');
    BlockReference? resolveC(String label, ResourceKey resource) =>
        label == 'shared'
        ? BlockReference(resource: messageB, blockId: const BlockId('block-0'))
        : null;
    final dependent = (await engine.decompose(
      resource: messageC,
      position: _position(1),
      text: 'uses [shared] label\n\nunrelated\n',
      resolveExternalLabel: resolveC,
    )).revision;
    expect(dependent.blocks.first.references.single.resource, messageB);
    await engine.prepare(_request(dependent));

    engine.invalidateBlock(messageB, const BlockId('block-0'));
    final again = await engine.prepare(_request(dependent));
    expect(again.plan.trigger, PreparationTrigger.blockDependencyChanged);
    expect(again.plan.blocksToParse, contains(dependent.blocks.first.id));
    await engine.workers.dispose();
  });

  test('a scan cancelled before dispatch never reaches a worker', () async {
    final engine = await _engine();
    final cancel = PreparationCancellationToken()
      ..cancel(PreparationCancellationReason.revoked);
    await expectLater(
      engine.decompose(
        resource: _message('cancelled-before-dispatch'),
        position: _position(1),
        text: 'alpha\n\nbeta\n',
        cancel: cancel,
      ),
      throwsA(
        isA<PreparationCancelledException>().having(
          (error) => error.stage,
          'stage',
          'queued',
        ),
      ),
    );
    expect(engine.workers.workerStats.handled, 0);
    expect(engine.workers.workerStats.workBytes, 0);
    await engine.workers.dispose();
  });

  test('a scan cancelled behind a busy worker frees the queue', () async {
    final engine = await _engine();
    // Occupy the only worker with real region parsing that yields.
    final busy = engine.workers.execute(
      operation: markdownRegionOperation,
      payload: <Object?>[
        1024,
        <Object?>[
          for (var index = 0; index < 200; index++)
            <Object?>['busy-$index', 'paragraph $index body\n\n'],
        ],
      ],
    );
    final cancel = PreparationCancellationToken();
    final scan = engine.decompose(
      resource: _message('cancelled-while-queued'),
      position: _position(1),
      text: _longText(200),
      cancel: cancel,
      onWorker: (_) => fail('a cancelled scan must not reach a worker'),
    );
    expect(engine.workers.pendingJobs, 2);
    cancel.cancel(PreparationCancellationReason.superseded);
    await expectLater(
      scan,
      throwsA(
        isA<PreparationCancelledException>().having(
          (error) => error.stage,
          'stage',
          'queued',
        ),
      ),
    );
    await busy;
    await engine.workers.idle;
    expect(engine.workers.pendingJobs, 0);

    // The cancelled entry released its capacity: the pool still works.
    final fresh = await engine.decompose(
      resource: _message('after-queue-cancel'),
      position: _position(1),
      text: 'alpha\n\n',
    );
    expect(fresh.revision.blocks, isNotEmpty);
    await engine.workers.dispose();
  });

  test('a queue-dropped scan never parses', () async {
    final worker = await PreparationWorker.spawn(
      name: 'scan-queue-drop',
      operations: <String, PreparationWorkerOperation>{
        markdownScanOperation: runMarkdownScan,
        'busy': _busyChunked,
      },
    );
    final busy = worker.execute(
      operation: 'busy',
      payload: <Object?>[10, 5000],
    );
    final token = PreparationCancellationToken();
    final scan = worker.execute(
      operation: markdownScanOperation,
      payload: <Object?>[64 * 1024, _longText(200)],
      cancel: token,
    );
    token.cancel(PreparationCancellationReason.disposed);
    await expectLater(scan, throwsA(isA<PreparationCancelledException>()));
    await busy;
    await _settleWorker(worker);
    expect(worker.workerStats.droppedWhileQueued, 1);
    expect(
      worker.workerStats.workBytes,
      0,
      reason: 'the dropped scan never parsed any block',
    );
    await worker.dispose();
  });
}

/// Waits until every accepted job of [worker] has settled.
Future<void> _settleWorker(PreparationWorker worker) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (worker.pendingJobs > 0 && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
