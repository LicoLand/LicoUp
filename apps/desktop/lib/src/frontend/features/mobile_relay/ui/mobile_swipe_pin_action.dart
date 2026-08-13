import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class MobileSwipePinAction extends StatefulWidget {
  const MobileSwipePinAction({
    super.key,
    required this.entryId,
    required this.pinned,
    required this.onTogglePinned,
    required this.child,
  });

  final String entryId;
  final bool pinned;
  final VoidCallback onTogglePinned;
  final Widget child;

  @override
  State<MobileSwipePinAction> createState() => _MobileSwipePinActionState();
}

final class _MobileSwipePinActionState extends State<MobileSwipePinAction> {
  static const double maxDragExtent = 84;
  static const double _openThreshold = 42;
  static const double _velocityThreshold = 420;

  double _revealExtent = 0;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      key: Key('mobile-home-swipe-${widget.entryId}'),
      borderRadius: BorderRadius.circular(8),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: _handleDragUpdate,
        onHorizontalDragEnd: _handleDragEnd,
        onHorizontalDragCancel: _resetDrag,
        child: Stack(
          children: [
            if (_revealExtent > 0)
              Positioned.fill(
                child: _MobilePinSwipeButton(
                  entryId: widget.entryId,
                  pinned: widget.pinned,
                  onPressed: _togglePinned,
                ),
              ),
            Transform.translate(
              offset: Offset(-_revealExtent, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final primaryDelta = details.primaryDelta ?? details.delta.dx;
    final next = (_revealExtent - primaryDelta).clamp(0, maxDragExtent);
    if (next == _revealExtent) return;
    setState(() => _revealExtent = next.toDouble());
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocityX = details.velocity.pixelsPerSecond.dx;
    final shouldOpen =
        _revealExtent >= _openThreshold || velocityX <= -_velocityThreshold;
    final shouldClose = velocityX >= _velocityThreshold;
    if (shouldOpen && !shouldClose) {
      _openAction();
    } else {
      _resetDrag();
    }
  }

  void _resetDrag() {
    if (_revealExtent == 0 || !mounted) return;
    setState(() => _revealExtent = 0);
  }

  void _openAction() {
    if (!mounted || _revealExtent == maxDragExtent) return;
    setState(() => _revealExtent = maxDragExtent);
  }

  void _togglePinned() {
    _resetDrag();
    widget.onTogglePinned();
  }
}

final class _MobilePinSwipeButton extends StatelessWidget {
  const _MobilePinSwipeButton({
    required this.entryId,
    required this.pinned,
    required this.onPressed,
  });

  final String entryId;
  final bool pinned;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final label = pinned ? strings.unpinFromTop : strings.pinToTop;
    return Semantics(
      button: true,
      label: label,
      child: Container(
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: colors.brandSurface.withAlpha(pinned ? 80 : 140),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SizedBox(
          width: _MobileSwipePinActionState.maxDragExtent,
          child: IconButton(
            key: Key('mobile-home-pin-$entryId'),
            tooltip: label,
            onPressed: onPressed,
            icon: Icon(
              pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              color: colors.accent,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}
