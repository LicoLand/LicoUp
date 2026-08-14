import 'package:licoup/src/contracts/conversation_image_byte_reader.dart';

/// Immutable typed local-image attachment captured from a picker selection.
///
/// [id] is a stable selection id, [name] the display name, [mediaType] one of
/// the supported image media types, and [path] the private local absolute
/// path. The path is used only by the native send admission and the
/// platform-root byte reader; it is never placed in prompt text, errors, or
/// renderer-facing projections.
final class ConversationAttachment {
  const ConversationAttachment({
    required this.id,
    required this.name,
    required this.mediaType,
    required this.path,
  });

  final String id;
  final String name;
  final String mediaType;
  final String path;

  Map<String, String> toJson() => <String, String>{
    'id': id,
    'name': name,
    'mediaType': mediaType,
    'path': path,
  };
}

/// Releases platform-owned attachment resources after the application has
/// finished with a conversation scope. User-selected files are never owned by
/// the client and therefore remain untouched by the platform implementation.
abstract interface class ConversationAttachmentRelease {
  Future<void> releaseAttachments(Iterable<ConversationAttachment> attachments);
}

/// Media type for a picked extension, or empty when unsupported.
String conversationAttachmentMediaTypeForExtension(String extension) =>
    conversationImageMediaTypeForExtension(extension);

/// Stable redacted status codes for picker outcomes. The codes are rendered
/// through the existing localized status projection; no private path or raw
/// picker error text is ever projected.
const String conversationAttachmentStatusCancelled =
    'attachment_picker_cancelled';
const String conversationAttachmentStatusFailed = 'attachment_picker_failed';
const String conversationAttachmentStatusLimit = 'attachment_list_limit';
