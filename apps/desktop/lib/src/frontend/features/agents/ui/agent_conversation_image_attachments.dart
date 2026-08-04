import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Messaging-style rendering of a message's image attachments: bounded
/// inline frames (rounded, aspect preserved) stacked vertically, each with a
/// loading placeholder, a graceful unavailable placeholder, and a tap-to-view
/// dialog. Rendering is local-only — inline base64 decodes in memory and
/// nothing is fetched over the network. File-path sources render the
/// unavailable placeholder until a platform-root byte provider exists
/// (frontend UI must not touch the file system directly).
class AgentConversationImageAttachmentList extends StatelessWidget {
  const AgentConversationImageAttachmentList({
    super.key,
    required this.images,
    this.maxWidth = 340,
    this.maxHeight = 280,
  });

  final List<AgentConversationImageAttachment> images;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < images.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          ConversationImageAttachmentFrame(
            key: ValueKey<String>('conversation-image-attachment-$index'),
            attachment: images[index],
            maxWidth: maxWidth,
            maxHeight: maxHeight,
          ),
        ],
      ],
    );
  }
}

/// One bounded image frame with loading, error, and tap-to-view behavior.
class ConversationImageAttachmentFrame extends StatelessWidget {
  const ConversationImageAttachmentFrame({
    super.key,
    required this.attachment,
    required this.maxWidth,
    required this.maxHeight,
  });

  final AgentConversationImageAttachment attachment;
  final double maxWidth;
  final double maxHeight;

  ImageProvider? _resolveProvider() {
    if (attachment.dataBase64.isNotEmpty) {
      try {
        return MemoryImage(base64Decode(attachment.dataBase64));
      } on FormatException {
        return null;
      }
    }
    // File-path sources resolve through the platform root in a later step;
    // frontend UI never touches the file system directly.
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final label = attachment.name.isEmpty
        ? strings.imageAttachment
        : attachment.name;
    final provider = _resolveProvider();
    if (provider == null) {
      return ConversationImageUnavailablePlaceholder(
        maxWidth: maxWidth,
        label: label,
      );
    }
    final frame = _ConversationImageFrameDecoration(
      child: Image(
        image: provider,
        fit: BoxFit.contain,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            return child;
          }
          return ConversationImageLoadingPlaceholder(maxWidth: maxWidth);
        },
        errorBuilder: (context, error, stackTrace) =>
            ConversationImageUnavailablePlaceholder(
              maxWidth: maxWidth,
              label: label,
            ),
      ),
    );
    return Semantics(
      image: true,
      label: label,
      button: true,
      child: GestureDetector(
        key: const Key('conversation-image-attachment-frame'),
        behavior: HitTestBehavior.opaque,
        onTap: () => showConversationImageViewer(
          context,
          provider: provider,
          label: label,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
          child: frame,
        ),
      ),
    );
  }
}

/// Border + radius shared by image frames and their placeholders.
class _ConversationImageFrameDecoration extends StatelessWidget {
  const _ConversationImageFrameDecoration({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line.withAlpha(110)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// Transient placeholder while an image decodes.
class ConversationImageLoadingPlaceholder extends StatelessWidget {
  const ConversationImageLoadingPlaceholder({
    super.key,
    required this.maxWidth,
  });

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return _ConversationImageFrameDecoration(
      child: SizedBox(
        width: maxWidth * 0.6,
        height: 120,
        child: Center(
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: colors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Graceful fallback when an attachment's source cannot be rendered (missing
/// file, undecodable payload, or empty source). Never exposes the raw path.
class ConversationImageUnavailablePlaceholder extends StatelessWidget {
  const ConversationImageUnavailablePlaceholder({
    super.key,
    required this.maxWidth,
    required this.label,
  });

  final double maxWidth;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return _ConversationImageFrameDecoration(
      child: SizedBox(
        key: const Key('conversation-image-unavailable'),
        width: maxWidth * 0.6,
        height: 120,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.broken_image_outlined,
              size: 22,
              color: colors.textMuted,
            ),
            const SizedBox(height: 6),
            Text(
              strings.imageUnavailable,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen local viewer for one image attachment: dimmed barrier, fitted
/// image, tap anywhere to dismiss. Pinch zoom is intentionally out of scope.
void showConversationImageViewer(
  BuildContext context, {
  required ImageProvider provider,
  required String label,
}) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withAlpha(216),
    builder: (dialogContext) {
      final strings = LicoStrings.of(dialogContext);
      return GestureDetector(
        onTap: () => Navigator.of(dialogContext).pop(),
        child: Dialog(
          key: const Key('conversation-image-viewer'),
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960, maxHeight: 720),
            child: Semantics(
              image: true,
              label: label.isEmpty ? strings.imageAttachment : label,
              child: Image(
                image: provider,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  final colors = context.licoColors;
                  return Center(
                    child: Text(
                      strings.imageUnavailable,
                      style: TextStyle(color: colors.textMuted, fontSize: 13),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}
