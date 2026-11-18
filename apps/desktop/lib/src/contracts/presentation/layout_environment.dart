enum LayoutRuntimeSurface { desktop, mobile }

enum LayoutViewportClass { compact, medium, expanded }

/// The finite viewport product supported by each runtime surface.
abstract final class LayoutViewportPolicy {
  static const double mobileMediumBreakpoint = 600;
  static const double desktopExpandedBreakpoint = 1024;

  static const Set<LayoutViewportClass> _desktop = {
    LayoutViewportClass.medium,
    LayoutViewportClass.expanded,
  };
  static const Set<LayoutViewportClass> _mobile = {
    LayoutViewportClass.compact,
    LayoutViewportClass.medium,
  };

  static Set<LayoutViewportClass> supportedFor(LayoutRuntimeSurface surface) =>
      switch (surface) {
        LayoutRuntimeSurface.desktop => _desktop,
        LayoutRuntimeSurface.mobile => _mobile,
      };

  static bool supports(
    LayoutRuntimeSurface surface,
    LayoutViewportClass viewport,
  ) => supportedFor(surface).contains(viewport);

  static LayoutViewportClass classify({
    required LayoutRuntimeSurface surface,
    required double width,
  }) {
    if (!width.isFinite || width < 0) {
      throw const FormatException('layout_environment_width_invalid');
    }
    return switch (surface) {
      LayoutRuntimeSurface.desktop =>
        width < desktopExpandedBreakpoint
            ? LayoutViewportClass.medium
            : LayoutViewportClass.expanded,
      LayoutRuntimeSurface.mobile =>
        width < mobileMediumBreakpoint
            ? LayoutViewportClass.compact
            : LayoutViewportClass.medium,
    };
  }
}

final class LayoutInsets {
  factory LayoutInsets({
    double left = 0,
    double top = 0,
    double right = 0,
    double bottom = 0,
  }) {
    final values = [left, top, right, bottom];
    if (values.any((value) => !value.isFinite || value < 0)) {
      throw const FormatException('layout_environment_insets_invalid');
    }
    return LayoutInsets._(left: left, top: top, right: right, bottom: bottom);
  }

  const LayoutInsets._({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  static const zero = LayoutInsets._();

  final double left;
  final double top;
  final double right;
  final double bottom;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutInsets &&
          other.left == left &&
          other.top == top &&
          other.right == right &&
          other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Immutable facts used to resolve and render one profile variant.
final class LayoutEnvironment {
  factory LayoutEnvironment.fromConstraints({
    required LayoutRuntimeSurface surface,
    required double width,
    required double height,
    required double textScale,
    LayoutInsets safeInsets = LayoutInsets.zero,
    double keyboardInset = 0,
    bool hasPointer = false,
    bool hasKeyboard = false,
    bool hasTouch = false,
    bool reducedMotion = false,
  }) {
    _validateMetrics(
      width: width,
      height: height,
      textScale: textScale,
      keyboardInset: keyboardInset,
    );
    return LayoutEnvironment._(
      surface: surface,
      viewport: LayoutViewportPolicy.classify(surface: surface, width: width),
      width: width,
      height: height,
      textScale: textScale,
      safeInsets: safeInsets,
      keyboardInset: keyboardInset,
      hasPointer: hasPointer,
      hasKeyboard: hasKeyboard,
      hasTouch: hasTouch,
      reducedMotion: reducedMotion,
    );
  }

  const LayoutEnvironment._({
    required this.surface,
    required this.viewport,
    required this.width,
    required this.height,
    required this.textScale,
    required this.safeInsets,
    required this.keyboardInset,
    required this.hasPointer,
    required this.hasKeyboard,
    required this.hasTouch,
    required this.reducedMotion,
  });

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

  static void _validateMetrics({
    required double width,
    required double height,
    required double textScale,
    required double keyboardInset,
  }) {
    if (!width.isFinite || width < 0 || !height.isFinite || height < 0) {
      throw const FormatException('layout_environment_size_invalid');
    }
    if (!textScale.isFinite || textScale <= 0) {
      throw const FormatException('layout_environment_text_scale_invalid');
    }
    if (!keyboardInset.isFinite || keyboardInset < 0) {
      throw const FormatException('layout_environment_keyboard_inset_invalid');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutEnvironment &&
          other.surface == surface &&
          other.viewport == viewport &&
          other.width == width &&
          other.height == height &&
          other.textScale == textScale &&
          other.safeInsets == safeInsets &&
          other.keyboardInset == keyboardInset &&
          other.hasPointer == hasPointer &&
          other.hasKeyboard == hasKeyboard &&
          other.hasTouch == hasTouch &&
          other.reducedMotion == reducedMotion;

  @override
  int get hashCode => Object.hash(
    surface,
    viewport,
    width,
    height,
    textScale,
    safeInsets,
    keyboardInset,
    hasPointer,
    hasKeyboard,
    hasTouch,
    reducedMotion,
  );
}
