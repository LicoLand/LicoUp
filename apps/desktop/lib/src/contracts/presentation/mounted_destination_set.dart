import 'dart:collection';

import 'semantic_destination.dart';

/// The catalogue projection of which semantic destinations a running client
/// actually mounts.
///
/// This value is derived from the composition declaration — never from a probe
/// performed while the client is running — so installing or removing a
/// capability changes this projection and nothing else. A destination the
/// declaration does not name is absent here, and the shell uses that absence
/// instead of guessing: an absent destination is not offered, and a request for
/// one is recovered to a mounted destination instead of rendering a surface no
/// feature owns.
///
/// The set is immutable and canonically ordered, so two identical declarations
/// always produce equal projections.
final class MountedDestinationSet {
  factory MountedDestinationSet(Iterable<ClientSection> mounted) {
    final requested = Set<ClientSection>.of(mounted);
    final ordered = <ClientSection>[
      for (final destination in ClientSection.values)
        if (requested.contains(destination)) destination,
    ];
    return MountedDestinationSet._(
      destinations: UnmodifiableListView<ClientSection>(ordered),
      mounted: UnmodifiableSetView<ClientSection>(ordered.toSet()),
    );
  }

  const MountedDestinationSet._({
    required this.destinations,
    required this.mounted,
  });

  /// Every mounted destination, in canonical [ClientSection] order.
  final List<ClientSection> destinations;

  final Set<ClientSection> mounted;

  /// Whether this client mounts [destination].
  ///
  /// A false answer is the catalogue's truthful absence report for that
  /// capability: no composition, no binding, no surface.
  bool isMounted(ClientSection destination) => mounted.contains(destination);

  /// The destination a request for [requested] resolves to.
  ///
  /// A mounted request resolves to itself. An absent one is recovered to the
  /// agent destination — the entry point every client serves — or otherwise to
  /// the first mounted destination in canonical order. The answer is null only
  /// when the client mounts nothing at all, which no valid composition
  /// produces.
  ClientSection? recoveryFor(ClientSection requested) {
    if (isMounted(requested)) return requested;
    if (isMounted(ClientSection.agents)) return ClientSection.agents;
    return destinations.isEmpty ? null : destinations.first;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MountedDestinationSet &&
          other.destinations.length == destinations.length &&
          other.mounted.containsAll(mounted);

  @override
  int get hashCode => Object.hashAll(destinations);

  @override
  String toString() => 'MountedDestinationSet($destinations)';
}
