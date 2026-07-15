import 'package:flutter/material.dart';

/// Studio-private copy of the frozen Safari-like desktop chrome measurements.
abstract final class StudioDesktopChromeMetrics {
  static const double searchFieldHeight = 28;
  static const double searchButtonSize = 32;
  static const double searchButtonEdgeInset = 8;
  static const double searchCornerRadius = 10;

  static double get windowCornerRadius =>
      (searchButtonSize / 2) + searchButtonEdgeInset;

  static double get topBarHeight =>
      searchButtonSize + (searchButtonEdgeInset * 2);

  static BorderRadius get windowBorderRadius =>
      BorderRadius.circular(windowCornerRadius);
}
