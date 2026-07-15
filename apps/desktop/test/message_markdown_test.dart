import 'package:flutter/material.dart';
import 'package:flutter_client/src/frontend/shared/ui/message_markdown.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
                codeBackground: colors.surfaceHigh,
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
                codeBackground: colors.surfaceHigh,
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
                codeBackground: colors.surfaceHigh,
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
