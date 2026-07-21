import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';

const nativeMobileStyleIdentity = 'glassy-rail-native';
const nativeMobileRestorationPrefix = 'native.mobile';

final LayoutVisualTokens nativeMobileVisualTokens = LayoutVisualTokens(
  spacingUnit: 4,
  density: 0.72,
  cardRadius: 5,
  elevation: 0,
  navigationExtent: 68,
  contentMaxWidth: 920,
  typographyScale: 0.9,
  motionDuration: const Duration(milliseconds: 140),
);

/// Non-color measurements for the dense mobile Native presentation.
abstract final class NativeMobileMetrics {
  static const double compactHeaderMinExtent = 52;
  static const double compactHeaderMaxExtent = 64;
  static const double compactHeaderTextScaleCeiling = 2.5;
  static const double compactHeaderEyebrowFontSize = 9;
  static const double compactHeaderTitleFontSize = 13;
  static const double compactHeaderTitleHeight = 1.05;
  static const double compactHeaderLineGap = 3;
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

  static double compactHeaderExtentFor(double textScale) {
    if (!textScale.isFinite || textScale <= 0) {
      throw const FormatException('native_mobile_text_scale_invalid');
    }
    final effectiveScale = textScale > compactHeaderTextScaleCeiling
        ? compactHeaderTextScaleCeiling
        : textScale;
    final eyebrowExtent = (compactHeaderEyebrowFontSize * effectiveScale)
        .ceilToDouble();
    final titleExtent =
        (compactHeaderTitleFontSize * compactHeaderTitleHeight * effectiveScale)
            .ceilToDouble();
    final requiredExtent = eyebrowExtent + compactHeaderLineGap + titleExtent;
    return requiredExtent
        .clamp(compactHeaderMinExtent, compactHeaderMaxExtent)
        .toDouble();
  }

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
        : nativeMobileVisualTokens.motionDuration;
  }
}
