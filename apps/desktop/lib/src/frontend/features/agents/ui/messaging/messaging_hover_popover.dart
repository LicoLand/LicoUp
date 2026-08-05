import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';

/// Hover-revealed floating card anchored to a trigger. The card stays open while
/// the pointer is over the trigger or card, dismisses shortly after leave, and
/// can be tap-pinned for accessibility and touch surfaces.
class MessagingHoverPopover extends StatefulWidget {
  const MessagingHoverPopover({
    super.key,
    required this.triggerBuilder,
    required this.cardBuilder,
    this.readabilityVeil = true,
    this.wrapInGlass = true,
    this.width,
    this.maxWidth,
    this.maxHeight = 420,
    this.borderRadius,
    this.targetAnchor = Alignment.bottomRight,
    this.followerAnchor = Alignment.topRight,
    this.offset = const Offset(0, 6),
    this.popoverKey,
  });

  /// Builds the trigger; [open] reflects hover/tap visibility and [toggle] /
  /// [close] control the card.
  final Widget Function(
    BuildContext context, {
    required bool open,
    required VoidCallback toggle,
    required VoidCallback close,
  })
  triggerBuilder;

  /// Builds the card body; call [close] after a selection dismisses the card.
  final Widget Function(BuildContext context, VoidCallback close) cardBuilder;

  final bool readabilityVeil;

  /// When false, [cardBuilder] supplies its own chrome (e.g. two separate
  /// glass cards). The overlay still shrink-wraps and hit-tests the body.
  final bool wrapInGlass;
  final double? width;

  /// Upper bound when [width] is null. Defaults to the compact popover cap.
  final double? maxWidth;
  final double maxHeight;
  final BorderRadius? borderRadius;
  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final Offset offset;
  final Key? popoverKey;

  @override
  State<MessagingHoverPopover> createState() => MessagingHoverPopoverState();

  /// Cap unbound overlay width so glass cards cannot span the full window.
  static double _defaultMaxWidth(BuildContext context) {
    final viewWidth = MediaQuery.sizeOf(context).width;
    return viewWidth < 420 ? viewWidth - 24 : 420;
  }
}

class MessagingHoverPopoverState extends State<MessagingHoverPopover> {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _portalController = OverlayPortalController();
  bool _pinnedOpen = false;
  bool _hoveringTrigger = false;
  bool _hoveringCard = false;
  Timer? _dismissTimer;

  static const Duration _dismissGrace = Duration(milliseconds: 180);

  bool get isOpen => _pinnedOpen || _hoveringTrigger || _hoveringCard;

  void close() {
    _dismissTimer?.cancel();
    setState(() {
      _pinnedOpen = false;
      _hoveringTrigger = false;
      _hoveringCard = false;
    });
    _hidePortal();
  }

  void toggle() {
    _dismissTimer?.cancel();
    setState(() {
      if (isOpen) {
        _pinnedOpen = false;
        _hoveringTrigger = false;
        _hoveringCard = false;
      } else {
        _pinnedOpen = true;
      }
    });
    _syncPortal();
  }

  void _syncPortal() {
    if (isOpen) {
      if (!_portalController.isShowing) {
        _portalController.show();
      }
    } else {
      _hidePortal();
    }
  }

  void _hidePortal() {
    if (_portalController.isShowing) {
      _portalController.hide();
    }
  }

  void _scheduleDismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(_dismissGrace, () {
      if (!mounted) {
        return;
      }
      if (_hoveringTrigger || _hoveringCard || _pinnedOpen) {
        return;
      }
      setState(_hidePortal);
    });
  }

  void _onTriggerEnter(PointerEnterEvent _) {
    _dismissTimer?.cancel();
    setState(() {
      _hoveringTrigger = true;
    });
    _syncPortal();
  }

  void _onTriggerExit(PointerExitEvent _) {
    setState(() {
      _hoveringTrigger = false;
    });
    if (!_pinnedOpen) {
      _scheduleDismiss();
    }
  }

  void _onCardEnter(PointerEnterEvent _) {
    _dismissTimer?.cancel();
    setState(() {
      _hoveringCard = true;
    });
    _syncPortal();
  }

  void _onCardExit(PointerExitEvent _) {
    setState(() {
      _hoveringCard = false;
    });
    if (!_pinnedOpen) {
      _scheduleDismiss();
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  Widget _buildOverlayCard(BuildContext context, BorderRadius radius) {
    final body = SizedBox(
      key: widget.popoverKey,
      width: widget.width,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth:
              widget.width ??
              widget.maxWidth ??
              MessagingHoverPopover._defaultMaxWidth(context),
          maxHeight: widget.maxHeight,
        ),
        child: widget.cardBuilder(context, close),
      ),
    );
    if (!widget.wrapInGlass) {
      return body;
    }
    return MessagingConversationOverlayGlass(
      borderRadius: radius,
      readabilityVeil: widget.readabilityVeil,
      child: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final radius =
        widget.borderRadius ??
        BorderRadius.circular(AppleControlMetrics.menuCornerRadius);

    return OverlayPortal(
      controller: _portalController,
      overlayChildBuilder: (context) {
        // The overlay lays its child out with tight full-screen constraints.
        // [followerAnchor] resolves against the follower's own size, so the
        // follower must shrink-wrap the card; otherwise every anchor is
        // computed on a full-screen box and the card lands in a window corner
        // instead of beside the trigger. Align loosens the constraints while
        // keeping the follower's linked transform authoritative.
        return Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _layerLink,
            targetAnchor: widget.targetAnchor,
            followerAnchor: widget.followerAnchor,
            offset: widget.offset,
            showWhenUnlinked: false,
            child: MouseRegion(
              onEnter: _onCardEnter,
              onExit: _onCardExit,
              child: Material(
                color: Colors.transparent,
                elevation: 0,
                child: _buildOverlayCard(context, radius),
              ),
            ),
          ),
        );
      },
      child: CompositedTransformTarget(
        link: _layerLink,
        child: MouseRegion(
          onEnter: _onTriggerEnter,
          onExit: _onTriggerExit,
          child: widget.triggerBuilder(
            context,
            open: isOpen,
            toggle: toggle,
            close: close,
          ),
        ),
      ),
    );
  }
}
