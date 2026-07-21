import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';

/// Quiet-luxury geometry for the Native desktop presentation system:
/// generous breathing room, soft radii, and unhurried motion.
final LayoutVisualTokens nativeDesktopTokens = LayoutVisualTokens(
  spacingUnit: 6,
  density: 0.9,
  cardRadius: 10,
  elevation: 0,
  navigationExtent: 64,
  contentMaxWidth: 1600,
  typographyScale: 0.95,
  motionDuration: const Duration(milliseconds: 160),
);

/// Profile-private measurements shared by Native shell and component recipes.
abstract final class NativeDesktopMetrics {
  static const double navigationItemExtent = 30;
  static const double minimumLabeledRailExtent = 168;
  static const double fieldMinimumExtent = 32;
  static const double dialogMaximumWidth = 720;
}
