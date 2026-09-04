import 'dart:collection';

import 'package:licoup/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_catalog_port.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/layout_variant.dart';

/// Immutable profile metadata and exact surface/viewport/destination product.
final class LayoutCatalog implements LayoutCatalogView {
  factory LayoutCatalog({
    required int revision,
    required Iterable<LayoutProfileDescriptor> profiles,
    required Iterable<LayoutVariantCoverage> variants,
    required SemanticDestinationCatalog destinationCatalog,
    Iterable<LayoutStateNamespace> stateNamespaces = const [],
  }) {
    if (revision < 1) {
      throw const FormatException('layout_catalog_revision_invalid');
    }

    final profileById = <LayoutProfileId, LayoutProfileDescriptor>{};
    for (final profile in profiles) {
      if (profileById.containsKey(profile.id)) {
        throw const FormatException('layout_catalog_profile_duplicate');
      }
      profileById[profile.id] = profile;
    }
    if (profileById.isEmpty) {
      throw const FormatException('layout_catalog_profile_missing');
    }

    final defaults = profileById.values
        .where((profile) => profile.isDefault)
        .toList(growable: false);
    if (defaults.length != 1) {
      throw const FormatException('layout_catalog_default_invalid');
    }

    final variantByKey = <LayoutVariantKey, LayoutVariantCoverage>{};
    for (final variant in variants) {
      if (!profileById.containsKey(variant.key.profileId)) {
        throw const FormatException('layout_catalog_variant_profile_unknown');
      }
      if (!LayoutViewportPolicy.supports(
        variant.key.surface,
        variant.key.viewport,
      )) {
        throw const FormatException('layout_catalog_viewport_unsupported');
      }
      if (variantByKey.containsKey(variant.key)) {
        throw const FormatException('layout_catalog_variant_duplicate');
      }
      variantByKey[variant.key] = variant;
    }

    final expectedKeys = <LayoutVariantKey>{};
    for (final profile in profileById.values) {
      for (final surface in LayoutRuntimeSurface.values) {
        final expectedDestinations = destinationCatalog.destinationsFor(
          surface,
        );
        for (final viewport in LayoutViewportPolicy.supportedFor(surface)) {
          final key = LayoutVariantKey(
            profileId: profile.id,
            surface: surface,
            viewport: viewport,
          );
          expectedKeys.add(key);
          final variant = variantByKey[key];
          if (variant == null) {
            throw const FormatException('layout_catalog_variant_missing');
          }
          if (!_sameSet(variant.destinations, expectedDestinations)) {
            throw const FormatException(
              'layout_catalog_destination_product_invalid',
            );
          }
        }
      }
    }
    if (!_sameSet(variantByKey.keys.toSet(), expectedKeys)) {
      throw const FormatException('layout_catalog_variant_product_invalid');
    }

    final namespaceSet = <LayoutStateNamespace>{};
    for (final namespace in stateNamespaces) {
      if (!namespaceSet.add(namespace)) {
        throw const FormatException('layout_state_namespace_duplicate');
      }
      if (!profileById.containsKey(namespace.profileId)) {
        throw const FormatException('layout_state_profile_unknown');
      }
      if (destinationCatalog.resolve(namespace.destination) !=
              namespace.destination ||
          !destinationCatalog.supports(
            namespace.destination,
            namespace.surface,
          )) {
        throw const FormatException('layout_state_destination_invalid');
      }
    }

    final defaultProfile = defaults.single;
    final orderedProfiles = <LayoutProfileDescriptor>[
      defaultProfile,
      for (final profile in profileById.values)
        if (profile.id != defaultProfile.id) profile,
    ];

    return LayoutCatalog._(
      revision: revision,
      destinationCatalog: destinationCatalog,
      defaultProfile: defaultProfile,
      profiles: UnmodifiableListView(orderedProfiles),
      profileById: UnmodifiableMapView(profileById),
      variantByKey: UnmodifiableMapView(variantByKey),
      stateNamespaces: UnmodifiableSetView(
        LinkedHashSet<LayoutStateNamespace>.of(namespaceSet),
      ),
    );
  }

  const LayoutCatalog._({
    required this.revision,
    required this.destinationCatalog,
    required this.defaultProfile,
    required this.profiles,
    required this.profileById,
    required this.variantByKey,
    required this.stateNamespaces,
  });

  final int revision;
  final SemanticDestinationCatalog destinationCatalog;
  final LayoutProfileDescriptor defaultProfile;
  final List<LayoutProfileDescriptor> profiles;
  final Map<LayoutProfileId, LayoutProfileDescriptor> profileById;
  final Map<LayoutVariantKey, LayoutVariantCoverage> variantByKey;
  @override
  final Set<LayoutStateNamespace> stateNamespaces;

  @override
  Iterable<LayoutProfileId> get profileIds => profileById.keys;

  @override
  Iterable<LayoutVariantKey> get variantKeys => variantByKey.keys;

  bool containsProfile(LayoutProfileId id) => profileById.containsKey(id);

  @override
  LayoutProfileDescriptor? profile(LayoutProfileId id) => profileById[id];

  @override
  LayoutVariantCoverage coverage(LayoutVariantKey key) {
    final coverage = variantByKey[key];
    if (coverage == null) {
      throw const FormatException('layout_catalog_variant_unregistered');
    }
    return coverage;
  }

  @override
  bool declaresStateNamespace(LayoutStateNamespace namespace) =>
      stateNamespaces.contains(namespace);

  static bool _sameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right);
}
