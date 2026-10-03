import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/presentation_flutter.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'support/prepared_markdown.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Rendered text of the slice rows, in layout order.
///
/// A slice with prepared inline runs is a rich text object, so its plain text
/// is read from the span tree; a slice without prepared runs is a plain Text.
List<String> _renderedText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? text.textSpan?.toPlainText())
    .whereType<String>()
    .toList();

/// Every styled span of every rich text in the tree, in layout order.
List<TextSpan> _styledSpans(WidgetTester tester) {
  final spans = <TextSpan>[];
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    final span = widget.textSpan;
    if (span == null) continue;
    span.visitChildren((candidate) {
      if (candidate is TextSpan && candidate.text != null) spans.add(candidate);
      return true;
    });
  }
  return spans;
}

void main() {
  group('partitionStreamingText', () {
    test('keeps every character exactly once, in order', () {
      final text = List.generate(
        250,
        (index) => 'line $index with a little content',
      ).join('\n');

      final slices = partitionStreamingText(text, targetLength: 64);

      expect(slices.join(), text);
      expect(slices.length, greaterThan(1));
      expect(slices.every((slice) => slice.length <= 64), isTrue);
      expect(slices.every((slice) => slice.isNotEmpty), isTrue);
    });

    test('prefers line ends over a hard cut', () {
      final slices = partitionStreamingText(
        'aaaa\nbbbb\ncccc',
        targetLength: 10,
      );

      expect(slices, <String>['aaaa\nbbbb\n', 'cccc']);
    });

    test('never splits an over-long line into partial characters', () {
      final text = 'x' * 10 + '👨‍👩‍👧‍👦' * 5 + 'e\u0301' + 'y' * 10;

      for (final target in <int>[1, 2, 3, 5, 7, 11]) {
        final slices = partitionStreamingText(text, targetLength: target);
        expect(slices.join(), text, reason: 'target $target');
        expect(slices.every((slice) => slice.isNotEmpty), isTrue);
      }
    });

    test('empty text needs no slice', () {
      expect(partitionStreamingText(''), isEmpty);
    });

    test('rejects a non-positive target length', () {
      expect(
        () => partitionStreamingText('text', targetLength: 0),
        throwsArgumentError,
      );
    });
  });

  testWidgets('renders prepared blocks in source order with block chrome', (
    tester,
  ) async {
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.paragraph('First paragraph.')),
      ('b2', MessageMarkdownBlock.heading('Title', level: 1)),
      ('b3', MessageMarkdownBlock.code('void main() {}', language: 'dart')),
      ('b4', MessageMarkdownBlock.quote('Quoted words.')),
    ]);

    await tester.pumpWidget(_host(StreamingText(prepared: prepared)));

    expect(find.text('First paragraph.'), findsOneWidget);
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('void main() {}'), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('Quoted words.'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Title')).style?.fontWeight,
      FontWeight.bold,
    );
  });

  testWidgets('renders list items and table rows from prepared blocks', (
    tester,
  ) async {
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.unorderedList(<String>['alpha', 'beta'])),
      ('b2', MessageMarkdownBlock.orderedList(<String>['first step'])),
      (
        'b3',
        MessageMarkdownBlock.table(<List<String>>[
          <String>['Name', 'Value'],
          <String>['a', '1'],
        ]),
      ),
    ]);

    await tester.pumpWidget(_host(StreamingText(prepared: prepared)));

    expect(find.text('• '), findsNWidgets(2));
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('1. '), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('lays a long block out as bounded slices without losing text', (
    tester,
  ) async {
    final long = List.generate(120, (index) => 'line $index').join('\n');
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.paragraph(long)),
    ]);

    // An unbounded row host, the way a transcript row presents one message.
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: StreamingText(prepared: prepared, targetSliceLength: 64),
        ),
      ),
    );

    // No single laid-out text object holds the whole block...
    expect(find.text(long), findsNothing);
    // ...yet every character of the original is present, in order.
    final rendered = _renderedText(tester);
    expect(rendered.length, greaterThan(1));
    expect(rendered.join(), long);
  });

  testWidgets('keeps slice anchors stable while the mutable tail grows', (
    tester,
  ) async {
    final first = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.paragraph('Sealed answer.')),
      ('b2', MessageMarkdownBlock.paragraph('Tail')),
    ], openTail: true);
    final anchor = StreamingText.anchorKey(first.blocks.first.block, 0);

    await tester.pumpWidget(_host(StreamingText(prepared: first)));
    final element = tester.element(find.byKey(anchor));

    final second = preparedMarkdownValue(
      <(String, MessageMarkdownBlock)>[
        ('b1', MessageMarkdownBlock.paragraph('Sealed answer.')),
        ('b2', MessageMarkdownBlock.paragraph('Tail grows further')),
      ],
      version: 2,
      openTail: true,
    );
    await tester.pumpWidget(_host(StreamingText(prepared: second)));

    expect(find.text('Tail grows further'), findsOneWidget);
    expect(find.byKey(anchor), findsOneWidget);
    expect(identical(tester.element(find.byKey(anchor)), element), isTrue);
  });

  testWidgets('a replaced source epoch retires anchors of the old epoch', (
    tester,
  ) async {
    final first = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.paragraph('Same looking text.')),
    ]);
    final oldAnchor = StreamingText.anchorKey(first.blocks.first.block, 0);

    await tester.pumpWidget(_host(StreamingText(prepared: first)));
    expect(find.byKey(oldAnchor), findsOneWidget);

    final replaced = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.paragraph('Same looking text.')),
    ], epoch: 'epoch-b');
    await tester.pumpWidget(_host(StreamingText(prepared: replaced)));

    expect(find.byKey(oldAnchor), findsNothing);
    expect(
      find.byKey(StreamingText.anchorKey(replaced.blocks.first.block, 0)),
      findsOneWidget,
    );
  });

  testWidgets('restyling keeps the rendered rows and applies the new style', (
    tester,
  ) async {
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.paragraph('Styled paragraph.')),
      ('b2', MessageMarkdownBlock.paragraph('Second paragraph.')),
    ]);
    final anchor = StreamingText.anchorKey(prepared.blocks.first.block, 0);
    var style = const TextStyle(fontSize: 14);

    late StateSetter setState;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setter) {
            setState = setter;
            return StreamingText(prepared: prepared, style: style);
          },
        ),
      ),
    );
    final before = tester.element(find.byKey(anchor));

    setState(() {
      style = const TextStyle(fontSize: 22, color: Color(0xFF112233));
    });
    await tester.pump();

    // The same prepared value, the same rows: a restyle is presentation only.
    expect(identical(tester.element(find.byKey(anchor)), before), isTrue);
    expect(
      tester.widget<Text>(find.text('Styled paragraph.')).style?.fontSize,
      22,
    );
  });

  testWidgets('selection covers displayed text and exposes the copy action', (
    tester,
  ) async {
    var copied = false;
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.paragraph('Selectable answer text.')),
    ]);

    await tester.pumpWidget(
      _host(StreamingText(prepared: prepared, onCopy: () => copied = true)),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('Selectable answer text.'), findsOneWidget);

    // The explicit full-copy action reaches accessibility clients.
    final semanticsFinder = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.onCopy != null,
    );
    expect(semanticsFinder, findsOneWidget);
    final node = tester.getSemantics(semanticsFinder);
    expect(node.getSemanticsData().hasAction(SemanticsAction.copy), isTrue);

    node.owner!.performAction(node.id, SemanticsAction.copy);
    expect(copied, isTrue);
  });

  testWidgets('double tap still triggers copy when selection is disabled', (
    tester,
  ) async {
    var copyCalled = false;
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.paragraph('Double tap to copy me')),
    ]);

    await tester.pumpWidget(
      _host(
        StreamingText(
          prepared: prepared,
          selectable: false,
          onCopy: () => copyCalled = true,
        ),
      ),
    );

    await tester.tap(find.text('Double tap to copy me'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Double tap to copy me'));
    await tester.pumpAndSettle();

    expect(copyCalled, isTrue);
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('a bounded presenter builds slices lazily as they scroll in', (
    tester,
  ) async {
    final lines = List.generate(
      400,
      (index) => 'line ${index.toString().padLeft(3, '0')}'.padRight(40, 'x'),
    );
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.code(lines.join('\n'))),
    ]);
    final controller = ScrollController();

    await tester.pumpWidget(
      _host(
        SizedBox(
          height: 150,
          child: StreamingText(
            prepared: prepared,
            controller: controller,
            shrinkWrap: false,
            targetSliceLength: 48,
          ),
        ),
      ),
    );

    final built = _renderedText(tester);
    expect(built.length, lessThan(lines.length));
    expect(find.text(lines.last), findsNothing);

    await tester.dragUntilVisible(
      find.text(lines.last),
      find.byType(Scrollable),
      const Offset(0, -600),
    );

    expect(find.text(lines.last), findsOneWidget);
  });

  testWidgets('an empty prepared value renders nothing', (tester) async {
    final prepared = preparedMarkdownValue(
      const <(String, MessageMarkdownBlock)>[],
    );

    await tester.pumpWidget(_host(StreamingText(prepared: prepared)));

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('renders prepared inline runs with mapped styles', (
    tester,
  ) async {
    final inline = prepareMessageMarkdownInline('Use **bold** and `code` here');
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      (
        'b1',
        MessageMarkdownBlock.paragraph(
          'Use **bold** and `code` here',
          inline: inline,
        ),
      ),
    ]);

    await tester.pumpWidget(_host(StreamingText(prepared: prepared)));

    // The visible text is the prepared display, not the raw markup.
    expect(find.text('Use bold and code here'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('`'), findsNothing);

    final spans = _styledSpans(tester);
    final bold = spans.firstWhere((span) => span.text == 'bold');
    expect(bold.style?.fontWeight, FontWeight.bold);
    final code = spans.firstWhere((span) => span.text == 'code');
    expect(code.style?.fontFamily, 'monospace');
    expect(code.style?.fontWeight, isNot(FontWeight.bold));
  });

  testWidgets('a styled run split by slicing keeps its style in every piece', (
    tester,
  ) async {
    final inline = prepareMessageMarkdownInline('**bold text that wraps**');
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      (
        'b1',
        MessageMarkdownBlock.paragraph(
          '**bold text that wraps**',
          inline: inline,
        ),
      ),
    ]);

    await tester.pumpWidget(
      _host(StreamingText(prepared: prepared, targetSliceLength: 8)),
    );

    // Several bounded slices, every character once, no markup on screen.
    final rendered = _renderedText(tester);
    expect(rendered.length, greaterThan(1));
    expect(rendered.join(), 'bold text that wraps');
    final spans = _styledSpans(tester);
    expect(spans, isNotEmpty);
    expect(
      spans.every((span) => span.style?.fontWeight == FontWeight.bold),
      isTrue,
      reason: 'the strong run keeps its style in every slice',
    );
  });

  testWidgets('a plain fallback never interprets markup-looking text', (
    tester,
  ) async {
    // A block without prepared inline runs is displayed literally: the
    // presenter has no tokenizer to fall back to.
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      ('b1', MessageMarkdownBlock.paragraph('**not bold** and `not code`')),
    ]);

    await tester.pumpWidget(_host(StreamingText(prepared: prepared)));

    expect(find.text('**not bold** and `not code`'), findsOneWidget);
    expect(
      _styledSpans(
        tester,
      ).any((span) => span.style?.fontWeight == FontWeight.bold),
      isFalse,
    );
  });

  testWidgets('prepared table cells render their own display values', (
    tester,
  ) async {
    final prepared = preparedMarkdownValue(<(String, MessageMarkdownBlock)>[
      (
        'b1',
        MessageMarkdownBlock.table(
          <List<String>>[
            <String>['Name', 'Value'],
            <String>['`a`', 'plain'],
          ],
          cellInline: <List<MessageMarkdownInline>>[
            <MessageMarkdownInline>[
              MessageMarkdownInline.plain('Name'),
              MessageMarkdownInline.plain('Value'),
            ],
            <MessageMarkdownInline>[
              prepareMessageMarkdownInline('`a`'),
              MessageMarkdownInline.plain('plain'),
            ],
          ],
        ),
      ),
    ]);

    await tester.pumpWidget(_host(StreamingText(prepared: prepared)));

    expect(find.text('Name'), findsOneWidget);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('`a`'), findsNothing);
    expect(
      _styledSpans(
        tester,
      ).firstWhere((span) => span.text == 'a').style?.fontFamily,
      'monospace',
    );
  });
}
