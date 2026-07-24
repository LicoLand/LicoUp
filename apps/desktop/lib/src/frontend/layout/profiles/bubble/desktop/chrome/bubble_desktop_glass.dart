import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';

/// Bubble-owned control measurements for its desktop chrome.
abstract final class BubbleDesktopControlMetrics {
  static const double searchFieldHeight = 28;
  static const double searchButtonSize = 32;
  static const double searchButtonEdgeInset = 8;
  static const double menuCornerRadius = 10;
  static const double controlCornerRadius = 8;
  static const double hairline = 0.5;

  static double get searchButtonRadius => searchButtonSize / 2;

  static double get windowCornerRadius =>
      searchButtonRadius + searchButtonEdgeInset;

  static double get topBarHeight =>
      searchButtonSize + (searchButtonEdgeInset * 2);

  static double get searchCornerRadius => menuCornerRadius;

  static BorderRadius get windowBorderRadius =>
      BorderRadius.circular(windowCornerRadius);
}

/// Bubble's private translucent surface implementation.
final class BubbleDesktopGlassSurface extends StatelessWidget {
  const BubbleDesktopGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(BubbleDesktopControlMetrics.controlCornerRadius),
    ),
    this.blurSigma = 18,
    this.fillAlpha,
    this.borderAlpha,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final int? fillAlpha;
  final int? borderAlpha;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final palette = context.layoutPalette;
    final fill = palette.isDark
        ? Colors.white.withAlpha(fillAlpha ?? 22)
        : Colors.black.withAlpha(fillAlpha ?? 10);
    final border = Colors.white.withAlpha(
      borderAlpha ?? (palette.isDark ? 48 : 70),
    );

    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: BorderSide(
          color: border,
          width: BubbleDesktopControlMetrics.hairline,
        ),
      ),
      clipBehavior: clipBehavior,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: ColoredBox(color: fill, child: child),
      ),
    );
  }
}
