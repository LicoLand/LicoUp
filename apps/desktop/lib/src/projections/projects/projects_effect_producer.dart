import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/projects/projects_effect.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

/// One-shot effect lane for the project surface.
///
/// The lane carries results, never facts: a renderer that wants to know what a
/// project holds reads the projection. Nothing here accepts a coordinate.
final class ProjectsEffectProducer implements EffectSource<ProjectsEffect> {
  final StreamController<ProjectsEffect> _effects =
      StreamController<ProjectsEffect>.broadcast(sync: true);

  @override
  Stream<ProjectsEffect> get effects => _effects.stream;

  bool get isClosed => _effects.isClosed;

  void emit(ProjectsEffect effect) {
    if (_effects.isClosed) return;
    _effects.add(effect);
  }

  Future<void> dispose() => closeBroadcastController(_effects);
}
