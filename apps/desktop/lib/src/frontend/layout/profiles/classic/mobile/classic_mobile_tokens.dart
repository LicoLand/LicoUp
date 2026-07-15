import 'dart:math' as math;

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';

const String classicMobileStyleIdentity = 'spacious-card-classic';
const String classicMobileRestorationPrefix = 'classic.mobile';

final LayoutVisualTokens classicMobileTokens = LayoutVisualTokens(
  spacingUnit: 8,
  density: 1,
  cardRadius: 24,
  elevation: 1,
  navigationExtent: 56,
  contentMaxWidth: 920,
  typographyScale: 1.04,
  motionDuration: const Duration(milliseconds: 220),
);

/// Classic-only measurements. Colors continue to come from the active
/// appearance theme so presentation identity and appearance stay orthogonal.
abstract final class ClassicMobileMetrics {
  static const double compactHorizontalPadding = 16;
  static const double mediumHorizontalPadding = 24;
  static const double minimumContentHeight = 96;
  static const double mediumNavigationWidth = 216;
  static const double composerBreathingRoom = 12;
  static const double compactStackGap = 12;
  static const double mediumStackGap = 20;
  static const double maximumTextScale = 3;

  static double interactiveExtent(LayoutEnvironment environment) {
    final base = environment.hasTouch ? 56.0 : 48.0;
    final keyboardAdjustment = environment.hasKeyboard ? 4.0 : 0.0;
    return math.max(
      classicMobileTokens.navigationExtent,
      base + keyboardAdjustment,
    );
  }

  static double horizontalPadding(LayoutEnvironment environment) {
    final base = switch (environment.viewport) {
      LayoutViewportClass.compact => compactHorizontalPadding,
      LayoutViewportClass.medium => mediumHorizontalPadding,
      LayoutViewportClass.expanded => mediumHorizontalPadding,
    };
    final pointerAdjustment = environment.hasPointer ? 4.0 : 0.0;
    return base + pointerAdjustment;
  }

  static double composerClearance(LayoutEnvironment environment) =>
      math.max(environment.safeInsets.bottom, environment.keyboardInset) +
      composerBreathingRoom;

  static double boundedTextScale(LayoutEnvironment environment) =>
      environment.textScale.clamp(1.0, maximumTextScale).toDouble();

  static Duration motionDuration(LayoutEnvironment environment) =>
      environment.reducedMotion
      ? Duration.zero
      : classicMobileTokens.motionDuration;
}
