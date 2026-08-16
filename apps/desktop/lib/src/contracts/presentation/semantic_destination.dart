import 'dart:collection';

import 'layout_environment.dart';

/// Canonical semantic destination identity shared by every layout.
enum ClientSection {
  agents,
  monitoring,
  skillHub,
  pluginManagement,
  mobileRelay,
  models,
  settings,
  agentHub,
}

final class SemanticDestinationDescriptor {
  factory SemanticDestinationDescriptor({
    required ClientSection destination,
    required String labelKey,
    required Set<LayoutRuntimeSurface> surfaces,
    ClientSection? aliasOf,
  }) {
    if (!_metadataKey.hasMatch(labelKey)) {
      throw const FormatException('semantic_destination_label_key_invalid');
    }
    if (surfaces.isEmpty) {
      throw const FormatException('semantic_destination_surface_missing');
    }
    if (aliasOf == destination) {
      throw const FormatException('semantic_destination_self_alias');
    }
    return SemanticDestinationDescriptor._(
      destination: destination,
      labelKey: labelKey,
      surfaces: UnmodifiableSetView(Set.of(surfaces)),
      aliasOf: aliasOf,
    );
  }

  const SemanticDestinationDescriptor._({
    required this.destination,
    required this.labelKey,
    required this.surfaces,
    required this.aliasOf,
  });

  static final RegExp _metadataKey = RegExp(
    r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$',
  );

  final ClientSection destination;
  final String labelKey;
  final Set<LayoutRuntimeSurface> surfaces;
  final ClientSection? aliasOf;

  bool get isAlias => aliasOf != null;
}
