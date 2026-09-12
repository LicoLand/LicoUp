import 'package:licoup/src/frontend/shared/ui/base_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

/// Agent catalog and detail surfaces share the application material system.
final class AgentHubSurface extends BaseSurface {
  const AgentHubSurface({super.key, required super.child, super.padding})
    : super(radius: LicoRadius.card, elevation: LicoElevation.card);
}
