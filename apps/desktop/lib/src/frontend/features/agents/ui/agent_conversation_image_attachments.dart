import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

typedef ConversationImageLoader =
    Future<Uint8List?> Function({
      required String localPath,
      required String mediaType,
    });

/// Bounded content-addressed cache of decoded inline image bytes. Decoding
/// base64 inside [State.build] (the previous behavior) reran the decode on
/// every rebuild of a visible row; the decode now happens once per unique
/// payload inside the state's read-sync path and is reused across rebuilds and
/// across rows leaving and re-entering the viewport. Null entries record
/// undecodable payloads so broken attachments do not decode repeatedly.
final LinkedHashMap<String, Uint8List?> _inlineImageBytesCache =
    LinkedHashMap();
const int _inlineImageBytesCacheLimit = 24;

Uint8List? _decodedInlineImageBytes(String dataBase64) {
  if (_inlineImageBytesCache.containsKey(dataBase64)) {
    final bytes = _inlineImageBytesCache.remove(dataBase64);
    // Refresh recency: LRU eviction drops the least recently used entry.
    _inlineImageBytesCache[dataBase64] = bytes;
    return bytes;
  }
  Uint8List? bytes;
  try {
    bytes = base64Decode(dataBase64);
  } on FormatException {
    bytes = null;
  }
  if (_inlineImageBytesCache.length >= _inlineImageBytesCacheLimit) {
    _inlineImageBytesCache.remove(_inlineImageBytesCache.keys.first);
  }
  _inlineImageBytesCache[dataBase64] = bytes;
  return bytes;
}

class ConversationImageLoaderScope extends InheritedWidget {
  const ConversationImageLoaderScope({
    super.key,
    required this.loader,
    required super.child,
  });

  final ConversationImageLoader loader;

  static ConversationImageLoader? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ConversationImageLoaderScope>()
      ?.loader;

  @override
  bool updateShouldNotify(ConversationImageLoaderScope oldWidget) =>
      !identical(loader, oldWidget.loader);
}

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
class ConversationImageAttachmentFrame extends StatefulWidget {
  const ConversationImageAttachmentFrame({
    super.key,
    required this.attachment,
    required this.maxWidth,
    required this.maxHeight,
  });

  final AgentConversationImageAttachment attachment;
  final double maxWidth;
  final double maxHeight;

  @override
  State<ConversationImageAttachmentFrame> createState() =>
      _ConversationImageAttachmentFrameState();
}

class _ConversationImageAttachmentFrameState
    extends State<ConversationImageAttachmentFrame> {
  Future<Uint8List?>? _read;
  Object? _readKey;

  AgentConversationImageAttachment get attachment => widget.attachment;
  double get maxWidth => widget.maxWidth;
  double get maxHeight => widget.maxHeight;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRead();
  }

  @override
  void didUpdateWidget(covariant ConversationImageAttachmentFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRead();
  }

  void _syncRead() {
    final loader = ConversationImageLoaderScope.maybeOf(context);
    final path = attachment.filePath.trim();
    final base64 = attachment.dataBase64;
    final key = (loader, path, attachment.mediaType, base64);
    if (_readKey == key) return;
    _readKey = key;
    // Inline base64 decodes outside the build path now; an undecodable inline
    // payload keeps the legacy fallback to the file-backed loader.
    if (base64.isNotEmpty) {
      final bytes = _decodedInlineImageBytes(base64);
      if (bytes != null) {
        _read = SynchronousFuture<Uint8List?>(bytes);
        return;
      }
    }
    _read = _loadFileBytes(loader, path);
  }

  Future<Uint8List?>? _loadFileBytes(
    ConversationImageLoader? loader,
    String path,
  ) {
    if (loader == null || path.isEmpty) {
      return null;
    }
    return loader(localPath: path, mediaType: attachment.mediaType);
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final label = attachment.name.isEmpty
        ? strings.imageAttachment
        : attachment.name;
    final read = _read;
    if (read == null) {
      return ConversationImageUnavailablePlaceholder(
        maxWidth: maxWidth,
        label: label,
      );
    }
    return FutureBuilder<Uint8List?>(
      future: read,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return ConversationImageLoadingPlaceholder(maxWidth: maxWidth);
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return ConversationImageUnavailablePlaceholder(
            maxWidth: maxWidth,
            label: label,
          );
        }
        return _buildProvider(context, MemoryImage(bytes), label);
      },
    );
  }

  Widget _buildProvider(
    BuildContext context,
    ImageProvider provider,
    String label,
  ) {
    // Bound the inline decode: full-size captures would otherwise decode and
    // upload to the GPU at native resolution for a 340px frame. The tap-to-view
    // dialog keeps the unbounded provider.
    final inlineProvider = ResizeImage(
      provider,
      width: (maxWidth * MediaQuery.devicePixelRatioOf(context)).round().clamp(
        1,
        1 << 30,
      ),
    );
    final frame = _ConversationImageFrameDecoration(
      child: Image(
        image: inlineProvider,
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
        borderRadius: BorderRadius.circular(LicoRadius.card),
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
        key: const Key('conversation-image-viewer-dismiss'),
        behavior: HitTestBehavior.opaque,
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
