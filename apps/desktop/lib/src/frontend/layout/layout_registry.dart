import 'dart:collection';

import 'package:licoup/src/application/features/layout/layout_catalog.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/layout_variant.dart';
import 'package:licoup/src/frontend/layout/layout_definition.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';

final class RegisteredLayoutVariant {
  const RegisteredLayoutVariant({required this.bundle, required this.variant});

  final LayoutSurfaceBundle bundle;
  final LayoutSurfaceVariant variant;
}

/// Immutable widget registry validated against the pure application catalog.
final class LayoutRegistry {
  factory LayoutRegistry({
    required LayoutCatalog catalog,
    required Iterable<LayoutDefinition> definitions,
  }) {
    final definitionById = <LayoutProfileId, LayoutDefinition>{};
    final variantByKey = <LayoutVariantKey, RegisteredLayoutVariant>{};
    final declaredNamespaces = <LayoutStateNamespace>{};

    for (final definition in definitions) {
      if (definitionById.containsKey(definition.profile.id)) {
        throw const FormatException('layout_registry_profile_duplicate');
      }
      final catalogProfile = catalog.profile(definition.profile.id);
      if (catalogProfile == null || catalogProfile != definition.profile) {
        throw const FormatException('layout_registry_profile_mismatch');
      }
      definitionById[definition.profile.id] = definition;
      for (final surface in LayoutRuntimeSurface.values) {
        final bundle = definition.bundles[surface]!;
        declaredNamespaces.addAll(bundle.stateNamespaces);
        for (final entry in bundle.variants.entries) {
          final key = LayoutVariantKey(
            profileId: definition.profile.id,
            surface: surface,
            viewport: entry.key,
          );
          if (variantByKey.containsKey(key)) {
            throw const FormatException('layout_registry_variant_duplicate');
          }
          final expected = catalog.coverage(key).destinations;
          final actual = entry.value.destinationBuilders.keys.toSet();
          if (!_sameSet(expected, actual)) {
            throw const FormatException(
              'layout_registry_destination_product_invalid',
            );
          }
          variantByKey[key] = RegisteredLayoutVariant(
            bundle: bundle,
            variant: entry.value,
          );
        }
      }
    }

    if (!_sameSet(
      definitionById.keys.toSet(),
      catalog.profileById.keys.toSet(),
    )) {
      throw const FormatException('layout_registry_profile_product_invalid');
    }
    if (!_sameSet(
      variantByKey.keys.toSet(),
      catalog.variantByKey.keys.toSet(),
    )) {
      throw const FormatException('layout_registry_variant_product_invalid');
    }
    if (!_sameSet(declaredNamespaces, catalog.stateNamespaces)) {
      throw const FormatException('layout_registry_state_product_invalid');
    }

    return LayoutRegistry._(
      catalog: catalog,
      definitions: UnmodifiableMapView(definitionById),
      variants: UnmodifiableMapView(variantByKey),
    );
  }

  const LayoutRegistry._({
    required this.catalog,
    required this.definitions,
    required this.variants,
  });

  final LayoutCatalog catalog;
  final Map<LayoutProfileId, LayoutDefinition> definitions;
  final Map<LayoutVariantKey, RegisteredLayoutVariant> variants;

  LayoutDefinition definition(LayoutProfileId id) {
    final definition = definitions[id];
    if (definition == null) {
      throw const FormatException('layout_registry_profile_unregistered');
    }
    return definition;
  }

  RegisteredLayoutVariant variant(LayoutVariantKey key) {
    final registered = variants[key];
    if (registered == null) {
      throw const FormatException('layout_registry_variant_unregistered');
    }
    return registered;
  }

  static bool _sameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right);
}
