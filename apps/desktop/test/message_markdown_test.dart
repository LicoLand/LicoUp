import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_block_view.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_inline.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('inline span parsing is content-addressed and cached', () {
    const accent = Color(0xFF0000FF);
    const codeBackground = Color(0xFFEEEEEE);
    final first = messageMarkdownInlineSpans(
      'hello **world** and `code`',
      const TextStyle(fontSize: 14),
      accent: accent,
      codeBackground: codeBackground,
    );
    // A rebuild with equal-but-fresh inputs hits the cache.
    final second = messageMarkdownInlineSpans(
      'hello **world** and `code`',
      const TextStyle(fontSize: 14),
      accent: accent,
      codeBackground: codeBackground,
    );
    expect(identical(first, second), isTrue);
    expect(first, hasLength(4));

    final otherText = messageMarkdownInlineSpans(
      'hello world',
      const TextStyle(fontSize: 14),
      accent: accent,
      codeBackground: codeBackground,
    );
    expect(identical(first, otherText), isFalse);

    // Cached span trees are shared across widgets, so they are immutable.
    expect(() => first.add(const TextSpan()), throwsUnsupportedError);
  });

  test('table intrinsic width measurement is cached per content and style', () {
    const accent = Color(0xFF0000FF);
    const codeBackground = Color(0xFFEEEEEE);
    const data = '| A | B |\n|---|---|\n| long cell content | x |\n';
    // The block-parse cache keeps the rows list identity per content.
    final firstRows = parseMessageMarkdownBlocks(data).single.rows;
    final secondRows = parseMessageMarkdownBlocks(data).single.rows;
    expect(identical(firstRows, secondRows), isTrue);

    final first = messageMarkdownTableIntrinsicColumnWidths(
      firstRows,
      const TextStyle(fontSize: 14),
      accent: accent,
      codeBackground: codeBackground,
    );
    final second = messageMarkdownTableIntrinsicColumnWidths(
      secondRows,
      const TextStyle(fontSize: 14),
      accent: accent,
      codeBackground: codeBackground,
    );
    expect(identical(first, second), isTrue);
    expect(first, hasLength(2));
    expect(first[0], greaterThan(first[1]));
    expect(first[1], greaterThan(0));
  });

  test('parseMessageMarkdownBlocks recognizes common message markdown', () {
    final blocks = parseMessageMarkdownBlocks('''
# Heading

- first
- **second**

> quoted

```dart
final value = 1;
```
''');

    expect(blocks, hasLength(4));
    expect(blocks[0].type, MessageMarkdownBlockType.heading);
    expect(blocks[0].text, 'Heading');
    expect(blocks[1].type, MessageMarkdownBlockType.unorderedList);
    expect(blocks[1].items, ['first', '**second**']);
    expect(blocks[2].type, MessageMarkdownBlockType.quote);
    expect(blocks[3].type, MessageMarkdownBlockType.code);
    expect(blocks[3].text, 'final value = 1;');
  });

  test('parseMessageMarkdownBlocks recognizes GFM pipe tables', () {
    final blocks = parseMessageMarkdownBlocks('''
## Migration Matrix

| Old Path | New Path | Status | Verifier |
|----------|----------|--------|----------|
| server/core/ | packages/foundation/ | migration in progress | architecture-graph |
| client-gui/ | apps/desktop/ | shim | layout-audit |
''');

    expect(blocks, hasLength(2));
    expect(blocks[0].type, MessageMarkdownBlockType.heading);
    expect(blocks[1].type, MessageMarkdownBlockType.table);
    expect(blocks[1].rows.first, [
      'Old Path',
      'New Path',
      'Status',
      'Verifier',
    ]);
    expect(blocks[1].rows[1][0], 'server/core/');
    expect(blocks[1].rows[2][1], 'apps/desktop/');
  });

  test('parseMessageMarkdownBlocks recognizes runtime API warnings', () {
    final blocks = parseMessageMarkdownBlocks('''
Normal response.

API Error: Connection closed mid-response.
The response above may be incomplete.
''');

    expect(blocks, hasLength(2));
    expect(blocks[0].type, MessageMarkdownBlockType.paragraph);
    expect(blocks[1].type, MessageMarkdownBlockType.warning);
    expect(
      blocks[1].text,
      'API Error: Connection closed mid-response.\n'
      'The response above may be incomplete.',
    );
  });

  testWidgets('MessageMarkdown renders markdown as structured widgets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            final colors = context.licoColors;
            return Scaffold(
              body: MessageMarkdown(
                data:
                    '# Title\n\nUse **bold**, `code`, and [link](https://example.com).\n\n1. step\n\n```sh\necho ok\n```',
                foreground: colors.text,
                accent: colors.primary,
                codeBackground: colors.surfaceRaised,
                blockBackground: colors.surface,
                borderColor: colors.line,
                renderStyle: const MessageMarkdownStyle(showCodeLanguage: true),
              ),
            );
          },
        ),
      ),
    );

    expect(find.text('Title'), findsOneWidget);
    expect(find.textContaining('Use bold, code, and link.'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('sh'), findsOneWidget);
    expect(find.text('echo ok'), findsOneWidget);
  });

  testWidgets('MessageMarkdown renders GFM pipe tables as a table', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            final colors = context.licoColors;
            return Scaffold(
              body: MessageMarkdown(
                data:
                    '| Old Path | New Path | Status | Verifier |\n'
                    '|----------|----------|--------|----------|\n'
                    '| server/core/ | packages/foundation/ | migration in progress | architecture-graph |\n',
                foreground: colors.text,
                accent: colors.primary,
                codeBackground: colors.surfaceRaised,
                blockBackground: colors.surface,
                borderColor: colors.line,
              ),
            );
          },
        ),
      ),
    );

    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Old Path'), findsOneWidget);
    expect(find.text('packages/foundation/'), findsOneWidget);
    expect(find.textContaining('|----------|'), findsNothing);
    // Tables fit the dialog inner boundary: no horizontal scroll, no overflow.
    expect(find.byType(SingleChildScrollView), findsNothing);
    final tableWidth = tester
        .renderObject<RenderBox>(find.byType(Table))
        .size
        .width;
    expect(tableWidth, lessThanOrEqualTo(800));
  });

  testWidgets('MessageMarkdown table wraps text to the available width', (
    tester,
  ) async {
    final longCell = List.filled(2, 'wraps at word boundaries').join(' ');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            final colors = context.licoColors;
            return Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 220,
                  child: MessageMarkdown(
                    data:
                        '| Wide | Short |\n'
                        '|------|-------|\n'
                        '| $longCell | short |\n',
                    foreground: colors.text,
                    accent: colors.primary,
                    codeBackground: colors.surfaceRaised,
                    blockBackground: colors.surface,
                    borderColor: colors.line,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final tableWidth = tester
        .renderObject<RenderBox>(find.byType(Table))
        .size
        .width;
    expect(tableWidth, lessThanOrEqualTo(220));
    // A 220px container cannot hold 42 characters on a single 14px line,
    // so a taller cell proves the text wrapped instead of overflowing.
    final cellHeight = tester
        .renderObject<RenderParagraph>(
          find.textContaining(longCell, findRichText: true),
        )
        .size
        .height;
    expect(cellHeight, greaterThan(30));
    // Narrow columns keep their intrinsic width instead of an equal share.
    final longCellWidth = tester
        .renderObject<RenderParagraph>(
          find.textContaining(longCell, findRichText: true),
        )
        .size
        .width;
    final shortCellWidth = tester
        .renderObject<RenderParagraph>(find.text('short'))
        .size
        .width;
    expect(shortCellWidth, lessThan(longCellWidth));
  });

  testWidgets('MessageMarkdown renders runtime API warnings as alert blocks', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            final colors = context.licoColors;
            return Scaffold(
              body: MessageMarkdown(
                data:
                    'API Error: Connection closed mid-response. '
                    'The response above may be incomplete.',
                foreground: colors.text,
                accent: colors.primary,
                codeBackground: colors.surfaceRaised,
                blockBackground: colors.surface,
                borderColor: colors.line,
              ),
            );
          },
        ),
      ),
    );

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining('API Error:'), findsOneWidget);
  });

  group('parseStreamingMessageMarkdownBlocks', () {
    test('is content-addressed and cached like the finalized parse', () {
      const data = '# Title\n\n- one\n- tw';
      final first = parseStreamingMessageMarkdownBlocks(data);
      final second = parseStreamingMessageMarkdownBlocks(data);
      expect(identical(first, second), isTrue);
    });

    test('heading is tail until its line terminates', () {
      var parsed = parseStreamingMessageMarkdownBlocks('# Hel');
      expect(parsed.complete, isEmpty);
      expect(parsed.tail?.type, MessageMarkdownBlockType.heading);
      expect(parsed.tail?.text, 'Hel');

      parsed = parseStreamingMessageMarkdownBlocks('# Hello\n');
      expect(parsed.tail, isNull);
      expect(parsed.complete.single.type, MessageMarkdownBlockType.heading);
      expect(parsed.complete.single.text, 'Hello');
    });

    test('paragraph is tail until a blank line terminates it', () {
      var parsed = parseStreamingMessageMarkdownBlocks('hello');
      expect(parsed.complete, isEmpty);
      expect(parsed.tail?.type, MessageMarkdownBlockType.paragraph);
      expect(parsed.tail?.text, 'hello');

      // A lone trailing newline terminates the line, not the paragraph.
      parsed = parseStreamingMessageMarkdownBlocks('hello\nworld');
      expect(parsed.complete, isEmpty);
      expect(parsed.tail?.text, 'hello\nworld');

      parsed = parseStreamingMessageMarkdownBlocks('hello\n');
      expect(parsed.complete, isEmpty);
      expect(parsed.tail?.text, 'hello');

      parsed = parseStreamingMessageMarkdownBlocks('hello\n\n');
      expect(parsed.tail, isNull);
      expect(parsed.complete.single.type, MessageMarkdownBlockType.paragraph);
      expect(parsed.complete.single.text, 'hello');

      parsed = parseStreamingMessageMarkdownBlocks('hello\n\nwor');
      expect(parsed.complete.single.text, 'hello');
      expect(parsed.tail?.text, 'wor');
    });

    test(
      'list completes item by item; the dangling item stays in the tail',
      () {
        var parsed = parseStreamingMessageMarkdownBlocks('- one\n- tw');
        expect(
          parsed.complete.single.type,
          MessageMarkdownBlockType.unorderedList,
        );
        expect(parsed.complete.single.items, ['one']);
        expect(parsed.tail?.type, MessageMarkdownBlockType.paragraph);
        expect(parsed.tail?.text, 'tw');

        parsed = parseStreamingMessageMarkdownBlocks('1. one\n2. tw');
        expect(
          parsed.complete.single.type,
          MessageMarkdownBlockType.orderedList,
        );
        expect(parsed.complete.single.items, ['one']);
        expect(parsed.tail?.text, 'tw');

        // A terminated last item completes the run.
        parsed = parseStreamingMessageMarkdownBlocks('- one\n- two\n');
        expect(parsed.tail, isNull);
        expect(parsed.complete.single.items, ['one', 'two']);

        // A lone dangling item has no complete prefix yet.
        parsed = parseStreamingMessageMarkdownBlocks('- on');
        expect(parsed.complete, isEmpty);
        expect(parsed.tail?.text, 'on');
      },
    );

    test(
      'code fence is open from the opening fence until the closing fence',
      () {
        var parsed = parseStreamingMessageMarkdownBlocks('```dart\nint a = 1;');
        expect(parsed.complete, isEmpty);
        expect(parsed.tail?.type, MessageMarkdownBlockType.code);
        expect(parsed.tail?.language, 'dart');
        expect(parsed.tail?.text, 'int a = 1;');

        // The closing fence closes the block even before its line terminates.
        parsed = parseStreamingMessageMarkdownBlocks(
          '```dart\nint a = 1;\n```',
        );
        expect(parsed.tail, isNull);
        expect(parsed.complete.single.type, MessageMarkdownBlockType.code);
        expect(parsed.complete.single.text, 'int a = 1;');

        // Content before the fence is complete while the fence stays open.
        parsed = parseStreamingMessageMarkdownBlocks('intro\n\n```sh\necho ok');
        expect(parsed.complete.single.type, MessageMarkdownBlockType.paragraph);
        expect(parsed.complete.single.text, 'intro');
        expect(parsed.tail?.type, MessageMarkdownBlockType.code);
        expect(parsed.tail?.text, 'echo ok');
      },
    );

    test('table keeps completed rows; the dangling row stays in the tail', () {
      final parsed = parseStreamingMessageMarkdownBlocks(
        '| A | B |\n|---|---|\n| a | b |\n| c | d',
      );
      expect(parsed.complete.single.type, MessageMarkdownBlockType.table);
      expect(parsed.complete.single.rows, [
        ['A', 'B'],
        ['a', 'b'],
      ]);
      expect(parsed.tail?.type, MessageMarkdownBlockType.paragraph);
      expect(parsed.tail?.text, '| c | d');
    });

    test('a fully terminated document has no tail and equals the finalized '
        'parse', () {
      const data =
          '# Title\n\n- a\n- b\n\n```sh\necho ok\n```\n\nlast para\n\n';
      final streaming = parseStreamingMessageMarkdownBlocks(data);
      expect(streaming.tail, isNull);
      final finalized = parseMessageMarkdownBlocks(data);
      expect(streaming.complete.length, finalized.length);
      for (var index = 0; index < finalized.length; index++) {
        expect(streaming.complete[index].type, finalized[index].type);
        expect(streaming.complete[index].text, finalized[index].text);
        expect(streaming.complete[index].items, finalized[index].items);
        expect(streaming.complete[index].rows, finalized[index].rows);
        expect(streaming.complete[index].language, finalized[index].language);
        expect(streaming.complete[index].level, finalized[index].level);
      }
    });
  });

  group('MessageMarkdown streaming mode', () {
    testWidgets(
      'styles a heading mid-stream once its line completes, plain before',
      (tester) async {
        await _pumpMarkdown(tester, '# Tit', isStreaming: true);
        // The half-typed heading renders as calm body text, not heading style.
        expect(_spanStyleForText(tester, 'Tit')?.fontSize, 14);
        expect(_hasSpanWithFontSize(tester, 18), isFalse);

        await _pumpMarkdown(tester, '# Title\n', isStreaming: true);
        expect(_spanStyleForText(tester, 'Title')?.fontSize, 18);

        await _pumpMarkdown(tester, '# Title\n\nbody grows', isStreaming: true);
        expect(_spanStyleForText(tester, 'Title')?.fontSize, 18);
        expect(_spanStyleForText(tester, 'body grows')?.fontSize, 14);
      },
    );

    testWidgets(
      'unclosed code fence shows the code frame immediately and never flashes '
      'to plain text',
      (tester) async {
        // The frame appears from the opening fence, before any content.
        await _pumpMarkdown(tester, '```dart\n', isStreaming: true);
        expect(_hasCodeFrame(tester), isTrue);
        expect(find.text('dart'), findsOneWidget);

        // Content streams inside the frame.
        await _pumpMarkdown(tester, '```dart\nint a = 1;', isStreaming: true);
        expect(_codeTextStyle(tester, 'int a = 1;')?.fontFamily, 'SF Mono');

        // The closing fence keeps the same code frame; no plain-text phase.
        await _pumpMarkdown(
          tester,
          '```dart\nint a = 1;\n```',
          isStreaming: true,
        );
        expect(_codeTextStyle(tester, 'int a = 1;')?.fontFamily, 'SF Mono');

        await _pumpMarkdown(
          tester,
          '```dart\nint a = 1;\n```\n\nafter',
          isStreaming: true,
        );
        expect(_codeTextStyle(tester, 'int a = 1;')?.fontFamily, 'SF Mono');
        expect(_spanStyleForText(tester, 'after')?.fontSize, 14);
      },
    );

    testWidgets(
      'mid-list renders terminated items as a list and the dangling item as '
      'plain tail text',
      (tester) async {
        await _pumpMarkdown(tester, '- one\n- tw', isStreaming: true);
        // One completed item: exactly one list marker.
        expect(find.text('-'), findsOneWidget);
        expect(_spanStyleForText(tester, 'one'), isNotNull);
        // The dangling item is tail text in the calm body presentation.
        expect(_spanStyleForText(tester, 'tw')?.fontSize, 14);

        await _pumpMarkdown(tester, '- one\n- two\n', isStreaming: true);
        expect(find.text('-'), findsNWidgets(2));
      },
    );

    testWidgets(
      'final render with isStreaming false is the finalized rendering',
      (tester) async {
        const data =
            '# Title\n\n- a\n- b\n\n```sh\necho ok\n```\n\nlast para\n\n';
        await _pumpMarkdown(tester, data, isStreaming: true);
        final streaming = _renderedPlainTexts(tester);
        await _pumpMarkdown(tester, data);
        final finalized = _renderedPlainTexts(tester);
        expect(streaming, finalized);
        // A terminated document in streaming mode renders identically too.
        expect(streaming, contains('Title'));
        expect(streaming, contains('echo ok'));
      },
    );
  });
}

Future<void> _pumpMarkdown(
  WidgetTester tester,
  String data, {
  bool isStreaming = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Builder(
        builder: (context) {
          final colors = context.licoColors;
          return Scaffold(
            body: MessageMarkdown(
              data: data,
              foreground: colors.text,
              accent: colors.primary,
              codeBackground: colors.surfaceRaised,
              blockBackground: colors.surface,
              borderColor: colors.line,
              renderStyle: const MessageMarkdownStyle(showCodeLanguage: true),
              isStreaming: isStreaming,
            ),
          );
        },
      ),
    ),
  );
}

/// Style of the inline span whose plain text is exactly [text], searching
/// every Text.rich subtree. InlineSpan.visitChildren is a full pre-order walk
/// of the span tree (including the span itself when it has text).
TextStyle? _spanStyleForText(WidgetTester tester, String text) {
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    final span = widget.textSpan;
    if (span == null) continue;
    TextStyle? found;
    span.visitChildren((candidate) {
      if (candidate is TextSpan && candidate.text == text) {
        found ??= candidate.style;
      }
      return true;
    });
    if (found != null) return found;
  }
  return null;
}

bool _hasSpanWithFontSize(WidgetTester tester, double fontSize) {
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    final span = widget.textSpan;
    if (span == null) continue;
    var found = false;
    span.visitChildren((candidate) {
      if (candidate.style?.fontSize == fontSize) {
        found = true;
      }
      return true;
    });
    if (found) return true;
  }
  return false;
}

/// Whether the code-block frame (the monospace body text) is on screen.
bool _hasCodeFrame(WidgetTester tester) {
  return tester
      .widgetList<Text>(find.byType(Text))
      .any((widget) => widget.style?.fontFamily == 'SF Mono');
}

/// Style of the plain (non-rich) code text widget with [data].
TextStyle? _codeTextStyle(WidgetTester tester, String data) {
  for (final widget in tester.widgetList<Text>(find.text(data))) {
    return widget.style;
  }
  return null;
}

/// Plain text of every Text widget in tree order, for render-parity diffs.
List<String> _renderedPlainTexts(WidgetTester tester) {
  return [
    for (final widget in tester.widgetList<Text>(find.byType(Text)))
      widget.data ?? widget.textSpan?.toPlainText() ?? '',
  ];
}
