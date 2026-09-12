import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/base_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

final class ContinuousParentSurface extends BaseSurface {
  const ContinuousParentSurface({
    super.key,
    required super.child,
    super.selected,
  }) : super(padding: const EdgeInsets.all(LicoContentSpacing.compact));
}

final class ContinuousChildSurface extends BaseSurface {
  const ContinuousChildSurface({
    super.key,
    required super.child,
    super.selected,
  }) : super(radius: LicoRadius.chip, elevation: LicoElevation.flat);
}

final class ContinuousCompletionSurface extends BaseSurface {
  const ContinuousCompletionSurface({super.key, required super.child})
    : super(
        tone: LicoSurfaceTone.accent,
        radius: LicoRadius.chip,
        padding: const EdgeInsets.all(LicoContentSpacing.compact),
      );
}
