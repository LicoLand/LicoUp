import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/src/cache/markdown_preparation_cache.dart';
import 'package:presentation_runtime/src/preparation/markdown/markdown_preparation_engine.dart';
import 'package:presentation_runtime/src/preparation/markdown/message_markdown_decomposition.dart';
import 'package:presentation_runtime/src/preparation/markdown/message_markdown_models.dart';
import 'package:presentation_runtime/src/preparation/markdown/message_markdown_parser.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker.dart';
import 'package:presentation_runtime/src/scheduling/preparation_worker_pool.dart';
import 'package:test/test.dart';

const ResourceScope _scope = ResourceScope('v7-inline');

ResourceKey _message(String id) => ResourceKey(scope: _scope, stableKey: id);

ResourceFieldGroup<PreparedValue<MessageMarkdownBlock>> _preparedField(
  ResourceKey resource,
) => ResourceFieldGroup(resource: resource, name: 'preparedBody');

SourcePosition _position(int version, {String epoch = 'epoch-a'}) =>
    SourcePosition(epoch: SourceEpoch(epoch), version: SourceVersion(version));

MarkdownPreparationRequest _request(
  MessageMarkdownDecomposition revision, {
  int generation = 1,
}) => MarkdownPreparationRequest(
  preparedField: _preparedField(revision.resource),
  revision: revision,
  generation: RequestGeneration(generation),
);

Future<MarkdownPreparationEngine> _engine({int workers = 1}) async {
  final pool = await PreparationWorkerPool.spawn(
    name: 'inline-test',
    operations: MarkdownPreparationEngine.workerOperations,
    workers: workers,
  );
  return MarkdownPreparationEngine(
    workers: pool,
    cache: MarkdownPreparationCache(),
  );
}

/// Flags of the runs whose display text is [text].
String _flagsOf(MessageMarkdownInline inline, String text) {
  final run = inline.runs.where((run) => run.text == text).first;
  return <String>[
    if (run.isCode) 'code',
    if (run.isStrong) 'strong',
    if (run.isEmphasis) 'emphasis',
    if (run.isLink) 'link',
  ].join('+');
}

List<String> _runTexts(MessageMarkdownInline inline) => <String>[
  for (final run in inline.runs) run.text,
];

/// True when a decoded payload is made of transferable primitives only.
bool _isPrimitivePayload(Object? value) {
  if (value == null || value is String || value is int || value is bool) {
    return true;
  }
  if (value is List<Object?>) return value.every(_isPrimitivePayload);
  return false;
}

void main() {
  group('prepareMessageMarkdownInline', () {
    test('keeps the visible inline behavior of the block renderer', () {
      final inline = prepareMessageMarkdownInline(
        'Use **bold**, `code`, and [link](https://example.test).',
      );
      expect(_runTexts(inline), <String>[
        'Use ',
        'bold',
        ', ',
        'code',
        ', and ',
        'link',
        '.',
      ]);
      expect(_flagsOf(inline, 'bold'), 'strong');
      expect(_flagsOf(inline, 'code'), 'code');
      expect(_flagsOf(inline, 'link'), 'link');
      // The link target is not part of the display, exactly as before.
      expect(inline.displayText, 'Use bold, code, and link.');
    });

    test('nests strong, emphasis, and code the way the markup nests', () {
      final inline = prepareMessageMarkdownInline(
        '**bold with `code` and *italic* end**',
      );
      expect(_flagsOf(inline, 'bold with '), 'strong');
      expect(_flagsOf(inline, 'code'), 'code+strong');
      expect(_flagsOf(inline, ' and '), 'strong');
      expect(_flagsOf(inline, 'italic'), 'strong+emphasis');
      expect(_flagsOf(inline, ' end'), 'strong');

      final underscore = prepareMessageMarkdownInline('__strong__ and _em_');
      expect(_flagsOf(underscore, 'strong'), 'strong');
      expect(_flagsOf(underscore, 'em'), 'emphasis');
    });

    test('keeps unmatched markers literal without inventing syntax', () {
      for (final text in <String>[
        'a * b',
        'a ** b',
        'unclosed `code',
        'unclosed [label](target',
        '2 * 3 = 6 and _x',
      ]) {
        final inline = prepareMessageMarkdownInline(text);
        expect(
          inline.displayText,
          text,
          reason: 'display must keep the exact source characters: $text',
        );
        expect(inline.runs.map((run) => run.text).join(), inline.displayText);
      }
      expect(
        prepareMessageMarkdownInline('a * b').runs.every((run) => run.isPlain),
        isTrue,
      );
    });

    test('handles empty text, newlines, and multibyte content', () {
      expect(prepareMessageMarkdownInline('').runs, isEmpty);
      final multiline = prepareMessageMarkdownInline(
        'first **line**\nsecond `line`\nthird 👨‍👩‍👧‍👦 line',
      );
      expect(
        multiline.displayText,
        'first line\nsecond line\nthird 👨‍👩‍👧‍👦 line',
      );
      expect(
        multiline.runs.map((run) => run.text).join(),
        multiline.displayText,
      );
    });

    test('a long block is prepared without truncation', () {
      final source = <String>[
        for (var index = 0; index < 4000; index++)
          'paragraph $index with **bold** and `code` content',
      ].join('\n');
      final inline = prepareMessageMarkdownInline(source);
      expect(inline.runs.map((run) => run.text).join(), inline.displayText);
      expect(inline.displayText, isNot(contains('**')));
      expect(inline.displayText, isNot(contains('`')));
      expect(
        inline.displayText.length,
        source.replaceAll('**', '').replaceAll('`', '').length,
      );
    });
  });

  group('MessageMarkdownInline.slice', () {
    final inline = prepareMessageMarkdownInline(
      'plain **bold** and `code` tail',
    );

    test('covers the full display with the original runs', () {
      final sliced = inline.slice(0, inline.displayText.length);
      expect(sliced.map((run) => run.text).join(), inline.displayText);
      expect(sliced.length, inline.runs.length);
      expect(sliced, inline.runs);
    });

    test('cuts runs at slice boundaries and keeps their flags', () {
      final bold = inline.runs.firstWhere((run) => run.text == 'bold');
      final start = inline.displayText.indexOf(bold.text);
      final sliced = inline.slice(start + 1, start + 3);
      expect(sliced.single.text, 'ol');
      expect(sliced.single.isStrong, isTrue);

      // Every slice of a partition joins back to the exact display text.
      final pieces = <String>[];
      for (var offset = 0; offset < inline.displayText.length; offset += 5) {
        final end = (offset + 5).clamp(0, inline.displayText.length);
        pieces.add(inline.slice(offset, end).map((run) => run.text).join());
      }
      expect(pieces.join(), inline.displayText);
    });

    test('rejects a range outside the display', () {
      expect(() => inline.slice(-1, 2), throwsA(isA<RangeError>()));
      expect(
        () => inline.slice(2, inline.displayText.length + 1),
        throwsA(isA<RangeError>()),
      );
      expect(() => inline.slice(3, 2), throwsA(isA<RangeError>()));
      expect(inline.slice(4, 4), isEmpty);
    });
  });

  group('prepared block codec', () {
    List<MessageMarkdownBlock> corpus() => <MessageMarkdownBlock>[
      MessageMarkdownBlock.paragraph(
        'plain text',
        inline: prepareMessageMarkdownInline('plain text'),
      ),
      MessageMarkdownBlock.paragraph(
        'with **bold** and `code`',
        inline: prepareMessageMarkdownInline('with **bold** and `code`'),
      ),
      MessageMarkdownBlock.heading(
        'Title',
        level: 2,
        inline: prepareMessageMarkdownInline('Title'),
      ),
      MessageMarkdownBlock.quote(
        'quoted `x`',
        inline: prepareMessageMarkdownInline('quoted `x`'),
      ),
      MessageMarkdownBlock.warning(
        'API Error: closed',
        inline: prepareMessageMarkdownInline('API Error: closed'),
      ),
      MessageMarkdownBlock.code('final a = 1;', language: 'dart'),
      MessageMarkdownBlock.unorderedList(
        <String>['first', '**second**'],
        itemInline: <MessageMarkdownInline>[
          prepareMessageMarkdownInline('first'),
          prepareMessageMarkdownInline('**second**'),
        ],
      ),
      MessageMarkdownBlock.orderedList(
        <String>['step'],
        itemInline: <MessageMarkdownInline>[
          prepareMessageMarkdownInline('step'),
        ],
      ),
      MessageMarkdownBlock.table(
        <List<String>>[
          <String>['A', 'B'],
          <String>['`x`', 'plain'],
        ],
        cellInline: <List<MessageMarkdownInline>>[
          <MessageMarkdownInline>[
            prepareMessageMarkdownInline('A'),
            prepareMessageMarkdownInline('B'),
          ],
          <MessageMarkdownInline>[
            prepareMessageMarkdownInline('`x`'),
            prepareMessageMarkdownInline('plain'),
          ],
        ],
      ),
      MessageMarkdownBlock.paragraph(
        '',
        inline: prepareMessageMarkdownInline(''),
      ),
    ];

    test('round-trips every prepared value through primitive payloads', () {
      for (final block in corpus()) {
        final encoded = encodeMessageMarkdownBlock(block);
        expect(
          _isPrimitivePayload(encoded),
          isTrue,
          reason: '${block.type} payload must be transferable primitives',
        );
        final decoded = decodeMessageMarkdownBlock(encoded);
        expect(decoded.type, block.type);
        expect(decoded.text, block.text);
        expect(decoded.level, block.level);
        expect(decoded.language, block.language);
        expect(decoded.items, block.items);
        expect(decoded.rows, block.rows);
        expect(
          decoded.contentHash,
          block.contentHash,
          reason: '${block.type} content identity survives the codec',
        );
      }
    });

    test('a plain field travels as its own text without run duplication', () {
      final block = MessageMarkdownBlock.paragraph(
        'no markup at all',
        inline: prepareMessageMarkdownInline('no markup at all'),
      );
      final encoded = encodeMessageMarkdownBlock(block);
      expect(encoded[6], isNull);
      expect(
        decodeMessageMarkdownBlock(encoded).inline!.displayText,
        'no markup at all',
      );
      expect(decodeMessageMarkdownBlock(encoded).inline!.isPlainText, isTrue);

      // The byte accounting sees the prepared display it actually retains.
      final markupBlock = MessageMarkdownBlock.paragraph(
        'with **bold**',
        inline: prepareMessageMarkdownInline('with **bold**'),
      );
      expect(
        messageMarkdownBlockBytes(markupBlock),
        greaterThan(
          messageMarkdownBlockBytes(
            MessageMarkdownBlock.paragraph('with **bold**'),
          ),
        ),
        reason: 'a prepared display must not be estimated as zero bytes',
      );
      expect(encodeMessageMarkdownBlock(markupBlock)[6], isNotNull);
    });

    test('rejects prepared lists that do not match the authored shape', () {
      expect(
        () => MessageMarkdownBlock.unorderedList(
          <String>['one', 'two'],
          itemInline: <MessageMarkdownInline>[
            prepareMessageMarkdownInline('one'),
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => MessageMarkdownBlock.table(
          <List<String>>[
            <String>['a', 'b'],
          ],
          cellInline: <List<MessageMarkdownInline>>[
            <MessageMarkdownInline>[prepareMessageMarkdownInline('a')],
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('prepared streaming split', () {
    test('a growing list settles completed items, keeps the dangling one', () {
      final growing = parseMessageMarkdownBlocks('- one\n- tw').single;
      expect(growing.type, MessageMarkdownBlockType.unorderedList);
      final split = growing.streaming!;
      expect(split.settledCount, 1);
      expect(split.tail!.type, MessageMarkdownBlockType.paragraph);
      expect(split.tail!.text, 'tw');
      expect(split.tail!.inline!.displayText, 'tw');
      expect(growing.settledStreamingPart!.items, <String>['one']);
      expect(
        growing.settledStreamingPart!.itemInline.single.displayText,
        'one',
      );

      final settled = parseMessageMarkdownBlocks('- one\n- two\n').single;
      expect(settled.streaming!.settledCount, 2);
      expect(settled.streaming!.tail, isNull);
      expect(settled.settledStreamingPart, isNull);
    });

    test('a growing list with one item has no settled part', () {
      final growing = parseMessageMarkdownBlocks('- on').single;
      expect(growing.streaming!.settledCount, 0);
      expect(growing.streaming!.tail!.text, 'on');
      expect(growing.settledStreamingPart, isNull);
    });

    test(
      'a growing table keeps completed rows and prepares the dangling row',
      () {
        final growing = parseMessageMarkdownBlocks(
          '| A | B |\n|---|---|\n| a | b |\n| c | d',
        ).single;
        expect(growing.type, MessageMarkdownBlockType.table);
        final split = growing.streaming!;
        expect(split.settledCount, 2);
        expect(split.tail!.text, '| c | d');
        expect(split.tail!.inline!.displayText, '| c | d');
        final settled = growing.settledStreamingPart!;
        expect(settled.rows, <List<String>>[
          <String>['A', 'B'],
          <String>['a', 'b'],
        ]);
        expect(settled.cellInline, hasLength(2));

        // Only the header exists so far: nothing is settled.
        final headerOnly = parseMessageMarkdownBlocks(
          '| A | B |\n|---|---|',
        ).single;
        expect(headerOnly.streaming!.settledCount, 0);
        expect(headerOnly.streaming!.tail!.text, '| A | B |\n|---|---|');

        final settledTable = parseMessageMarkdownBlocks(
          '| A | B |\n|---|---|\n| a | b |\n\n',
        ).single;
        expect(settledTable.streaming!.settledCount, 2);
        expect(settledTable.streaming!.tail, isNull);
      },
    );

    test('a growing heading or paragraph keeps its own prepared display', () {
      final heading = parseMessageMarkdownBlocks('# Tit').single;
      expect(heading.streaming, isNull);
      expect(heading.text, 'Tit');
      expect(heading.inline!.displayText, 'Tit');

      final paragraph = parseMessageMarkdownBlocks('bo **ld**').single;
      expect(paragraph.streaming, isNull);
      expect(paragraph.inline!.displayText, 'bo ld');
    });

    test('the split round-trips through primitive payloads', () {
      final growing = parseMessageMarkdownBlocks('- one\n- **tw**').single;
      final encoded = encodeMessageMarkdownBlock(growing);
      expect(_isPrimitivePayload(encoded), isTrue);
      final decoded = decodeMessageMarkdownBlock(encoded);
      expect(decoded.contentHash, growing.contentHash);
      expect(decoded.streaming!.settledCount, 1);
      expect(decoded.streaming!.tail!.text, '**tw**');
      expect(decoded.streaming!.tail!.inline!.displayText, 'tw');
      expect(decoded.streaming!.tail!.inline!.runs.single.isStrong, isTrue);
    });

    test('the worker prepares the split over the region boundary', () async {
      final worker = await PreparationWorker.spawn(
        name: 'inline-split',
        operations: MarkdownPreparationEngine.workerOperations,
      );
      final raw = await worker.execute(
        operation: markdownRegionOperation,
        payload: <Object?>[
          64 * 1024,
          <Object?>[
            <Object?>['b1', '- one\n- **tw**'],
          ],
        ],
      );
      final result = (raw! as List<Object?>).single! as List<Object?>;
      expect(result[1], isNull);
      final block = decodeMessageMarkdownBlock(result[2]);
      expect(block.streaming!.settledCount, 1);
      expect(block.streaming!.tail!.inline!.displayText, 'tw');
      expect(block.streaming!.tail!.inline!.runs.single.isStrong, isTrue);
      expect(worker.identity.runsInCallerIsolate, isFalse);
      await worker.dispose();
    });
  });

  test('a worker prepares the inline display, not the caller', () async {
    final engine = await _engine();
    final resource = _message('worker-inline');
    const text = '# Title\n\nbody **bold** and `code`\n\n- item **one**\n';
    final revision = decomposeMessageMarkdown(
      resource: resource,
      position: _position(1),
      text: text,
    );
    final outcome = await engine.prepare(_request(revision));

    expect(outcome.parsedBlocks, revision.blocks.length);
    expect(
      outcome.worker,
      isNotNull,
      reason: 'the region parse must report the worker that ran it',
    );
    expect(outcome.worker!.runsInCallerIsolate, isFalse);
    expect(outcome.worker!.isolateDebugName, startsWith('licoup-preparation'));

    final reference = parseMessageMarkdownBlocks(text);
    expect(
      outcome.value.blocks.map((block) => block.value.contentHash).toList(),
      reference.map((block) => block.contentHash).toList(),
    );
    final prepared = outcome.value.blocks[1].value;
    expect(prepared.type, MessageMarkdownBlockType.paragraph);
    expect(_flagsOf(prepared.inline!, 'bold'), 'strong');
    expect(_flagsOf(prepared.inline!, 'code'), 'code');
    final list = outcome.value.blocks.last.value;
    expect(_flagsOf(list.itemInline.single, 'one'), 'strong');
    await engine.workers.dispose();
  });

  test(
    'the region operation returns prepared runs over the boundary',
    () async {
      final worker = await PreparationWorker.spawn(
        name: 'inline-region',
        operations: MarkdownPreparationEngine.workerOperations,
      );
      final raw = await worker.execute(
        operation: markdownRegionOperation,
        payload: <Object?>[
          64 * 1024,
          <Object?>[
            <Object?>['b1', 'use **bold** and `code` here'],
          ],
        ],
      );
      final result = (raw! as List<Object?>).single! as List<Object?>;
      expect(result[1], isNull, reason: 'no parse error');
      final block = decodeMessageMarkdownBlock(result[2]);
      expect(block.inline, isNotNull);
      expect(_flagsOf(block.inline!, 'bold'), 'strong');
      expect(_flagsOf(block.inline!, 'code'), 'code');
      expect(block.inline!.displayText, 'use bold and code here');
      expect(worker.identity.runsInCallerIsolate, isFalse);
      await worker.dispose();
    },
  );

  test('an edited block re-prepares its inline display', () async {
    final engine = await _engine();
    final resource = _message('inline-edit');
    const firstText = 'alpha **one** tail\n\nbeta `two` tail\n\n';
    final first = decomposeMessageMarkdown(
      resource: resource,
      position: _position(1),
      text: firstText,
    );
    final firstOutcome = await engine.prepare(_request(first));
    expect(
      _flagsOf(firstOutcome.value.blocks.first.value.inline!, 'one'),
      'strong',
    );

    final second = decomposeMessageMarkdown(
      resource: resource,
      position: _position(2),
      text: firstText,
      previous: first,
    );
    final reused = await engine.prepare(_request(second));
    expect(reused.plan.blocksToParse, isEmpty);
    expect(reused.parsedBlocks, 0);
    expect(
      identical(
        reused.value.blocks.first.value,
        firstOutcome.value.blocks.first.value,
      ),
      isTrue,
      reason: 'an unchanged block reuses the identical prepared payload',
    );

    final third = decomposeMessageMarkdown(
      resource: resource,
      position: _position(3),
      text: 'alpha **changed** tail\n\nbeta `two` tail\n\n',
      previous: second,
    );
    final changed = await engine.prepare(_request(third));
    expect(changed.plan.blocksToParse, contains(third.blocks.first.id));
    expect(
      _flagsOf(changed.value.blocks.first.value.inline!, 'changed'),
      'strong',
    );
    expect(
      changed.value.blocks.first.value.inline!.displayText,
      'alpha changed tail',
    );
    expect(
      identical(
        changed.value.blocks[1].value,
        firstOutcome.value.blocks[1].value,
      ),
      isTrue,
      reason: 'the untouched block keeps its prepared display',
    );
    await engine.workers.dispose();
  });

  test('a referenced block change re-prepares the dependent inline', () async {
    final engine = await _engine();
    final resource = _message('inline-dependency');
    final first = decomposeMessageMarkdown(
      resource: resource,
      position: _position(1),
      text: '[site]: https://one.test\n\nsee **bold** [site] here\n\n',
    );
    final firstOutcome = await engine.prepare(_request(first));
    expect(first.blocks[1].references, isNotEmpty);
    expect(first.blocks[1].isSealed, isTrue);
    expect(
      _flagsOf(firstOutcome.value.blocks[1].value.inline!, 'bold'),
      'strong',
    );

    final second = decomposeMessageMarkdown(
      resource: resource,
      position: _position(2),
      text: '[site]: https://two.test\n\nsee **bold** [site] here\n\n',
      previous: first,
    );
    final outcome = await engine.prepare(_request(second));
    expect(outcome.plan.trigger, PreparationTrigger.blockDependencyChanged);
    expect(outcome.plan.blocksToParse, contains(second.blocks[1].id));
    final dependent = outcome.value.blocks[1].value;
    expect(
      identical(dependent, firstOutcome.value.blocks[1].value),
      isFalse,
      reason: 'a dependent block must re-prepare, not reuse its old display',
    );
    expect(dependent.inline!.displayText, 'see bold [site] here');
    expect(_flagsOf(dependent.inline!, 'bold'), 'strong');
    expect(
      outcome.worker!.runsInCallerIsolate,
      isFalse,
      reason: 'the dependent re-parse ran in the worker',
    );
    await engine.workers.dispose();
  });

  test(
    'a long growing stream re-parses only the growing block in a worker',
    () async {
      final engine = await _engine();
      final resource = _message('inline-long-stream');
      final frozen = StringBuffer();
      for (var index = 0; index < 400; index++) {
        frozen.writeln('Paragraph $index with **bold** and `code`.');
        frozen.writeln();
      }
      final listPrefix = <String>[
        for (var index = 0; index < 300; index++) '- item $index',
      ];
      final firstText = '${frozen.toString()}${listPrefix.join('\n')}\n- grow';
      final first = decomposeMessageMarkdown(
        resource: resource,
        position: _position(1),
        text: firstText,
      );
      final firstOutcome = await engine.prepare(_request(first));
      expect(firstOutcome.worker!.runsInCallerIsolate, isFalse);

      final growing = firstOutcome.value.blocks.last.value;
      expect(growing.type, MessageMarkdownBlockType.unorderedList);
      expect(growing.streaming!.settledCount, 300);
      expect(growing.streaming!.tail!.text, 'grow');
      expect(growing.settledStreamingPart!.items, hasLength(300));

      final secondText = '$firstText more';
      final second = decomposeMessageMarkdown(
        resource: resource,
        position: _position(2),
        text: secondText,
        previous: first,
      );
      final secondOutcome = await engine.prepare(_request(second));
      expect(
        secondOutcome.plan.blocksToParse,
        <BlockId>[second.blocks.last.id],
        reason: 'only the growing block re-parses, not the long frozen prefix',
      );
      expect(
        secondOutcome.plan.estimatedInputBytes,
        lessThan(frozen.length),
        reason: 'the long frozen prefix is not re-sent to the worker',
      );
      expect(
        secondOutcome.value.blocks.last.value.streaming!.tail!.text,
        'grow more',
      );
      expect(
        identical(
          secondOutcome.value.blocks.first.value,
          firstOutcome.value.blocks.first.value,
        ),
        isTrue,
        reason: 'the frozen prefix keeps its prepared payload',
      );
      expect(secondOutcome.worker!.runsInCallerIsolate, isFalse);
      await engine.workers.dispose();
    },
  );
}
