import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Transient confirmation capsule for the messaging conversation surfaces.
///
/// Shows a bottom-anchored toast that reuses the messaging failure/processing
/// capsule's visual language — [MessagingConversationOverlayGlass] fill with
/// a hairline border, a status icon slot, and the optional top-edge pulse —
/// so ephemeral confirmations (copy feedback) read as the same chrome as the
/// inline status capsule. Failures themselves stay inline in the conversation;
/// this toast is only for brief confirmations.
///
/// The toast is inserted into the root [Overlay] rather than a
/// [ScaffoldMessenger] snackbar: it never queues behind other snackbars, does
/// not depend on a surrounding [Scaffold], and paints above hover popovers the
/// messenger would sit beneath. It auto-dismisses after [showDuration] and any
/// tap on the capsule dismisses it early. It covers only its own small area
/// and ignores taps outside, so it never blocks the conversation flow.
void showMessagingStatusCapsuleToast(
  BuildContext context, {
  required String message,
  IconData icon = Icons.check_circle_rounded,
  Color? iconColor,
  bool pulse = false,
  Duration showDuration = const Duration(milliseconds: 2000),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  // One capsule at a time: a fresh confirmation replaces an earlier toast
  // instead of stacking duplicates at the same bottom anchor.
  final previous = _activeEntry;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    opaque: false,
    maintainState: false,
    builder: (overlayContext) => _MessagingStatusCapsuleToastHost(
      message: message,
      icon: icon,
      iconColor: iconColor,
      pulse: pulse,
      showDuration: showDuration,
      onDismissed: () {
        if (identical(_activeEntry, entry)) {
          _activeEntry = null;
        }
        if (entry.mounted) {
          entry.remove();
        }
      },
    ),
  );
  _activeEntry = entry;
  if (previous != null && previous.mounted) {
    previous.remove();
  }
  overlay.insert(entry);
}

/// The toast currently on screen, replaced by each new confirmation.
OverlayEntry? _activeEntry;

/// Corner radius shared with the inline status capsule
/// (`MessagingProcessStatusRow`), so the toast reads as the same capsule.
const double _capsuleCornerRadius = 10;

class _MessagingStatusCapsuleToastHost extends StatefulWidget {
  const _MessagingStatusCapsuleToastHost({
    required this.message,
    required this.icon,
    required this.iconColor,
    required this.pulse,
    required this.showDuration,
    required this.onDismissed,
  });

  final String message;
  final IconData icon;
  final Color? iconColor;
  final bool pulse;
  final Duration showDuration;
  final VoidCallback onDismissed;

  @override
  State<_MessagingStatusCapsuleToastHost> createState() =>
      _MessagingStatusCapsuleToastHostState();
}

class _MessagingStatusCapsuleToastHostState
    extends State<_MessagingStatusCapsuleToastHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _autoDismissTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
    )..forward();
    _autoDismissTimer = Timer(widget.showDuration, _dismiss);
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _autoDismissTimer?.cancel();
    if (!mounted || _dismissing) {
      return;
    }
    _dismissing = true;
    _controller.reverse().whenComplete(widget.onDismissed);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final media = MediaQuery.of(context);
    final borderRadius = BorderRadius.circular(_capsuleCornerRadius);
    final entrance = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final capsule = Semantics(
      container: true,
      liveRegion: true,
      label: widget.message,
      child: LicoTopEdgePulse(
        key: const Key('messaging-status-capsule-pulse'),
        enabled: widget.pulse,
        borderRadius: borderRadius,
        color: colors.text.withAlpha(colors.isDark ? 90 : 70),
        child: GestureDetector(
          key: const Key('messaging-status-capsule-toast'),
          behavior: HitTestBehavior.opaque,
          onTap: _dismiss,
          child: MessagingConversationOverlayGlass(
            borderRadius: borderRadius,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    key: const Key('messaging-status-capsule-icon'),
                    widget.icon,
                    size: 15,
                    color: widget.iconColor ?? colors.success,
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: Text(
                      widget.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.04,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + media.padding.bottom),
        child: FadeTransition(
          opacity: entrance,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(entrance),
            child: capsule,
          ),
        ),
      ),
    );
  }
}
