import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart'
    show PreparedValue;
import 'package:presentation_runtime/presentation_runtime.dart'
    show
        MessageMarkdownBlock,
        MessageMarkdownInline,
        MessageMarkdownInlineRun,
        PresentationRuntime,
        prepareMessageMarkdownInline;

import 'package:licoup/src/frontend/shared/ui/message_markdown_block_view.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_style.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';

import 'v7_conversation_ui/prepared_message_markdown_harness.dart';

/// The renderer boundary is a behavior, not a file list: a block view renders
/// the prepared display value it receives and has no tokenizer to fall back to.
/// These cases fail if the view ever interprets raw Markdown again.
void main() {
  Widget host(MessageMarkdownBlock block) => MaterialApp(
    theme: buildLicoTheme(platformBrightness: Brightness.dark),
    home: Builder(
      builder: (context) {
        final colors = context.licoColors;
        return Scaffold(
          body: MessageMarkdownBlockView(
            block: block,
            baseStyle: TextStyle(
              color: colors.text,
              fontSize: 14,
              height: 1.35,
            ),
            foreground: colors.text,
            accent: colors.primary,
            codeBackground: colors.surfaceRaised,
            blockBackground: colors.surface,
            borderColor: colors.line,
            renderStyle: const MessageMarkdownStyle(),
          ),
        );
      },
    ),
  );

  testWidgets('a prepared display that disagrees with the raw text wins', (
    tester,
  ) async {
    // The prepared value is the authority: the view must show exactly the
    // display the worker produced, even when the raw text would render
    // differently. A re-tokenizing renderer would show '**raw markup**'.
    final block = MessageMarkdownBlock.paragraph(
      '**raw markup**',
      inline: MessageMarkdownInline(<MessageMarkdownInlineRun>[
        const MessageMarkdownInlineRun('prepared display', isStrong: true),
      ]),
    );
    await tester.pumpWidget(host(block));

    expect(find.text('prepared display'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
    final span = _styledSpans(tester).single;
    expect(span.style?.fontWeight, FontWeight.w800);
  });

  testWidgets(
    'a block without prepared inline renders literally, never parsed',
    (tester) async {
      final block = MessageMarkdownBlock.paragraph(
        '**not bold** and `not code`',
      );
      await tester.pumpWidget(host(block));

      expect(find.text('**not bold** and `not code`'), findsOneWidget);
      expect(
        _styledSpans(
          tester,
        ).any((span) => span.style?.fontWeight == FontWeight.w800),
        isFalse,
      );
      expect(
        _styledSpans(tester).any((span) => span.style?.fontFamily == 'SF Mono'),
        isFalse,
      );
    },
  );

  testWidgets('list items and table cells render their own prepared values', (
    tester,
  ) async {
    final block = MessageMarkdownBlock.unorderedList(
      <String>['**item raw**'],
      itemInline: <MessageMarkdownInline>[
        MessageMarkdownInline(<MessageMarkdownInlineRun>[
          const MessageMarkdownInlineRun('item display'),
        ]),
      ],
    );
    await tester.pumpWidget(host(block));
    expect(find.text('item display'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);

    final table = MessageMarkdownBlock.table(
      <List<String>>[
        <String>['header raw'],
        <String>['`cell raw`'],
      ],
      cellInline: <List<MessageMarkdownInline>>[
        <MessageMarkdownInline>[
          MessageMarkdownInline(<MessageMarkdownInlineRun>[
            const MessageMarkdownInlineRun('cell display'),
          ]),
        ],
        <MessageMarkdownInline>[
          MessageMarkdownInline(<MessageMarkdownInlineRun>[
            const MessageMarkdownInlineRun('second display'),
          ]),
        ],
      ],
    );
    await tester.pumpWidget(host(table));
    expect(find.text('cell display'), findsOneWidget);
    expect(find.textContaining('raw'), findsNothing);
  });

  testWidgets('a prepared inline value from the runtime maps without parsing', (
    tester,
  ) async {
    final block = MessageMarkdownBlock.paragraph(
      'Use **bold** and `code`',
      inline: prepareMessageMarkdownInline('Use **bold** and `code`'),
    );
    await tester.pumpWidget(host(block));

    expect(find.text('Use bold and code'), findsOneWidget);
    final spans = _styledSpans(tester);
    expect(
      spans.firstWhere((span) => span.text == 'bold').style?.fontWeight,
      FontWeight.w800,
    );
    expect(
      spans.firstWhere((span) => span.text == 'code').style?.fontFamily,
      'SF Mono',
    );
  });

  group('worker-prepared streaming split renders the old visible semantics', () {
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

    Future<void> pumpPrepared(
      WidgetTester tester, {
      required String identity,
      required String data,
    }) async {
      // Publish the body the way a view does, let the real pipeline prepare it
      // in the worker, then render the installed value through the split.
      preparation.publish(identity: identity, text: data);
      await waitForPreparedBody(tester, preparation, identity);
      await tester.pumpWidget(
        conversationMarkdownTestApp(
          preparation: preparation,
          child: Builder(
            builder: (context) {
              final prepared = preparation.valueFor(identity);
              final colors = context.licoColors;
              if (prepared == null) return const SizedBox.shrink();
              return SingleChildScrollView(
                child: _preparedBody(
                  prepared,
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
      await tester.pump();
    }

    testWidgets('an open heading shows its title calmly, without the marker', (
      tester,
    ) async {
      await pumpPrepared(tester, identity: 'split-heading', data: '# Tit');

      expect(find.text('Tit'), findsOneWidget);
      expect(find.textContaining('#'), findsNothing);
      expect(_styledSpans(tester).single.style?.fontSize, 14);
      expect(
        _styledSpans(tester).any((span) => span.style?.fontSize == 18),
        isFalse,
      );
      expect(
        preparation.workerFor('split-heading')?.runsInCallerIsolate,
        isFalse,
      );
      await finishConversationMarkdownTest(tester, preparation, runtime);
    });

    testWidgets(
      'a growing list keeps completed items and a calm dangling item',
      (tester) async {
        await pumpPrepared(
          tester,
          identity: 'split-list',
          data: '- one\n- **tw**',
        );

        // The completed item renders as a list item; the dangling one is calm
        // prepared text, and no raw marker line reaches the screen.
        expect(find.text('-'), findsOneWidget);
        expect(find.text('one'), findsOneWidget);
        expect(find.text('tw'), findsOneWidget);
        expect(find.textContaining('- one'), findsNothing);
        expect(find.textContaining('**'), findsNothing);
        expect(_spanStyleForText(tester, 'tw')?.fontSize, 14);
        expect(_spanStyleForText(tester, 'tw')?.fontWeight, FontWeight.w800);
        await finishConversationMarkdownTest(tester, preparation, runtime);
      },
    );

    testWidgets(
      'a growing table keeps completed rows and a calm dangling row',
      (tester) async {
        await pumpPrepared(
          tester,
          identity: 'split-table',
          data: '| A | B |\n|---|---|\n| a | b |\n| c | d',
        );

        expect(find.byType(Table), findsOneWidget);
        expect(find.text('A'), findsOneWidget);
        expect(find.text('a'), findsOneWidget);
        expect(find.text('| c | d'), findsOneWidget);
        expect(find.text('c'), findsNothing);
        await finishConversationMarkdownTest(tester, preparation, runtime);
      },
    );

    testWidgets('a fully settled unsealed table renders with final styling', (
      tester,
    ) async {
      await pumpPrepared(
        tester,
        identity: 'split-table-settled',
        data: '| A | B |\n|---|---|\n| a | b |\n',
      );

      // The last row line is terminated, so nothing streams calmly: the whole
      // table renders final even while the block can still grow.
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('a'), findsOneWidget);
      expect(find.textContaining('|'), findsNothing);
      await finishConversationMarkdownTest(tester, preparation, runtime);
    });

    testWidgets('an open code fence keeps its frame from the opening fence', (
      tester,
    ) async {
      await pumpPrepared(
        tester,
        identity: 'split-code',
        data: '```dart\nint a = 1;',
      );

      expect(find.text('dart'), findsOneWidget);
      expect(find.text('int a = 1;'), findsOneWidget);
      final monoBody = tester
          .widgetList<Text>(find.byType(Text))
          .any((widget) => widget.style?.fontFamily == 'SF Mono');
      expect(
        monoBody ||
            _styledSpans(
              tester,
            ).any((span) => span.style?.fontFamily == 'SF Mono'),
        isTrue,
        reason: 'the open fence keeps its monospace frame',
      );
      await finishConversationMarkdownTest(tester, preparation, runtime);
    });
  });
}

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

/// Renders a prepared body exactly as the composer will: frozen blocks with
/// final styling, the mutable tail through the streaming view.
Widget _preparedBody(
  PreparedValue<MessageMarkdownBlock> prepared, {
  required Color foreground,
  required Color accent,
  required Color codeBackground,
  required Color blockBackground,
  required Color borderColor,
  MessageMarkdownStyle renderStyle = const MessageMarkdownStyle(
    showCodeLanguage: true,
  ),
}) {
  final baseStyle = TextStyle(
    color: foreground,
    fontSize: renderStyle.bodyFontSize,
    height: renderStyle.bodyLineHeight,
    letterSpacing: 0,
  );
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final block in prepared.immutablePrefix) ...[
        MessageMarkdownBlockView(
          key: ValueKey<String>('frozen-${block.id.value}'),
          block: block.value,
          baseStyle: baseStyle,
          foreground: foreground,
          accent: accent,
          codeBackground: codeBackground,
          blockBackground: blockBackground,
          borderColor: borderColor,
          renderStyle: renderStyle,
        ),
        SizedBox(height: renderStyle.blockSpacing),
      ],
      for (final block in prepared.mutableTail)
        MessageMarkdownStreamingBlockView(
          key: ValueKey<String>('tail-${block.id.value}'),
          block: block.value,
          baseStyle: baseStyle,
          foreground: foreground,
          accent: accent,
          codeBackground: codeBackground,
          blockBackground: blockBackground,
          borderColor: borderColor,
          renderStyle: renderStyle,
        ),
    ],
  );
}

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
