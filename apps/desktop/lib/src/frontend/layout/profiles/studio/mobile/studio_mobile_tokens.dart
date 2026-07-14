import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';

const studioMobileStyleIdentity = 'dense-docked-studio';
const studioMobileRestorationPrefix = 'studio.mobile';

final LayoutVisualTokens studioMobileVisualTokens = LayoutVisualTokens(
  spacingUnit: 4,
  density: 0.72,
  cardRadius: 5,
  elevation: 0,
  navigationExtent: 68,
  contentMaxWidth: 920,
  typographyScale: 0.9,
  motionDuration: const Duration(milliseconds: 140),
);

/// Non-color measurements for the dense mobile Studio presentation.
abstract final class StudioMobileMetrics {
  static const double compactHeaderExtent = 52;
  static const double mediumRailExtent = 68;
  static const double compactDrawerMaxWidth = 304;
  static const double compactDrawerWidthFactor = 0.84;
  static const double touchTargetExtent = 48;
  static const double pointerTargetExtent = 42;
  static const double hairline = 1;
  static const double compactRadius = 9;
  static const double controlRadius = 5;
  static const double contentEdge = 8;
  static const double denseGap = 4;

  static double targetExtent(LayoutEnvironment environment) {
    return environment.hasTouch ? touchTargetExtent : pointerTargetExtent;
  }

  static EdgeInsets safeContentInsets(LayoutEnvironment environment) {
    final safe = environment.safeInsets;
    return EdgeInsets.fromLTRB(
      safe.left,
      safe.top,
      safe.right,
      keyboardClearance(environment),
    );
  }

  static double keyboardClearance(LayoutEnvironment environment) {
    return environment.keyboardInset > environment.safeInsets.bottom
        ? environment.keyboardInset
        : environment.safeInsets.bottom;
  }

  static Duration motion(LayoutEnvironment environment) {
    return environment.reducedMotion
        ? Duration.zero
        : studioMobileVisualTokens.motionDuration;
  }
}
