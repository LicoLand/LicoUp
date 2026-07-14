import 'dart:collection';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';

/// Immutable aggregate assembled only by the parent composition root.
final class LayoutDefinition {
  factory LayoutDefinition(Iterable<LayoutSurfaceBundle> bundles) {
    final bundleList = bundles.toList(growable: false);
    if (bundleList.isEmpty) {
      throw const FormatException('layout_definition_bundle_missing');
    }
    final profile = bundleList.first.profile;
    final bySurface = <LayoutRuntimeSurface, LayoutSurfaceBundle>{};
    for (final bundle in bundleList) {
      if (bundle.profile != profile) {
        throw const FormatException('layout_definition_profile_mismatch');
      }
      if (bySurface.containsKey(bundle.surface)) {
        throw const FormatException('layout_definition_surface_duplicate');
      }
      bySurface[bundle.surface] = bundle;
    }
    if (bySurface.length != LayoutRuntimeSurface.values.length ||
        !bySurface.keys.toSet().containsAll(LayoutRuntimeSurface.values)) {
      throw const FormatException('layout_definition_surface_product_invalid');
    }
    return LayoutDefinition._(
      profile: profile,
      bundles: UnmodifiableMapView(bySurface),
    );
  }

  const LayoutDefinition._({required this.profile, required this.bundles});

  final LayoutProfileDescriptor profile;
  final Map<LayoutRuntimeSurface, LayoutSurfaceBundle> bundles;
}
