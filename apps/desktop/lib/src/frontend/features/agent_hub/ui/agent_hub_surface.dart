import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/base_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

/// Agent catalog and detail surfaces share the application material system.
final class AgentHubSurface extends BaseSurface {
  const AgentHubSurface({super.key, required super.child, super.padding})
    : super(radius: LicoRadius.card, elevation: LicoElevation.card);
}

/// The detail selector track shares continuous control geometry while the
/// Agent Hub retains ownership of its compact segmented presentation.
final class AgentHubDetailSelectorSurface extends BaseControlSurface {
  const AgentHubDetailSelectorSurface({
    super.key,
    required super.child,
    required super.fill,
    required super.stroke,
  }) : super(borderRadius: const BorderRadius.all(Radius.circular(16)));
}
