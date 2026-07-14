import 'dart:collection';

import 'layout_environment.dart';

/// Canonical semantic destination identity shared by every layout.
enum ClientSection {
  controlPanel,
  agents,
  feed,
  monitoring,
  mcpPlugins,
  skillHub,
  localRuntime,
  mobileRelay,
  settings,
}

final class SemanticDestinationDescriptor {
  SemanticDestinationDescriptor({
    required this.destination,
    required this.labelKey,
    required Set<LayoutRuntimeSurface> surfaces,
    this.aliasOf,
  }) : surfaces = UnmodifiableSetView(Set.of(surfaces)) {
    if (labelKey.trim().isEmpty) {
      throw const FormatException('semantic_destination_label_missing');
    }
    if (surfaces.isEmpty) {
      throw const FormatException('semantic_destination_surface_missing');
    }
    if (aliasOf == destination) {
      throw const FormatException('semantic_destination_self_alias');
    }
  }

  final ClientSection destination;
  final String labelKey;
  final Set<LayoutRuntimeSurface> surfaces;
  final ClientSection? aliasOf;
}
