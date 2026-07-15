import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';

/// Dense, dock-oriented geometry for the Bubble desktop presentation system.
final LayoutVisualTokens bubbleDesktopTokens = LayoutVisualTokens(
  spacingUnit: 6,
  density: 0.72,
  cardRadius: 2,
  elevation: 0,
  navigationExtent: 224,
  contentMaxWidth: 1600,
  typographyScale: 0.92,
  motionDuration: const Duration(milliseconds: 120),
);

/// Profile-private measurements shared by Bubble shell and component recipes.
abstract final class BubbleDesktopMetrics {
  static const double hairline = 1;
  static const double compactRailExtent = 64;
  static const double minimumLabeledRailExtent = 176;
  static const double maximumRailExtent = 296;
  static const double railHeaderExtent = 54;
  static const double navigationItemExtent = 38;
  static const double toolbarExtent = 42;
  static const double fieldMinimumExtent = 32;
  static const double dialogMaximumWidth = 720;
}
