import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

void main() {
  testWidgets('StreamingText renders basic paragraphs with inline formatting', (
    tester,
  ) async {
    const doc =
        'Hello **world** with *italic* and `code` span and [docs](https://licoup.dev)';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StreamingText(document: doc)),
      ),
    );

    expect(find.byType(StreamingText), findsOneWidget);
    expect(find.byType(RepaintBoundary), findsWidgets);
    expect(find.text('code'), findsOneWidget);
  });

  testWidgets('StreamingText renders markdown headings and blockquotes', (
    tester,
  ) async {
    const doc = '# Main Title\n\n## Subtitle\n\n> This is a wise quote.';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StreamingText(document: doc)),
      ),
    );

    expect(find.text('Main Title'), findsOneWidget);
    expect(find.text('Subtitle'), findsOneWidget);
    expect(find.text('This is a wise quote.'), findsOneWidget);
  });

  testWidgets('StreamingText renders closed code blocks', (tester) async {
    const doc = '```dart\nvoid main() => print("licoup");\n```';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StreamingText(document: doc)),
      ),
    );

    expect(find.text('dart'), findsOneWidget);
    expect(find.text('void main() => print("licoup");'), findsOneWidget);
  });

  testWidgets(
    'StreamingText renders unclosed code blocks during streaming without waiting for fence',
    (tester) async {
      const doc = '```python\ndef run_agent():\n    return "streaming"';

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: StreamingText(document: doc, isStreaming: true)),
        ),
      );

      // Code container and language render immediately even though ``` closing fence is missing
      expect(find.text('python'), findsOneWidget);
      expect(
        find.text('def run_agent():\n    return "streaming"'),
        findsOneWidget,
      );
    },
  );

  testWidgets('StreamingText renders bullet and ordered lists', (tester) async {
    const doc = '- First bullet\n- Second bullet\n\n1. Numbered item';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StreamingText(document: doc)),
      ),
    );

    expect(find.text('First bullet'), findsOneWidget);
    expect(find.text('Second bullet'), findsOneWidget);
    expect(find.text('Numbered item'), findsOneWidget);
  });

  testWidgets(
    'StreamingText seals completed blocks under stable keys during streaming updates',
    (tester) async {
      var doc = '# Completed Block 1\n\nLine 2';

      late StateSetter setDocState;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setDocState = setState;
                return StreamingText(document: doc, isStreaming: true);
              },
            ),
          ),
        ),
      );

      expect(find.text('Completed Block 1'), findsOneWidget);
      expect(find.text('Line 2'), findsOneWidget);

      // Capture the KeyedSubtree of the first block
      final firstBlockFinder = find.byWidgetPredicate(
        (widget) =>
            widget is KeyedSubtree &&
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith('block-0-'),
      );
      expect(firstBlockFinder, findsOneWidget);

      // Append new tokens to stream
      setDocState(() {
        doc = '# Completed Block 1\n\nLine 2 with streamed suffix';
      });
      await tester.pump();

      // First block's key remains completely stable
      expect(firstBlockFinder, findsOneWidget);
      expect(find.text('Line 2 with streamed suffix'), findsOneWidget);
    },
  );

  testWidgets('StreamingText triggers onCopy callback', (tester) async {
    var copyCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamingText(
            document: 'Double tap to copy me',
            onCopy: () => copyCalled = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Double tap to copy me'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Double tap to copy me'));
    await tester.pumpAndSettle();

    expect(copyCalled, isTrue);
  });
}
