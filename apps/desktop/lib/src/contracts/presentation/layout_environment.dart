enum LayoutRuntimeSurface { desktop, mobile }

enum LayoutViewportClass { compact, medium, expanded }

final class LayoutInsets {
  const LayoutInsets({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// Immutable facts used to resolve a profile variant.
final class LayoutEnvironment {
  const LayoutEnvironment({
    required this.surface,
    required this.viewport,
    required this.width,
    required this.height,
    required this.textScale,
    required this.safeInsets,
    this.keyboardInset = 0,
    this.hasPointer = false,
    this.hasKeyboard = false,
    this.hasTouch = false,
    this.reducedMotion = false,
  }) : assert(width >= 0),
       assert(height >= 0),
       assert(textScale > 0),
       assert(keyboardInset >= 0);

  final LayoutRuntimeSurface surface;
  final LayoutViewportClass viewport;
  final double width;
  final double height;
  final double textScale;
  final LayoutInsets safeInsets;
  final double keyboardInset;
  final bool hasPointer;
  final bool hasKeyboard;
  final bool hasTouch;
  final bool reducedMotion;

  static LayoutViewportClass classifyWidth(double width) {
    if (width < 600) {
      return LayoutViewportClass.compact;
    }
    if (width < 1024) {
      return LayoutViewportClass.medium;
    }
    return LayoutViewportClass.expanded;
  }
}
