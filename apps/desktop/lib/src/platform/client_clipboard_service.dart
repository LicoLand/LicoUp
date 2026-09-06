import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart' as rich_clipboard;

import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/conversation_attachment_release.dart';
import 'package:licoup/src/contracts/conversation_image_byte_reader.dart';

/// Clipboard access at the platform boundary. Text keeps Flutter's native
/// implementation; image reads use the richer native clipboard formats and
/// materialize one bounded private temporary file for the existing local-file
/// attachment pipeline.
class ClientClipboardService implements ConversationAttachmentRelease {
  ClientClipboardService({ClientClipboardImageSource? imageSource})
    : _imageSource = imageSource ?? const SystemClientClipboardImageSource();

  final ClientClipboardImageSource _imageSource;
  final Set<String> _ownedImagePaths = <String>{};
  Future<Directory>? _imageDirectory;
  int _imageSequence = 0;

  Future<void> writeText(String text) {
    return Clipboard.setData(ClipboardData(text: text.trim()));
  }

  Future<ClientClipboardAttachmentResult> readImageAttachment() async {
    final image = await _imageSource.readImage();
    if (!image.available) {
      return const ClientClipboardAttachmentResult.absent();
    }
    if (!image.succeeded) {
      return ClientClipboardAttachmentResult.failure(image.failureCode);
    }
    final bytes = image.bytes!;
    if (bytes.length > maxConversationImageBytesPerFile) {
      return const ClientClipboardAttachmentResult.failure(
        conversationAttachmentFailureSizeLimit,
      );
    }
    final extension = _extensionForMediaType(image.mediaType);
    if (extension.isEmpty) {
      return const ClientClipboardAttachmentResult.failure(
        conversationAttachmentFailureMediaUnsupported,
      );
    }
    final sequence = ++_imageSequence;
    final name = 'pasted-image-$sequence.$extension';
    try {
      final directory = await (_imageDirectory ??= Directory.systemTemp
          .createTemp('licoup-clipboard-images-'));
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      _ownedImagePaths.add(file.path);
      return ClientClipboardAttachmentResult.success(
        ConversationAttachment(
          id: 'clipboard-$sequence',
          name: name,
          mediaType: image.mediaType,
          path: file.path,
        ),
      );
    } on Object {
      return const ClientClipboardAttachmentResult.failure(
        conversationAttachmentStatusFailed,
      );
    }
  }

  @override
  Future<void> releaseAttachments(
    Iterable<ConversationAttachment> attachments,
  ) async {
    var releasedOwnedImage = false;
    for (final attachment in attachments) {
      final path = attachment.path;
      if (!_ownedImagePaths.remove(path)) continue;
      releasedOwnedImage = true;
      try {
        await File(path).delete();
      } on Object {
        // Best-effort cleanup of a client-owned temporary clipboard image.
      }
    }
    if (!releasedOwnedImage || _ownedImagePaths.isNotEmpty) return;
    await _deleteImageDirectory();
  }

  Future<void> _deleteImageDirectory() async {
    final pendingDirectory = _imageDirectory;
    _imageDirectory = null;
    if (pendingDirectory == null) return;
    try {
      final directory = await pendingDirectory;
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on Object {
      // The OS temporary directory remains the final cleanup boundary.
    }
  }

  Future<void> dispose() async {
    await releaseAttachments(
      _ownedImagePaths
          .map(
            (path) => ConversationAttachment(
              id: '',
              name: '',
              mediaType: '',
              path: path,
            ),
          )
          .toList(growable: false),
    );
    await _deleteImageDirectory();
  }
}

abstract interface class ClientClipboardImageSource {
  Future<ClientClipboardImageReadResult> readImage();
}

final class SystemClientClipboardImageSource
    implements ClientClipboardImageSource {
  const SystemClientClipboardImageSource();

  static const _formats = <rich_clipboard.FileFormat>[
    rich_clipboard.Formats.png,
    rich_clipboard.Formats.jpeg,
    rich_clipboard.Formats.gif,
    rich_clipboard.Formats.webp,
  ];

  @override
  Future<ClientClipboardImageReadResult> readImage() async {
    final clipboard = rich_clipboard.SystemClipboard.instance;
    if (clipboard == null) {
      return const ClientClipboardImageReadResult.absent();
    }
    final rich_clipboard.ClipboardReader reader;
    try {
      reader = await clipboard.read();
    } on Object {
      // Preserve Flutter's native text-paste path when rich clipboard access
      // itself is unavailable.
      return const ClientClipboardImageReadResult.absent();
    }
    for (final item in reader.items) {
      final available = item.getFormats(_formats);
      if (available.isEmpty) continue;
      final format = available.first as rich_clipboard.FileFormat;
      final mediaType = _mediaTypeForFormat(format);
      try {
        final bytes = await _readBoundedFile(item, format);
        if (bytes == null) {
          return const ClientClipboardImageReadResult.failure(
            conversationAttachmentStatusFailed,
          );
        }
        return ClientClipboardImageReadResult.success(
          bytes: bytes,
          mediaType: mediaType,
        );
      } on _ClipboardImageTooLarge {
        return const ClientClipboardImageReadResult.failure(
          conversationAttachmentFailureSizeLimit,
        );
      } on Object {
        return const ClientClipboardImageReadResult.failure(
          conversationAttachmentStatusFailed,
        );
      }
    }
    return const ClientClipboardImageReadResult.absent();
  }

  Future<Uint8List?> _readBoundedFile(
    rich_clipboard.ClipboardDataReader reader,
    rich_clipboard.FileFormat format,
  ) {
    final completer = Completer<Uint8List?>();
    final progress = reader.getFile(
      format,
      (file) async {
        try {
          final declaredSize = file.fileSize;
          if (declaredSize != null &&
              declaredSize > maxConversationImageBytesPerFile) {
            file.close();
            throw const _ClipboardImageTooLarge();
          }
          final bytes = BytesBuilder(copy: false);
          var length = 0;
          await for (final chunk in file.getStream()) {
            length += chunk.length;
            if (length > maxConversationImageBytesPerFile) {
              throw const _ClipboardImageTooLarge();
            }
            bytes.add(chunk);
          }
          if (!completer.isCompleted) {
            completer.complete(bytes.takeBytes());
          }
        } on Object catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    if (progress == null && !completer.isCompleted) {
      completer.complete(null);
    }
    return completer.future;
  }
}

final class ClientClipboardImageReadResult {
  const ClientClipboardImageReadResult.absent()
    : available = false,
      bytes = null,
      mediaType = '',
      failureCode = '';

  const ClientClipboardImageReadResult.success({
    required this.bytes,
    required this.mediaType,
  }) : available = true,
       failureCode = '';

  const ClientClipboardImageReadResult.failure(this.failureCode)
    : available = true,
      bytes = null,
      mediaType = '';

  final bool available;
  final Uint8List? bytes;
  final String mediaType;
  final String failureCode;

  bool get succeeded => bytes != null && failureCode.isEmpty;
}

final class ClientClipboardAttachmentResult {
  const ClientClipboardAttachmentResult.absent()
    : consumed = false,
      attachment = null,
      failureCode = '';

  const ClientClipboardAttachmentResult.success(this.attachment)
    : consumed = true,
      failureCode = '';

  const ClientClipboardAttachmentResult.failure(this.failureCode)
    : consumed = true,
      attachment = null;

  final bool consumed;
  final ConversationAttachment? attachment;
  final String failureCode;

  bool get succeeded => attachment != null && failureCode.isEmpty;
}

final class _ClipboardImageTooLarge implements Exception {
  const _ClipboardImageTooLarge();
}

String _mediaTypeForFormat(rich_clipboard.FileFormat format) =>
    switch (format) {
      rich_clipboard.Formats.png => 'image/png',
      rich_clipboard.Formats.jpeg => 'image/jpeg',
      rich_clipboard.Formats.gif => 'image/gif',
      rich_clipboard.Formats.webp => 'image/webp',
      _ => '',
    };

String _extensionForMediaType(String mediaType) => switch (mediaType) {
  'image/png' => 'png',
  'image/jpeg' => 'jpg',
  'image/gif' => 'gif',
  'image/webp' => 'webp',
  _ => '',
};
