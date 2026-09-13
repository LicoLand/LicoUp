import 'package:licoup/src/frontend/shared/ui/base_surface.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

/// Feature specialization for the skill catalog's interactive cards.
final class SkillSurface extends BaseSurface {
  const SkillSurface({super.key, required super.child})
    : super(radius: LicoRadius.card, elevation: LicoElevation.card);
}
