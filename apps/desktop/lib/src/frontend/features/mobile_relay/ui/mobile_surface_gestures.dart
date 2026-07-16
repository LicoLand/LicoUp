import 'package:flutter/material.dart';

class SwipeableMobileAgentSurface extends StatelessWidget {
  const SwipeableMobileAgentSurface({
    super.key,
    required this.child,
    required this.onSwipeRight,
    required this.onSwipeLeft,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final Widget child;
  final VoidCallback onSwipeRight;
  final VoidCallback? onSwipeLeft;
  final ValueChanged<DragStartDetails> onDragStart;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final void Function(DragEndDetails, VoidCallback, VoidCallback?) onDragEnd;
  final VoidCallback onDragCancel;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: onDragStart,
      onHorizontalDragUpdate: onDragUpdate,
      onHorizontalDragEnd: (details) =>
          onDragEnd(details, onSwipeRight, onSwipeLeft),
      onHorizontalDragCancel: onDragCancel,
      child: child,
    );
  }
}
