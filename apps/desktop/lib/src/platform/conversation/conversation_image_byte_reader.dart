import 'dart:io';
import 'dart:typed_data';

import 'package:licoup/src/contracts/conversation_image_byte_reader.dart';

/// Platform-root implementation of [ConversationImageByteReader]. This is the
/// only code that touches the file system for attachment bytes: it applies
/// the same no-follow, regular-file, signature, and byte-budget rules as the
/// native send admission and returns only bounded bytes or a stable redacted
/// code — never a path.
final class PlatformConversationImageByteReader
    implements ConversationImageByteReader {
  const PlatformConversationImageByteReader();

  static const ConversationImageByteReader instance =
      PlatformConversationImageByteReader();

  @override
  Future<ConversationImageReadResult> read({
    required String localPath,
    required String mediaType,
  }) async {
    if (!supportedConversationImageMediaTypes.contains(mediaType)) {
      return const ConversationImageReadResult.failure(
        conversationAttachmentFailureMediaUnsupported,
      );
    }
    final FileSystemEntityType entityType;
    try {
      entityType = await FileSystemEntity.type(localPath, followLinks: false);
    } on Object {
      return const ConversationImageReadResult.failure(
        conversationAttachmentFailureFileUnavailable,
      );
    }
    if (entityType == FileSystemEntityType.link) {
      return const ConversationImageReadResult.failure(
        conversationAttachmentFailureSymlinkRejected,
      );
    }
    if (entityType != FileSystemEntityType.file) {
      return const ConversationImageReadResult.failure(
        conversationAttachmentFailureNotRegularFile,
      );
    }
    final file = File(localPath);
    FileStat stat;
    try {
      stat = await file.stat();
    } on Object {
      return const ConversationImageReadResult.failure(
        conversationAttachmentFailureFileUnavailable,
      );
    }
    if (stat.size > maxConversationImageBytesPerFile) {
      return const ConversationImageReadResult.failure(
        conversationAttachmentFailureSizeLimit,
      );
    }
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(await file.readAsBytes());
    } on Object {
      return const ConversationImageReadResult.failure(
        conversationAttachmentFailureFileUnavailable,
      );
    }
    if (bytes.length > maxConversationImageBytesPerFile) {
      return const ConversationImageReadResult.failure(
        conversationAttachmentFailureSizeLimit,
      );
    }
    if (bytes.isEmpty || !conversationImageSignatureMatches(bytes, mediaType)) {
      return const ConversationImageReadResult.failure(
        conversationAttachmentFailureSignatureMismatch,
      );
    }
    return ConversationImageReadResult.success(bytes);
  }
}
