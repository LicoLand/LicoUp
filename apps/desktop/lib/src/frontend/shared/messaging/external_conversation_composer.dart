import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';

/// Presentation-only InheritedScope marking that the host layout re-parents
/// the conversation composer outside the workspace (the Desktop dock capsule
/// input). When hosted, the workspace clips its internal composer away
/// through [ExternalConversationComposerClip]; mobile and the Dashboard
/// layout never provide this scope, so their composer behavior is untouched.
final class LayoutExternalComposerScope extends InheritedWidget {
  const LayoutExternalComposerScope({
    super.key,
    required this.hosted,
    this.hostedCapsules = false,
    required super.child,
  });

  final bool hosted;

  /// When true alongside [hosted], the host also owns the composer's
  /// Assistant and Adaptive Flywheel capsules (the Desktop expanded composer
  /// box pops them above the field), so the canonical pane suppresses its
  /// own copies.
  final bool hostedCapsules;

  static bool isHosted(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LayoutExternalComposerScope>()
          ?.hosted ??
      false;

  static bool hostsCapsules(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LayoutExternalComposerScope>()
          ?.hostedCapsules ??
      false;

  @override
  bool updateShouldNotify(LayoutExternalComposerScope oldWidget) =>
      oldWidget.hosted != hosted || oldWidget.hostedCapsules != hostedCapsules;
}

/// Hides the workspace's internal composer when the host layout re-parents
/// input into its own chrome. Renders the conversation pane taller than the
/// viewport by exactly the composer's laid-out height and clips the
/// overflow, so the composer (including multiline growth, tracked through
/// [SizeChangedLayoutNotification]) leaves the transcript, capsule row, and
/// header untouched above the clip line.
final class ExternalConversationComposerClip extends StatefulWidget {
  const ExternalConversationComposerClip({super.key, required this.child});

  final Widget child;

  @override
  State<ExternalConversationComposerClip> createState() =>
      _ExternalConversationComposerClipState();
}

final class _ExternalConversationComposerClipState
    extends State<ExternalConversationComposerClip> {
  final GlobalKey _boundaryKey = GlobalKey();
  double _hiddenExtent =
      MessagingDesktopMetrics.conversationComposerOverlayExtent;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final boundary = _boundaryKey.currentContext;
    if (boundary == null) return;
    double? composerHeight;
    void visit(Element element) {
      if (composerHeight != null) return;
      final key = element.widget.key;
      if (key is ValueKey<String> && key.value.startsWith('composer-')) {
        final renderObject = element.renderObject;
        if (renderObject is RenderBox && renderObject.hasSize) {
          composerHeight = renderObject.size.height;
        }
        return;
      }
      element.visitChildren(visit);
    }

    boundary.visitChildElements(visit);
    if (composerHeight == null) return;
    final extent = composerHeight!;
    if (extent != _hiddenExtent) {
      setState(() => _hiddenExtent = extent);
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _scheduleMeasure();
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedHeight) {
            return widget.child;
          }
          _scheduleMeasure();
          final extendedHeight = constraints.maxHeight + _hiddenExtent;
          return ClipRect(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: extendedHeight,
              maxHeight: extendedHeight,
              child: SizedBox(
                key: _boundaryKey,
                width: constraints.maxWidth,
                height: extendedHeight,
                child: widget.child,
              ),
            ),
          );
        },
      ),
    );
  }
}
