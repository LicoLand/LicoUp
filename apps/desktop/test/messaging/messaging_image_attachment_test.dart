import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  group('parseAgentConversationImageAttachments', () {
    test('parses typed entries and drops unusable ones', () {
      final images = parseAgentConversationImageAttachments([
        {'mediaType': 'image/png', 'data': _onePixelPngBase64, 'name': 'shot'},
        {'path': '/fixture-root/screenshot.png'},
        {'name': 'no source at all'},
        {'data': 'x' * 6000001},
        'not-a-map',
      ]);

      expect(images, hasLength(3));
      expect(images[0].mediaType, 'image/png');
      expect(images[0].dataBase64, _onePixelPngBase64);
      expect(images[0].name, 'shot');
      expect(images[1].filePath, '/fixture-root/screenshot.png');
      expect(images[1].mediaType, 'image/png');
      expect(images[2].dataBase64, 'x' * 6000001);
    });

    test('retains every attachment and sanitizes names', () {
      final images = parseAgentConversationImageAttachments([
        for (var index = 0; index < 6; index++)
          {'data': _onePixelPngBase64, 'name': '[Image #${index + 1}]'},
      ]);

      expect(images, hasLength(6));
      for (final image in images) {
        expect(image.name, isEmpty);
      }
    });

    test('parses through the message parser onto the message model', () {
      final message = parseAgentConversationMessage({
        'id': 'm1',
        'role': 'user',
        'text': 'with image',
        'createdAt': '2026-07-20T10:00:00',
        'images': [
          {'mediaType': 'image/png', 'data': _onePixelPngBase64},
        ],
      });

      expect(message.images, hasLength(1));
      expect(message.images.single.dataBase64, _onePixelPngBase64);
    });

    test('keeps an image-only user message displayable', () {
      final message = parseAgentConversationMessage({
        'id': 'image-only',
        'role': 'user',
        'text': '',
        'createdAt': '2026-07-20T10:00:00',
        'images': [
          {'path': '/fixture-root/screenshot.png'},
        ],
      });

      expect(message.text, isEmpty);
      expect(message.images, hasLength(1));
      expect(message.isDisplayable, isTrue);
    });
  });

  testWidgets('message content renders an inline image attachment', (
    tester,
  ) async {
    await _pumpContent(
      tester,
      data: 'see the screenshot',
      images: [
        const AgentConversationImageAttachment(dataBase64: _onePixelPngBase64),
      ],
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-image-attachment-frame')),
      findsOneWidget,
    );
    expect(find.byType(Image), findsWidgets);
    // The inline frame decodes at a bounded size…
    final inlineImage = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const Key('conversation-image-attachment-frame')),
        matching: find.byType(Image),
      ),
    );
    expect(inlineImage.image, isA<ResizeImage>());
    expect(
      find.byKey(const Key('conversation-image-unavailable')),
      findsNothing,
    );
    expect(find.text('see the screenshot', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image-only message renders attachments without text', (
    tester,
  ) async {
    await _pumpContent(
      tester,
      data: '',
      images: [
        const AgentConversationImageAttachment(dataBase64: _onePixelPngBase64),
      ],
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-image-attachment-frame')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('file path source renders the unavailable placeholder', (
    tester,
  ) async {
    await _pumpContent(
      tester,
      data: 'with image',
      images: [
        const AgentConversationImageAttachment(
          filePath: '/definitely/missing/screenshot.png',
        ),
      ],
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-image-unavailable')),
      findsOneWidget,
    );
    expect(find.text('Image unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multiple attachments stack vertically', (tester) async {
    await _pumpContent(
      tester,
      data: 'two shots',
      images: const [
        AgentConversationImageAttachment(dataBase64: _onePixelPngBase64),
        AgentConversationImageAttachment(dataBase64: _onePixelPngBase64),
      ],
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-image-attachment-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-image-attachment-1')),
      findsOneWidget,
    );
    final first = tester.getTopLeft(
      find.byKey(const Key('conversation-image-attachment-0')),
    );
    final second = tester.getTopLeft(
      find.byKey(const Key('conversation-image-attachment-1')),
    );
    expect(first.dy, lessThan(second.dy));
  });

  testWidgets('tapping an attachment opens and closes the viewer', (
    tester,
  ) async {
    await _pumpContent(
      tester,
      data: 'see it',
      images: [
        const AgentConversationImageAttachment(dataBase64: _onePixelPngBase64),
      ],
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('conversation-image-attachment-frame')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('conversation-image-viewer')), findsOneWidget);
    // …while the full-screen viewer keeps the unbounded provider.
    final viewerImage = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const Key('conversation-image-viewer')),
        matching: find.byType(Image),
      ),
    );
    expect(viewerImage.image, isA<MemoryImage>());

    await tester.tap(
      find.byKey(const Key('conversation-image-viewer-dismiss')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('conversation-image-viewer')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpContent(
  WidgetTester tester, {
  required String data,
  required List<AgentConversationImageAttachment> images,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 600,
          child: AgentConversationMessageContent(
            data: data,
            foreground: Colors.white,
            accent: Colors.blue,
            codeBackground: Colors.black,
            blockBackground: Colors.black54,
            borderColor: Colors.grey,
            renderStyle: const MessageMarkdownStyle(),
            images: images,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
