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
}
