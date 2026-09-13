import 'package:licoup/src/frontend/shared/ui/base_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

/// Feature specialization for Agent plugin and capability cards.
final class PluginSurface extends BaseSurface {
  const PluginSurface({super.key, required super.child, super.padding})
    : super(radius: LicoRadius.card, elevation: LicoElevation.card);
}
