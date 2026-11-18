import 'dart:collection';

import 'layout_environment.dart';
import 'layout_profile.dart';
import 'semantic_destination.dart';

/// Collision-free key for a concrete profile renderer variant.
final class LayoutVariantKey implements Comparable<LayoutVariantKey> {
  const LayoutVariantKey({
    required this.profileId,
    required this.surface,
    required this.viewport,
  });

  final LayoutProfileId profileId;
  final LayoutRuntimeSurface surface;
  final LayoutViewportClass viewport;

  @override
  int compareTo(LayoutVariantKey other) {
    final profileOrder = profileId.compareTo(other.profileId);
    if (profileOrder != 0) {
      return profileOrder;
    }
    final surfaceOrder = surface.index.compareTo(other.surface.index);
    return surfaceOrder != 0
        ? surfaceOrder
        : viewport.index.compareTo(other.viewport.index);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutVariantKey &&
          other.profileId == profileId &&
          other.surface == surface &&
          other.viewport == viewport;

  @override
  int get hashCode => Object.hash(profileId, surface, viewport);

  @override
  String toString() => '${profileId.value}/${surface.name}/${viewport.name}';
}

final class LayoutVariantCoverage {
  LayoutVariantCoverage({
    required this.key,
    required Set<ClientSection> destinations,
  }) : destinations = UnmodifiableSetView(Set.of(destinations)) {
    if (destinations.isEmpty) {
      throw const FormatException('layout_variant_destinations_missing');
    }
  }

  final LayoutVariantKey key;
  final Set<ClientSection> destinations;
}
