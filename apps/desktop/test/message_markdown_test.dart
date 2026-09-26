import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_runtime/presentation_runtime.dart'
    show
        MessageMarkdownBlockType,
        PresentationRuntime,
        parseMessageMarkdownBlocks,
        parseStreamingMessageMarkdownBlocks,
        prepareMessageMarkdownInline;

import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_block_view.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_inline.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';

import 'v7_conversation_ui/prepared_message_markdown_harness.dart';

void main() {
  const accent = Color(0xFF0000FF);
  const codeBackground = Color(0xFFEEEEEE);

  group('prepared inline display mapping', () {
    test('maps prepared flags to styles without reading the raw markup', () {
      final inline = prepareMessageMarkdownInline('hello **world** and `code`');
      final first = messageMarkdownInlineSpans(
        inline,
        const TextStyle(fontSize: 14),
        accent: accent,
        codeBackground: codeBackground,
      );
      // A rebuild with the same prepared value and style hits the cache.
      final second = messageMarkdownInlineSpans(
        inline,
        const TextStyle(fontSize: 14),
        accent: accent,
        codeBackground: codeBackground,
      );
      expect(identical(first, second), isTrue);
      expect(first, hasLength(4));
      expect((first[0] as TextSpan).text, 'hello ');
      expect((first[0] as TextSpan).style?.fontWeight, isNull);
      expect((first[1] as TextSpan).text, 'world');
      expect((first[1] as TextSpan).style?.fontWeight, FontWeight.w800);
      expect((first[3] as TextSpan).text, 'code');
      expect((first[3] as TextSpan).style?.fontFamily, 'SF Mono');
      expect((first[3] as TextSpan).style?.fontSize, 13);
      expect((first[3] as TextSpan).style?.backgroundColor, codeBackground);

      // The display value is the authority: the raw source never reaches the
      // mapping, so nothing here can re-tokenize it.
      expect(inline.displayText, 'hello world and code');
      expect((first[3] as TextSpan).text, isNot(contains('`')));

      // A restyle maps the same prepared value again; the value is untouched.
      final restyled = messageMarkdownInlineSpans(
        inline,
        const TextStyle(fontSize: 20),
        accent: accent,
        codeBackground: codeBackground,
      );
      expect(identical(restyled, first), isFalse);
      expect((restyled[3] as TextSpan).style?.fontSize, 19);

      // Cached span trees are shared across widgets, so they are immutable.
      expect(() => first.add(const TextSpan()), throwsUnsupportedError);
    });

    test('maps link and emphasis flags with the renderer styles', () {
      final inline = prepareMessageMarkdownInline(
        'see [label](https://example.test) and *slanted*',
      );
      final spans = messageMarkdownInlineSpans(
        inline,
        const TextStyle(fontSize: 14),
        accent: accent,
        codeBackground: codeBackground,
      );
      final link =
          spans.firstWhere((span) => (span as TextSpan).text == 'label')
              as TextSpan;
      expect(link.style?.color, accent);
      expect(link.style?.decoration, TextDecoration.underline);
      final emphasis =
          spans.firstWhere((span) => (span as TextSpan).text == 'slanted')
              as TextSpan;
      expect(emphasis.style?.fontStyle, FontStyle.italic);
    });

    test('table intrinsic width measurement is cached per prepared cells', () {
      const data = '| A | B |\n|---|---|\n| long cell content | x |\n';
      final cells = parseMessageMarkdownBlocks(data).single.cellInline;
      expect(cells, isNotEmpty);

      final first = messageMarkdownTableIntrinsicColumnWidths(
        cells,
        const TextStyle(fontSize: 14),
        accent: accent,
        codeBackground: codeBackground,
      );
      final second = messageMarkdownTableIntrinsicColumnWidths(
        cells,
        const TextStyle(fontSize: 14),
        accent: accent,
        codeBackground: codeBackground,
      );
      expect(identical(first, second), isTrue);
      expect(first, hasLength(2));
      expect(first[0], greaterThan(first[1]));
      expect(first[1], greaterThan(0));
    });
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
    expect(blocks[0].inline!.displayText, 'Heading');
    expect(blocks[1].type, MessageMarkdownBlockType.unorderedList);
    expect(blocks[1].items, ['first', '**second**']);
    // The item keeps its authored text and carries its own display value.
    expect(blocks[1].itemInline, hasLength(2));
    expect(blocks[1].itemInline[1].displayText, 'second');
    expect(blocks[1].itemInline[1].runs.single.isStrong, isTrue);
    expect(blocks[2].type, MessageMarkdownBlockType.quote);
    expect(blocks[2].inline!.displayText, 'quoted');
    expect(blocks[3].type, MessageMarkdownBlockType.code);
    expect(blocks[3].text, 'final value = 1;');
    // Code keeps its raw text and has no prepared inline display.
    expect(blocks[3].inline, isNull);
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
    expect(blocks[1].cellInline, hasLength(3));
    expect(blocks[1].cellInline[0][0].displayText, 'Old Path');
    expect(blocks[1].cellInline[2][1].displayText, 'apps/desktop/');
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
    expect(
      blocks[1].inline!.displayText,
      'API Error: Connection closed mid-response.\n'
      'The response above may be incomplete.',
    );
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

    test(
      'incremental growth keeps completed heading, list, fence, and paragraph',
      () {
        const headingAndList = '# Title\n\n- one\n- tw';
        final mid = parseStreamingMessageMarkdownBlocks(headingAndList);
        expect(mid.complete, hasLength(2));
        expect(mid.complete[0].type, MessageMarkdownBlockType.heading);
        expect(mid.complete[0].text, 'Title');
        expect(mid.complete[1].type, MessageMarkdownBlockType.unorderedList);
        expect(mid.complete[1].items, ['one']);
        expect(mid.tail?.type, MessageMarkdownBlockType.paragraph);
        expect(mid.tail?.text, 'tw');

        const stillOpenItem = '# Title\n\n- one\n- two more';
        final openItem = parseStreamingMessageMarkdownBlocks(stillOpenItem);
        expect(openItem.complete, hasLength(2));
        expect(openItem.complete[0].type, MessageMarkdownBlockType.heading);
        expect(openItem.complete[0].text, 'Title');
        expect(
          openItem.complete[1].type,
          MessageMarkdownBlockType.unorderedList,
        );
        expect(openItem.complete[1].items, ['one']);
        expect(openItem.tail?.text, 'two more');

        const closedListThenParagraph = '# Title\n\n- one\n- two more\n\nNext';
        final grown = parseStreamingMessageMarkdownBlocks(
          closedListThenParagraph,
        );
        expect(grown.complete[0].type, MessageMarkdownBlockType.heading);
        expect(grown.complete[0].text, 'Title');
        expect(grown.complete[1].type, MessageMarkdownBlockType.unorderedList);
        expect(grown.complete[1].items, ['one', 'two more']);
        expect(grown.tail?.type, MessageMarkdownBlockType.paragraph);
        expect(grown.tail?.text, 'Next');

        const introAndFence = 'Hello there\n\n```dart\nint x';
        final openFence = parseStreamingMessageMarkdownBlocks(introAndFence);
        expect(
          openFence.complete.single.type,
          MessageMarkdownBlockType.paragraph,
        );
        expect(openFence.complete.single.text, 'Hello there');
        expect(openFence.tail?.type, MessageMarkdownBlockType.code);

        final grownFence = parseStreamingMessageMarkdownBlocks(
          'Hello there\n\n```dart\nint x = 1;',
        );
        expect(
          grownFence.complete.single.type,
          MessageMarkdownBlockType.paragraph,
        );
        expect(grownFence.complete.single.text, 'Hello there');
        expect(grownFence.tail?.text, 'int x = 1;');
      },
    );

    test('a reply sharing a closed prefix never inherits its blocks', () {
      // Two replies may stream alternately (group conversations) or a new
      // reply may reuse an earlier opening. Each parse must stand on its own
      // source: a quote closed by a real blank line stays complete, and the
      // next quote opens a fresh tail instead of merging across replies.
      const closed = '> a\n\n';
      final first = parseStreamingMessageMarkdownBlocks(closed);
      expect(first.complete.single.type, MessageMarkdownBlockType.quote);
      expect(first.complete.single.text, 'a');
      expect(first.tail, isNull);

      const unrelated = '> a\n\n> b';
      final second = parseStreamingMessageMarkdownBlocks(unrelated);
      expect(second.complete.single.type, MessageMarkdownBlockType.quote);
      expect(second.complete.single.text, 'a');
      expect(second.tail?.type, MessageMarkdownBlockType.quote);
      expect(second.tail?.text, 'b');
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
        // The content fingerprint covers the prepared inline display too, so
        // equality here means the streaming split kept the same prepared value.
        expect(
          streaming.complete[index].contentHash,
          finalized[index].contentHash,
        );
      }
    });
  });

  group('MessageMarkdown over the real prepared pipeline', () {
    late PresentationRuntime runtime;
    late ConversationMarkdownPreparation preparation;

    setUp(() {
      runtime = PresentationRuntime();
      preparation = conversationMarkdownTestPreparation(runtime: runtime);
    });

    tearDown(() {
      unawaited(preparation.dispose());
      runtime.dispose();
    });

    Widget markdown({
      required String data,
      required String identity,
      bool isStreaming = false,
      Color? foreground,
      MessageMarkdownStyle renderStyle = const MessageMarkdownStyle(
        showCodeLanguage: true,
      ),
    }) => conversationMarkdownTestApp(
      preparation: preparation,
      child: conversationMarkdownTestView(
        data: data,
        identity: identity,
        isStreaming: isStreaming,
        foreground: foreground,
        renderStyle: renderStyle,
      ),
    );

    Future<void> prepare(WidgetTester tester, String identity) async {
      await waitForPreparedBody(tester, preparation, identity);
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) =>
        finishConversationMarkdownTest(tester, preparation, runtime);

    testWidgets('MessageMarkdown renders markdown as structured widgets', (
      tester,
    ) async {
      await tester.pumpWidget(
        markdown(
          identity: 'md-structured',
          data:
              '# Title\n\nUse **bold**, `code`, and [link](https://example.com).\n\n1. step\n\n```sh\necho ok\n```',
        ),
      );
      await prepare(tester, 'md-structured');

      expect(find.text('Title'), findsOneWidget);
      expect(find.textContaining('Use bold, code, and link.'), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('sh'), findsOneWidget);
      expect(find.text('echo ok'), findsOneWidget);

      // The visible inline semantics survived the move into the worker: the
      // display text is styled from the prepared runs, not re-tokenized.
      expect(_spanStyleForText(tester, 'bold')?.fontWeight, FontWeight.w800);
      expect(_spanStyleForText(tester, 'code')?.fontFamily, 'SF Mono');
      final link = _spanStyleForText(tester, 'link');
      expect(link?.decoration, TextDecoration.underline);
      expect(find.textContaining('**'), findsNothing);
      expect(find.textContaining('`'), findsNothing);
      expect(find.textContaining('](https://'), findsNothing);

      // The body was prepared by a real worker isolate, not the caller.
      expect(
        preparation.workerFor('md-structured')?.runsInCallerIsolate,
        isFalse,
        reason: 'the prepared body came from a worker isolate',
      );
      await finish(tester);
    });

    testWidgets('MessageMarkdown renders GFM pipe tables as a table', (
      tester,
    ) async {
      await tester.pumpWidget(
        markdown(
          identity: 'md-table',
          data:
              '| Old Path | New Path | Status | Verifier |\n'
              '|----------|----------|--------|----------|\n'
              '| server/core/ | packages/foundation/ | migration in progress | architecture-graph |\n',
        ),
      );
      await prepare(tester, 'md-table');

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
      await finish(tester);
    });

    testWidgets('MessageMarkdown table wraps text to the available width', (
      tester,
    ) async {
      final longCell = List.filled(2, 'wraps at word boundaries').join(' ');
      await tester.pumpWidget(
        conversationMarkdownTestApp(
          preparation: preparation,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 220,
              child: conversationMarkdownTestView(
                identity: 'md-wrap',
                data:
                    '| Wide | Short |\n'
                    '|------|-------|\n'
                    '| $longCell | short |\n',
              ),
            ),
          ),
        ),
      );
      await prepare(tester, 'md-wrap');

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
      await finish(tester);
    });

    testWidgets(
      'MessageMarkdown renders runtime API warnings as alert blocks',
      (tester) async {
        await tester.pumpWidget(
          markdown(
            identity: 'md-warning',
            data:
                'API Error: Connection closed mid-response. '
                'The response above may be incomplete.',
          ),
        );
        await prepare(tester, 'md-warning');

        expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
        expect(find.textContaining('API Error:'), findsOneWidget);
        await finish(tester);
      },
    );

    testWidgets('a long body is prepared and rendered without truncation', (
      tester,
    ) async {
      final words = List.generate(1200, (index) => 'word$index').join(' ');
      final data = 'Long **body** with `code`: $words';
      await tester.pumpWidget(
        conversationMarkdownTestApp(
          preparation: preparation,
          child: SingleChildScrollView(
            child: conversationMarkdownTestView(
              data: data,
              identity: 'md-long',
            ),
          ),
        ),
      );
      await prepare(tester, 'md-long');

      // The prepared display is complete: the first and last words render, the
      // markup is gone, and no synchronous parser stood in for the worker.
      expect(find.textContaining('Long body with code:'), findsOneWidget);
      expect(find.textContaining('word1199'), findsOneWidget);
      expect(find.textContaining('**'), findsNothing);
      expect(
        preparation.workerFor('md-long')?.runsInCallerIsolate,
        isFalse,
        reason: 'the long body was prepared on a worker isolate',
      );
      await finish(tester);
    });

    testWidgets('a theme change and rebuild repaint the same prepared value', (
      tester,
    ) async {
      const data = '# Title\n\nbody **bold** text\n\n';
      await tester.pumpWidget(markdown(data: data, identity: 'md-restyle'));
      await prepare(tester, 'md-restyle');
      final prepared = preparation.valueFor('md-restyle');
      final preparations = preparation.preparationsFor('md-restyle');
      final worker = preparation.workerFor('md-restyle');
      expect(prepared, isNotNull);

      // Replacing colours and renderer metrics is a pure appearance change:
      // no new preparation, no new worker, and no re-tokenizing of the body.
      await tester.pumpWidget(
        conversationMarkdownTestApp(
          preparation: preparation,
          brightness: Brightness.light,
          child: conversationMarkdownTestView(
            data: data,
            identity: 'md-restyle',
            foreground: const Color(0xFF112233),
            renderStyle: const MessageMarkdownStyle(
              bodyFontSize: 17,
              heading1FontSize: 22,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(identical(preparation.valueFor('md-restyle'), prepared), isTrue);
      expect(preparation.preparationsFor('md-restyle'), preparations);
      expect(identical(preparation.workerFor('md-restyle'), worker), isTrue);
      expect(find.text('Title'), findsOneWidget);
      expect(messageMarkdownSpanFontSize(tester, 'Title'), 22);
      expect(_spanStyleForText(tester, 'bold')?.fontWeight, FontWeight.w800);
      await finish(tester);
    });

    group('streaming mode', () {
      testWidgets(
        'styles a heading mid-stream once its line completes, plain before',
        (tester) async {
          await tester.pumpWidget(
            markdown(
              data: '# Tit',
              identity: 'md-stream-heading',
              isStreaming: true,
            ),
          );
          await prepare(tester, 'md-stream-heading');
          // The half-typed heading renders its prepared title as calm body
          // text, not heading style, and never the raw marker.
          expect(find.text('Tit'), findsOneWidget);
          expect(find.textContaining('#'), findsNothing);
          expect(_spanStyleForText(tester, 'Tit')?.fontSize, 14);
          expect(_hasSpanWithFontSize(tester, 18), isFalse);

          await tester.pumpWidget(
            markdown(
              data: '# Title\n',
              identity: 'md-stream-heading',
              isStreaming: true,
            ),
          );
          await waitForStreamRevision(tester, preparation, 'md-stream-heading');
          expect(find.text('Title'), findsOneWidget);
          expect(messageMarkdownSpanFontSize(tester, 'Title'), 18);

          await tester.pumpWidget(
            markdown(
              data: '# Title\n\nbody grows',
              identity: 'md-stream-heading',
              isStreaming: true,
            ),
          );
          await waitForStreamRevision(tester, preparation, 'md-stream-heading');
          expect(messageMarkdownSpanFontSize(tester, 'Title'), 18);
          expect(_spanStyleForText(tester, 'body grows')?.fontSize, 14);
          await finish(tester);
        },
      );

      testWidgets(
        'unclosed code fence shows the code frame immediately and never flashes '
        'to plain text',
        (tester) async {
          // The frame appears from the opening fence, before any content.
          await tester.pumpWidget(
            markdown(
              data: '```dart\n',
              identity: 'md-stream-code',
              isStreaming: true,
            ),
          );
          await prepare(tester, 'md-stream-code');
          expect(_hasCodeFrame(tester), isTrue);
          expect(find.text('dart'), findsOneWidget);

          // Content streams inside the frame.
          await tester.pumpWidget(
            markdown(
              data: '```dart\nint a = 1;',
              identity: 'md-stream-code',
              isStreaming: true,
            ),
          );
          await waitForStreamRevision(tester, preparation, 'md-stream-code');
          expect(_codeTextStyle(tester, 'int a = 1;')?.fontFamily, 'SF Mono');

          // The closing fence keeps the same code frame; no plain-text phase.
          await tester.pumpWidget(
            markdown(
              data: '```dart\nint a = 1;\n```',
              identity: 'md-stream-code',
              isStreaming: true,
            ),
          );
          await waitForStreamRevision(tester, preparation, 'md-stream-code');
          expect(_codeTextStyle(tester, 'int a = 1;')?.fontFamily, 'SF Mono');

          await tester.pumpWidget(
            markdown(
              data: '```dart\nint a = 1;\n```\n\nafter',
              identity: 'md-stream-code',
              isStreaming: true,
            ),
          );
          await waitForStreamRevision(tester, preparation, 'md-stream-code');
          expect(_codeTextStyle(tester, 'int a = 1;')?.fontFamily, 'SF Mono');
          expect(_spanStyleForText(tester, 'after')?.fontSize, 14);
          await finish(tester);
        },
      );

      testWidgets(
        'a half-typed list stays calm until its run terminates, then renders '
        'as a list',
        (tester) async {
          await tester.pumpWidget(
            markdown(
              data: '- one\n- tw',
              identity: 'md-stream-list',
              isStreaming: true,
            ),
          );
          await prepare(tester, 'md-stream-list');
          // The completed item renders as a list item and only the dangling
          // item is calm prepared text: the raw marker line never shows.
          expect(find.text('-'), findsOneWidget);
          expect(find.text('one'), findsOneWidget);
          expect(find.text('tw'), findsOneWidget);
          expect(_spanStyleForText(tester, 'tw')?.fontSize, 14);
          expect(find.textContaining('- one'), findsNothing);

          await tester.pumpWidget(
            markdown(
              data: '- one\n- two\n',
              identity: 'md-stream-list',
              isStreaming: true,
            ),
          );
          await waitForStreamRevision(tester, preparation, 'md-stream-list');
          // A terminated run renders as a list with one marker per item.
          expect(find.text('-'), findsNWidgets(2));
          await finish(tester);
        },
      );

      testWidgets(
        'a half-typed table keeps completed rows and a calm dangling row',
        (tester) async {
          await tester.pumpWidget(
            markdown(
              data: '| A | B |\n|---|---|\n| a | b |\n| c | d',
              identity: 'md-stream-table',
              isStreaming: true,
            ),
          );
          await prepare(tester, 'md-stream-table');
          expect(find.byType(Table), findsOneWidget);
          expect(find.text('A'), findsOneWidget);
          expect(find.text('a'), findsOneWidget);
          // The dangling row line is calm prepared text, not a table row.
          expect(find.text('| c | d'), findsOneWidget);
          expect(find.text('c'), findsNothing);

          await tester.pumpWidget(
            markdown(
              data: '| A | B |\n|---|---|\n| a | b |\n| c | d |\n',
              identity: 'md-stream-table',
              isStreaming: true,
            ),
          );
          await waitForStreamRevision(tester, preparation, 'md-stream-table');
          // The terminated row joins the table with final styling.
          expect(find.byType(Table), findsOneWidget);
          expect(find.text('c'), findsOneWidget);
          expect(find.textContaining('| c |'), findsNothing);
          await finish(tester);
        },
      );

      testWidgets(
        'a long growing stream keeps its settled items on a worker value',
        (tester) async {
          final items = <String>[
            for (var index = 0; index < 200; index++) '- item $index',
          ];
          final data = '${items.join('\n')}\n- grow';
          await tester.pumpWidget(
            conversationMarkdownTestApp(
              preparation: preparation,
              child: SingleChildScrollView(
                child: conversationMarkdownTestView(
                  data: data,
                  identity: 'md-stream-long',
                  isStreaming: true,
                ),
              ),
            ),
          );
          await prepare(tester, 'md-stream-long');
          expect(find.text('-'), findsNWidgets(200));
          expect(find.text('item 0'), findsOneWidget);
          expect(find.text('item 199'), findsOneWidget);
          expect(find.text('grow'), findsOneWidget);
          expect(
            preparation.workerFor('md-stream-long')?.runsInCallerIsolate,
            isFalse,
          );

          await tester.pumpWidget(
            conversationMarkdownTestApp(
              preparation: preparation,
              child: SingleChildScrollView(
                child: conversationMarkdownTestView(
                  data: '$data more',
                  identity: 'md-stream-long',
                  isStreaming: true,
                ),
              ),
            ),
          );
          await waitForStreamRevision(tester, preparation, 'md-stream-long');
          expect(find.text('-'), findsNWidgets(200));
          expect(find.text('grow more'), findsOneWidget);
          expect(
            preparation.workerFor('md-stream-long')?.runsInCallerIsolate,
            isFalse,
            reason: 'the grown stream is prepared on a worker isolate',
          );
          await finish(tester);
        },
      );

      testWidgets(
        'final render with isStreaming false is the finalized rendering',
        (tester) async {
          const data =
              '# Title\n\n- a\n- b\n\n```sh\necho ok\n```\n\nlast para\n\n';
          await tester.pumpWidget(
            markdown(
              data: data,
              identity: 'md-stream-final',
              isStreaming: true,
            ),
          );
          await prepare(tester, 'md-stream-final');
          final streaming = _renderedPlainTexts(tester);
          await tester.pumpWidget(
            markdown(data: data, identity: 'md-stream-final'),
          );
          await tester.pump();
          final finalized = _renderedPlainTexts(tester);
          expect(streaming, finalized);
          // A terminated document in streaming mode renders identically too.
          expect(streaming, contains('Title'));
          expect(streaming, contains('echo ok'));
          await finish(tester);
        },
      );
    });
  });
}

/// Waits until a streamed identity has a value different from the one held.
Future<void> waitForStreamRevision(
  WidgetTester tester,
  ConversationMarkdownPreparation preparation,
  String identity,
) async {
  final previous = preparation.valueFor(identity);
  await waitForConversationMarkdown(tester, () {
    final value = preparation.valueFor(identity);
    return value != null && !identical(value, previous);
  }, description: 'the next revision of $identity');
  await tester.pump();
}

/// Style of the inline span whose plain text is exactly [text], searching
/// every Text.rich subtree, falling back to the plain Text style.
TextStyle? _spanStyleForText(WidgetTester tester, String text) {
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    final span = widget.textSpan;
    if (span == null) {
      if (widget.data == text) return widget.style;
      continue;
    }
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
    if (span == null) {
      if (widget.style?.fontSize == fontSize) return true;
      continue;
    }
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
