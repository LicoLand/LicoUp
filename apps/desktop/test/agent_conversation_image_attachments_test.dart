import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/conversation_image_byte_reader.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_image_attachments.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/conversation/conversation_image_byte_reader.dart';

void main() {
  testWidgets('path-backed image uses the injected bounded byte reader', (
    tester,
  ) async {
    final reader = _ImageReader(
      ConversationImageReadResult.success(
        Uint8List.fromList(const [
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
        ]),
      ),
    );
    await tester.pumpWidget(_app(reader));
    await tester.pumpAndSettle();

    expect(reader.paths, ['attachment-fixture.png']);
    expect(
      find.byKey(const Key('conversation-image-attachment-frame')),
      findsOneWidget,
    );
    expect(find.text('image.png'), findsNothing);
  });

  testWidgets('reader failure keeps the existing unavailable placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _ImageReader(
          const ConversationImageReadResult.failure(
            conversationAttachmentFailureFileUnavailable,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('conversation-image-unavailable')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-image-attachment-frame')),
      findsNothing,
    );
  });

  test(
    'platform reader rejects a symbolic link without following its target',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'licoup-image-reader-',
      );
      try {
        final target = File(
          '${directory.path}${Platform.pathSeparator}synthetic.png',
        );
        await target.writeAsBytes(const [
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
        ]);
        final link = Link(
          '${directory.path}${Platform.pathSeparator}linked.png',
        );
        await link.create(target.path);

        final result = await PlatformConversationImageByteReader.instance.read(
          localPath: link.path,
          mediaType: 'image/png',
        );

        expect(result.bytes, isNull);
        expect(
          result.failureCode,
          conversationAttachmentFailureSymlinkRejected,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.isWindows,
  );
}

Widget _app(ConversationImageByteReader reader) => MaterialApp(
  theme: buildLicoTheme(platformBrightness: Brightness.dark),
  home: ConversationImageByteReaderScope(
    reader: reader,
    child: const Scaffold(
      body: ConversationImageAttachmentFrame(
        attachment: AgentConversationImageAttachment(
          mediaType: 'image/png',
          filePath: 'attachment-fixture.png',
          name: 'image.png',
        ),
        maxWidth: 340,
        maxHeight: 280,
      ),
    ),
  ),
);

final class _ImageReader implements ConversationImageByteReader {
  _ImageReader(this.result);

  final ConversationImageReadResult result;
  final paths = <String>[];

  @override
  Future<ConversationImageReadResult> read({
    required String localPath,
    required String mediaType,
  }) async {
    paths.add(localPath);
    return result;
  }
}
