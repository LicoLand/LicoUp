library feature_mount_contract;

/// Stable identity of one mountable feature.
///
/// A directory entry is identified by this value, never by its position in the
/// directory, so mounting, unmounting and enabling one entry can never be
/// confused with another and two equal directories compare equal regardless of
/// how they were assembled.
final class FeatureMountId {
  const FeatureMountId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FeatureMountId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FeatureMountId($value)';
}

/// Stable identity of one destination a mounted feature contributes.
///
/// The identity belongs to the directory, not to a renderer: a shell resolves
/// the surface of a destination by asking which entry contributes it.
final class MountDestinationId {
  const MountDestinationId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MountDestinationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MountDestinationId($value)';
}

/// Stable identity of one capability a mounted feature contributes.
///
/// A capability is what a mount offers to the rest of the client without owning
/// a destination of its own, and what another mount can require before it is
/// able to serve its destination.
final class MountCapabilityId {
  const MountCapabilityId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MountCapabilityId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MountCapabilityId($value)';
}

/// Lifecycle phase of one directory entry, ordered by what the entry
/// contributes.
///
/// An [unmounted] entry contributes nothing and owns no resource, so removing a
/// declaration and unmounting it have the same visible effect on the shell. A
/// [mounted] entry owns the resource its feature needs but still contributes no
/// destination and no capability. Only an [enabled] entry contributes the
/// destinations and capabilities its declaration names.
enum FeatureMountPhase { unmounted, mounted, enabled }

/// The input one directory entry is declared from.
///
/// A declaration names the entry's identity, the phase it is requested in, and
/// the destinations and capabilities the feature contributes while it is
/// enabled. It carries no surface, builder, or renderer: a directory decides
/// which features exist, never how one looks.
final class FeatureMountRequest {
  factory FeatureMountRequest({
    required FeatureMountId id,
    FeatureMountPhase phase = FeatureMountPhase.mounted,
    Iterable<MountDestinationId> destinations = const <MountDestinationId>[],
    Iterable<MountCapabilityId> capabilities = const <MountCapabilityId>[],
  }) => FeatureMountRequest._(
    id: id,
    phase: phase,
    destinations: Set<MountDestinationId>.unmodifiable(destinations),
    capabilities: Set<MountCapabilityId>.unmodifiable(capabilities),
  );

  const FeatureMountRequest._({
    required this.id,
    required this.phase,
    required this.destinations,
    required this.capabilities,
  });

  final FeatureMountId id;

  /// The phase this declaration asks for.
  final FeatureMountPhase phase;

  /// Destinations this feature contributes while it is enabled.
  final Set<MountDestinationId> destinations;

  /// Capabilities this feature contributes while it is enabled.
  final Set<MountCapabilityId> capabilities;

  /// The same declaration requested in [phase].
  FeatureMountRequest at(FeatureMountPhase phase) => FeatureMountRequest(
    id: id,
    phase: phase,
    destinations: destinations,
    capabilities: capabilities,
  );

  FeatureMountRequest unmounted() => at(FeatureMountPhase.unmounted);

  FeatureMountRequest mounted() => at(FeatureMountPhase.mounted);

  FeatureMountRequest enabled() => at(FeatureMountPhase.enabled);

  /// The directory entry this declaration produces.
  FeatureMount get entry => FeatureMount._(this, phase);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FeatureMountRequest &&
          other.id == id &&
          other.phase == phase &&
          _sameSet(other.destinations, destinations) &&
          _sameSet(other.capabilities, capabilities);

  @override
  int get hashCode =>
      Object.hash(id, phase, _setHash(destinations), _setHash(capabilities));

  @override
  String toString() =>
      'FeatureMountRequest($id, ${phase.name}, '
      '${destinations.length} destinations, ${capabilities.length} capabilities)';
}

/// One entry of a [FeatureMountDirectory]: the declaration it was created from
/// and the phase it is in now.
final class FeatureMount {
  const FeatureMount._(this.request, this.phase);

  final FeatureMountRequest request;
  final FeatureMountPhase phase;

  FeatureMountId get id => request.id;

  /// Destinations the declaration names, whether or not they are contributed.
  Set<MountDestinationId> get destinations => request.destinations;

  /// Capabilities the declaration names, whether or not they are contributed.
  Set<MountCapabilityId> get capabilities => request.capabilities;

  /// True while the entry owns its resource, at any phase but [unmounted].
  bool get isMounted => phase != FeatureMountPhase.unmounted;

  /// True while the entry contributes its destinations and capabilities.
  bool get isEnabled => phase == FeatureMountPhase.enabled;

  bool contributesDestination(MountDestinationId destination) =>
      isEnabled && request.destinations.contains(destination);

  bool contributesCapability(MountCapabilityId capability) =>
      isEnabled && request.capabilities.contains(capability);

  /// This entry in [phase], keeping its declaration.
  FeatureMount at(FeatureMountPhase phase) =>
      phase == this.phase ? this : FeatureMount._(request, phase);

  FeatureMount mount() => at(FeatureMountPhase.mounted);

  FeatureMount unmount() => at(FeatureMountPhase.unmounted);

  FeatureMount enable() => at(FeatureMountPhase.enabled);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FeatureMount && other.request == request && other.phase == phase;

  @override
  int get hashCode => Object.hash(request, phase);

  @override
  String toString() => 'FeatureMount($id, ${phase.name})';
}

/// The directory of feature mounts one client owns.
///
/// Every question the shell asks about a capability is answered here and
/// nowhere else: which destinations exist, which capabilities are available,
/// and which entry contributes a given destination. A destination or capability
/// no enabled entry contributes is absent, so removing one declaration removes
/// everything it contributed without any other file changing.
///
/// The value is immutable. Mounting, unmounting and enabling return a new
/// directory, and two directories with the same entries in the same order are
/// equal, so a directory can be built once and compared freely.
final class FeatureMountDirectory {
  factory FeatureMountDirectory(Iterable<FeatureMountRequest> requests) {
    final entries = <FeatureMount>[];
    final identities = <FeatureMountId>{};
    for (final request in requests) {
      if (!identities.add(request.id)) {
        throw ArgumentError.value(
          request.id.value,
          'requests',
          'duplicate feature mount id in one directory',
        );
      }
      entries.add(request.entry);
    }
    return FeatureMountDirectory._(List<FeatureMount>.unmodifiable(entries));
  }

  const FeatureMountDirectory._(this.mounts);

  /// A directory that mounts nothing: every destination and capability is
  /// absent.
  static const FeatureMountDirectory empty = FeatureMountDirectory._(
    <FeatureMount>[],
  );

  /// Every entry, in declaration order.
  final List<FeatureMount> mounts;

  bool get isEmpty => mounts.isEmpty;

  bool get isNotEmpty => mounts.isNotEmpty;

  FeatureMount? entryFor(FeatureMountId id) {
    for (final entry in mounts) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// The phase of [id]; a declaration the directory does not hold is
  /// [FeatureMountPhase.unmounted].
  FeatureMountPhase phaseOf(FeatureMountId id) =>
      entryFor(id)?.phase ?? FeatureMountPhase.unmounted;

  bool isMounted(FeatureMountId id) =>
      phaseOf(id) != FeatureMountPhase.unmounted;

  bool isEnabled(FeatureMountId id) => phaseOf(id) == FeatureMountPhase.enabled;

  /// The first enabled entry that contributes [destination], or null when no
  /// enabled entry does.
  FeatureMount? contributorOf(MountDestinationId destination) {
    for (final entry in mounts) {
      if (entry.contributesDestination(destination)) return entry;
    }
    return null;
  }

  bool contributes(MountDestinationId destination) =>
      contributorOf(destination) != null;

  bool contributesCapability(MountCapabilityId capability) {
    for (final entry in mounts) {
      if (entry.contributesCapability(capability)) return true;
    }
    return false;
  }

  /// True when every capability in [capabilities] is available.
  bool contributesCapabilities(Iterable<MountCapabilityId> capabilities) {
    for (final capability in capabilities) {
      if (!contributesCapability(capability)) return false;
    }
    return true;
  }

  /// Every destination the enabled entries contribute.
  Set<MountDestinationId> get destinations =>
      Set<MountDestinationId>.unmodifiable(<MountDestinationId>{
        for (final entry in mounts)
          if (entry.isEnabled) ...entry.destinations,
      });

  /// Every capability the enabled entries contribute.
  Set<MountCapabilityId> get capabilities =>
      Set<MountCapabilityId>.unmodifiable(<MountCapabilityId>{
        for (final entry in mounts)
          if (entry.isEnabled) ...entry.capabilities,
      });

  /// This directory with [id] moved to [phase].
  ///
  /// A phase request for an identity the directory does not hold is an error:
  /// a lifecycle transition never creates a declaration.
  FeatureMountDirectory at(FeatureMountId id, FeatureMountPhase phase) =>
      _replace(id, (entry) => entry.at(phase));

  FeatureMountDirectory mount(FeatureMountId id) =>
      at(id, FeatureMountPhase.mounted);

  FeatureMountDirectory unmount(FeatureMountId id) =>
      at(id, FeatureMountPhase.unmounted);

  FeatureMountDirectory enable(FeatureMountId id) =>
      at(id, FeatureMountPhase.enabled);

  /// This directory without the declarations named by [ids].
  ///
  /// The entries stop existing, so every destination and capability they
  /// contributed disappears with them. An identity this directory does not hold
  /// is ignored, which makes removal the inverse of declaring.
  FeatureMountDirectory without(Iterable<FeatureMountId> ids) {
    final removed = Set<FeatureMountId>.of(ids);
    return FeatureMountDirectory._(
      List<FeatureMount>.unmodifiable(<FeatureMount>[
        for (final entry in mounts)
          if (!removed.contains(entry.id)) entry,
      ]),
    );
  }

  FeatureMountDirectory _replace(
    FeatureMountId id,
    FeatureMount Function(FeatureMount entry) update,
  ) {
    final updated = <FeatureMount>[];
    var found = false;
    for (final entry in mounts) {
      if (entry.id == id) {
        found = true;
        updated.add(update(entry));
      } else {
        updated.add(entry);
      }
    }
    if (!found) {
      throw ArgumentError.value(
        id.value,
        'id',
        'no such feature mount in this directory',
      );
    }
    return FeatureMountDirectory._(List<FeatureMount>.unmodifiable(updated));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FeatureMountDirectory && _sameMounts(other.mounts, mounts);

  @override
  int get hashCode => Object.hashAll(mounts);

  @override
  String toString() => 'FeatureMountDirectory(${mounts.length} mounts)';
}

bool _sameMounts(List<FeatureMount> left, List<FeatureMount> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameSet<T>(Set<T> left, Set<T> right) {
  if (left.length != right.length) return false;
  return left.every(right.contains);
}

int _setHash<T>(Set<T> values) {
  var result = 0;
  for (final value in values) {
    result ^= value.hashCode;
  }
  return result;
}
