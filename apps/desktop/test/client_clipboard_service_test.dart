import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/platform/client_clipboard_service.dart';

void main() {
  test(
    'clipboard image is materialized and released as an owned attachment',
    () async {
      final bytes = Uint8List.fromList(const <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      final service = ClientClipboardService(
        imageSource: _FakeClipboardImageSource(
          ClientClipboardImageReadResult.success(
            bytes: bytes,
            mediaType: 'image/png',
          ),
        ),
      );
      addTearDown(service.dispose);

      final result = await service.readImageAttachment();

      expect(result.consumed, isTrue);
      expect(result.succeeded, isTrue);
      final attachment = result.attachment!;
      expect(attachment.mediaType, 'image/png');
      expect(attachment.name, 'pasted-image-1.png');
      expect(await File(attachment.path).readAsBytes(), bytes);

      await service.releaseAttachments([attachment]);
      expect(await File(attachment.path).exists(), isFalse);
    },
  );

  test(
    'clipboard without an image preserves native text paste fallback',
    () async {
      final service = ClientClipboardService(
        imageSource: _FakeClipboardImageSource(
          const ClientClipboardImageReadResult.absent(),
        ),
      );
      addTearDown(service.dispose);

      final result = await service.readImageAttachment();

      expect(result.consumed, isFalse);
      expect(result.attachment, isNull);
      expect(result.failureCode, isEmpty);
    },
  );
}

final class _FakeClipboardImageSource implements ClientClipboardImageSource {
  const _FakeClipboardImageSource(this.result);

  final ClientClipboardImageReadResult result;

  @override
  Future<ClientClipboardImageReadResult> readImage() async => result;
}
