import 'dart:collection';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

/// The sole semantic destination and surface-coverage authority.
final class SemanticDestinationCatalog {
  factory SemanticDestinationCatalog(
    Iterable<SemanticDestinationDescriptor> descriptors,
  ) {
    final byDestination = <ClientSection, SemanticDestinationDescriptor>{};
    for (final descriptor in descriptors) {
      if (byDestination.containsKey(descriptor.destination)) {
        throw const FormatException('semantic_destination_duplicate');
      }
      byDestination[descriptor.destination] = descriptor;
    }
    if (byDestination.length != ClientSection.values.length) {
      throw const FormatException('semantic_destination_product_incomplete');
    }

    final resolvedAliases = <ClientSection, ClientSection>{};
    ClientSection resolveAlias(ClientSection destination) {
      final cached = resolvedAliases[destination];
      if (cached != null) {
        return cached;
      }
      final visited = <ClientSection>{};
      var current = destination;
      while (true) {
        if (!visited.add(current)) {
          throw const FormatException('semantic_destination_alias_cycle');
        }
        final descriptor = byDestination[current];
        if (descriptor == null) {
          throw const FormatException('semantic_destination_alias_missing');
        }
        final target = descriptor.aliasOf;
        if (target == null) {
          resolvedAliases[destination] = current;
          return current;
        }
        current = target;
      }
    }

    for (final descriptor in byDestination.values) {
      final canonical = byDestination[resolveAlias(descriptor.destination)]!;
      if (!canonical.surfaces.containsAll(descriptor.surfaces)) {
        throw const FormatException(
          'semantic_destination_alias_surface_invalid',
        );
      }
    }

    final canonicalBySurface = <LayoutRuntimeSurface, Set<ClientSection>>{};
    for (final surface in LayoutRuntimeSurface.values) {
      final destinations =
          byDestination.values
              .where(
                (descriptor) =>
                    !descriptor.isAlias &&
                    descriptor.surfaces.contains(surface),
              )
              .map((descriptor) => descriptor.destination)
              .toList()
            ..sort((a, b) => a.index.compareTo(b.index));
      if (destinations.isEmpty) {
        throw const FormatException('semantic_destination_surface_empty');
      }
      canonicalBySurface[surface] = UnmodifiableSetView(
        LinkedHashSet<ClientSection>.of(destinations),
      );
    }

    return SemanticDestinationCatalog._(
      descriptors: UnmodifiableListView(
        ClientSection.values.map((destination) => byDestination[destination]!),
      ),
      byDestination: UnmodifiableMapView(byDestination),
      resolvedAliases: UnmodifiableMapView(resolvedAliases),
      canonicalBySurface: UnmodifiableMapView(canonicalBySurface),
    );
  }

  factory SemanticDestinationCatalog.current() =>
      SemanticDestinationCatalog(_currentDescriptors);

  const SemanticDestinationCatalog._({
    required this.descriptors,
    required this.byDestination,
    required this.resolvedAliases,
    required this.canonicalBySurface,
  });

  final List<SemanticDestinationDescriptor> descriptors;
  final Map<ClientSection, SemanticDestinationDescriptor> byDestination;
  final Map<ClientSection, ClientSection> resolvedAliases;
  final Map<LayoutRuntimeSurface, Set<ClientSection>> canonicalBySurface;

  ClientSection resolve(ClientSection destination) =>
      resolvedAliases[destination] ?? destination;

  bool supports(ClientSection destination, LayoutRuntimeSurface surface) =>
      canonicalBySurface[surface]!.contains(resolve(destination));

  Set<ClientSection> destinationsFor(LayoutRuntimeSurface surface) =>
      canonicalBySurface[surface]!;

  static final List<SemanticDestinationDescriptor> _currentDescriptors = [
    SemanticDestinationDescriptor(
      destination: ClientSection.controlPanel,
      labelKey: 'destination.home',
      surfaces: const {LayoutRuntimeSurface.desktop},
    ),
    SemanticDestinationDescriptor(
      destination: ClientSection.agents,
      labelKey: 'destination.agents',
      surfaces: const {
        LayoutRuntimeSurface.desktop,
        LayoutRuntimeSurface.mobile,
      },
    ),
    SemanticDestinationDescriptor(
      destination: ClientSection.feed,
      labelKey: 'destination.feed',
      surfaces: const {LayoutRuntimeSurface.mobile},
    ),
    SemanticDestinationDescriptor(
      destination: ClientSection.monitoring,
      labelKey: 'destination.monitoring',
      surfaces: const {LayoutRuntimeSurface.desktop},
    ),
    SemanticDestinationDescriptor(
      destination: ClientSection.mcpPlugins,
      labelKey: 'destination.extensions',
      surfaces: const {LayoutRuntimeSurface.desktop},
    ),
    SemanticDestinationDescriptor(
      destination: ClientSection.skillHub,
      labelKey: 'destination.skills',
      surfaces: const {LayoutRuntimeSurface.desktop},
      aliasOf: ClientSection.mcpPlugins,
    ),
    SemanticDestinationDescriptor(
      destination: ClientSection.localRuntime,
      labelKey: 'destination.runtime',
      surfaces: const {LayoutRuntimeSurface.desktop},
    ),
    SemanticDestinationDescriptor(
      destination: ClientSection.mobileRelay,
      labelKey: 'destination.mobile-relay',
      surfaces: const {
        LayoutRuntimeSurface.desktop,
        LayoutRuntimeSurface.mobile,
      },
    ),
    SemanticDestinationDescriptor(
      destination: ClientSection.settings,
      labelKey: 'destination.settings',
      surfaces: const {
        LayoutRuntimeSurface.desktop,
        LayoutRuntimeSurface.mobile,
      },
    ),
  ];
}
