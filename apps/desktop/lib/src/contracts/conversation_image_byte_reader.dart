library;

import 'dart:typed_data';

/// Bounded attachment byte contract shared by the native send path and the
/// renderer. The renderer (frontend) and every controller depend only on this
/// narrow contract; the platform-root implementation is the only code that
/// ever touches the file system.

/// Maximum attachment count per conversation send (mirrors the native bound).
const int maxConversationImageAttachments = 4;

/// Per-file byte budget (4 MiB) for local image attachments.
const int maxConversationImageBytesPerFile = 4 * 1024 * 1024;

/// Total byte budget (16 MiB) across one conversation send.
const int maxConversationImageBytesTotal = 16 * 1024 * 1024;

const Set<String> supportedConversationImageMediaTypes = <String>{
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
};

/// Stable redacted failure codes returned by the platform byte reader. A code
/// is intentionally a plain identifier: the renderer maps it to localized
/// text and never receives the private path.
const String conversationAttachmentFailureFileUnavailable =
    'attachment_file_unavailable';
const String conversationAttachmentFailureSymlinkRejected =
    'attachment_symlink_rejected';
const String conversationAttachmentFailureNotRegularFile =
    'attachment_not_regular_file';
const String conversationAttachmentFailureMediaUnsupported =
    'attachment_media_unsupported';
const String conversationAttachmentFailureSignatureMismatch =
    'attachment_signature_mismatch';
const String conversationAttachmentFailureSizeLimit = 'attachment_size_limit';

/// Media type for a picked file extension, or empty when unsupported.
String conversationImageMediaTypeForExtension(String extension) {
  final normalized = extension.trim().toLowerCase();
  return switch (normalized) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    _ => '',
  };
}

/// Signature check against the declared media type. [bytes] may contain the
/// whole file or only its leading prefix; a short prefix fails closed.
bool conversationImageSignatureMatches(List<int> bytes, String mediaType) {
  final prefix = bytes;
  return switch (mediaType) {
    'image/png' =>
      prefix.length >= 8 &&
          prefix[0] == 0x89 &&
          prefix[1] == 0x50 &&
          prefix[2] == 0x4E &&
          prefix[3] == 0x47 &&
          prefix[4] == 0x0D &&
          prefix[5] == 0x0A &&
          prefix[6] == 0x1A &&
          prefix[7] == 0x0A,
    'image/jpeg' =>
      prefix.length >= 3 &&
          prefix[0] == 0xFF &&
          prefix[1] == 0xD8 &&
          prefix[2] == 0xFF,
    'image/gif' =>
      prefix.length >= 4 &&
          prefix[0] == 0x47 &&
          prefix[1] == 0x49 &&
          prefix[2] == 0x46 &&
          prefix[3] == 0x38,
    'image/webp' =>
      prefix.length >= 12 &&
          prefix[0] == 0x52 &&
          prefix[1] == 0x49 &&
          prefix[2] == 0x46 &&
          prefix[3] == 0x46 &&
          prefix[8] == 0x57 &&
          prefix[9] == 0x45 &&
          prefix[10] == 0x42 &&
          prefix[11] == 0x50,
    _ => false,
  };
}

/// Immutable bounded byte result of one attachment read. [failureCode] is a
/// stable redacted code; exactly one of [bytes] or [failureCode] is set.
final class ConversationImageReadResult {
  const ConversationImageReadResult.success(this.bytes) : failureCode = '';

  const ConversationImageReadResult.failure(this.failureCode) : bytes = null;

  final Uint8List? bytes;
  final String failureCode;

  bool get succeeded => bytes != null && failureCode.isEmpty;
}

/// Narrow platform-root reader. Implementations must follow the same
/// no-follow, regular-file, signature, and byte-budget rules as the native
/// send admission and must never expose the private path in an error.
abstract interface class ConversationImageByteReader {
  Future<ConversationImageReadResult> read({
    required String localPath,
    required String mediaType,
  });
}
