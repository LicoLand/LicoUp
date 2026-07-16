import 'package:flutter/material.dart';

/// Apple-leaning control metrics shared by chrome and themed controls.
///
/// This foundation deliberately has no dependency on the Lico theme or any
/// concrete Apple widget, so layout constants can be reused without creating
/// a theme/widget dependency cycle.
abstract final class AppleControlMetrics {
  static const double searchFieldWidth = 228;
  static const double searchFieldHeight = 28;

  /// Collapsed shell search control (circular icon button).
  ///
  /// Sized so it can nest concentrically in the window corner with equal
  /// top/trailing insets (macOS toolbar concentricity).
  static const double searchButtonSize = 32;

  /// Equal inset from the window's top and trailing edges around the
  /// collapsed search circle.
  static const double searchButtonEdgeInset = 8;

  static double get searchButtonRadius => searchButtonSize / 2;

  /// Outer window corner radius for concentric nesting: R = r + inset.
  static double get windowCornerRadius =>
      searchButtonRadius + searchButtonEdgeInset;

  /// Desktop top bar height: search circle + equal vertical insets.
  static double get topBarHeight =>
      searchButtonSize + (searchButtonEdgeInset * 2);

  /// Menu / overlay panel corner radius (search results, notifications).
  static const double menuCornerRadius = 10;

  /// Shell search field matches the menu panel rounded-rect language.
  static const double searchCornerRadius = menuCornerRadius;
  static const double controlCornerRadius = 8;
  static const double hairline = 0.5;
  static const double searchFocusRingWidth = 2;

  static BorderRadius get searchFieldBorderRadius =>
      BorderRadius.circular(searchCornerRadius);

  static BorderRadius get windowBorderRadius =>
      BorderRadius.circular(windowCornerRadius);
}

bool isAppleClientTargetPlatform(TargetPlatform platform) {
  return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
}

bool isAppleClientPlatform(BuildContext context) {
  return isAppleClientTargetPlatform(Theme.of(context).platform);
}
