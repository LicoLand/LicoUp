import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Non-color visual values owned by one complete layout profile.
final class LayoutVisualTokens extends ThemeExtension<LayoutVisualTokens> {
  factory LayoutVisualTokens({
    required double spacingUnit,
    required double density,
    required double cardRadius,
    required double elevation,
    required double navigationExtent,
    required double contentMaxWidth,
    required double typographyScale,
    required Duration motionDuration,
  }) {
    final values = [
      spacingUnit,
      density,
      cardRadius,
      elevation,
      navigationExtent,
      contentMaxWidth,
      typographyScale,
    ];
    if (values.any((value) => !value.isFinite || value < 0) ||
        typographyScale == 0 ||
        motionDuration.isNegative) {
      throw const FormatException('layout_visual_tokens_invalid');
    }
    return LayoutVisualTokens._(
      spacingUnit: spacingUnit,
      density: density,
      cardRadius: cardRadius,
      elevation: elevation,
      navigationExtent: navigationExtent,
      contentMaxWidth: contentMaxWidth,
      typographyScale: typographyScale,
      motionDuration: motionDuration,
    );
  }

  const LayoutVisualTokens._({
    required this.spacingUnit,
    required this.density,
    required this.cardRadius,
    required this.elevation,
    required this.navigationExtent,
    required this.contentMaxWidth,
    required this.typographyScale,
    required this.motionDuration,
  });

  final double spacingUnit;
  final double density;
  final double cardRadius;
  final double elevation;
  final double navigationExtent;
  final double contentMaxWidth;
  final double typographyScale;
  final Duration motionDuration;

  @override
  LayoutVisualTokens copyWith({
    double? spacingUnit,
    double? density,
    double? cardRadius,
    double? elevation,
    double? navigationExtent,
    double? contentMaxWidth,
    double? typographyScale,
    Duration? motionDuration,
  }) => LayoutVisualTokens(
    spacingUnit: spacingUnit ?? this.spacingUnit,
    density: density ?? this.density,
    cardRadius: cardRadius ?? this.cardRadius,
    elevation: elevation ?? this.elevation,
    navigationExtent: navigationExtent ?? this.navigationExtent,
    contentMaxWidth: contentMaxWidth ?? this.contentMaxWidth,
    typographyScale: typographyScale ?? this.typographyScale,
    motionDuration: motionDuration ?? this.motionDuration,
  );

  @override
  LayoutVisualTokens lerp(
    covariant ThemeExtension<LayoutVisualTokens>? other,
    double t,
  ) {
    if (other is! LayoutVisualTokens) {
      return this;
    }
    return LayoutVisualTokens(
      spacingUnit: lerpDouble(spacingUnit, other.spacingUnit, t)!,
      density: lerpDouble(density, other.density, t)!,
      cardRadius: lerpDouble(cardRadius, other.cardRadius, t)!,
      elevation: lerpDouble(elevation, other.elevation, t)!,
      navigationExtent: lerpDouble(
        navigationExtent,
        other.navigationExtent,
        t,
      )!,
      contentMaxWidth: lerpDouble(contentMaxWidth, other.contentMaxWidth, t)!,
      typographyScale: lerpDouble(typographyScale, other.typographyScale, t)!,
      motionDuration: Duration(
        microseconds: lerpDouble(
          motionDuration.inMicroseconds.toDouble(),
          other.motionDuration.inMicroseconds.toDouble(),
          t,
        )!.round(),
      ),
    );
  }
}

extension LayoutVisualTokensContext on BuildContext {
  LayoutVisualTokens get layoutVisualTokens {
    final tokens = Theme.of(this).extension<LayoutVisualTokens>();
    if (tokens == null) {
      throw StateError('layout_visual_tokens_missing');
    }
    return tokens;
  }
}
