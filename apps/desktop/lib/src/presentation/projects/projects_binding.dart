import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/projects/projects_effect.dart';
import 'package:licoup/src/presentation/projects/projects_intent.dart';
import 'package:licoup/src/presentation/projects/projects_layout.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';

/// Everything one renderer binds for the project surface.
///
/// The durable facts and the local arrangement are two sources, and the
/// arrangement reaches the renderer through [layoutMutations] instead of an
/// intent sink. A drag therefore writes local layout state only; it has no
/// member of type [IntentSink] to send through.
final class ProjectsBinding {
  const ProjectsBinding({
    required this.projection,
    required this.layout,
    required this.intents,
    required this.layoutMutations,
    required this.effects,
  });

  final ProjectionSource<ProjectsProjection> projection;
  final ProjectionSource<ProjectsLayoutState> layout;
  final IntentSink<ProjectsIntent> intents;
  final ProjectLayoutMutations layoutMutations;
  final EffectSource<ProjectsEffect> effects;
}
