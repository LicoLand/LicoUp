import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import '../cache/byte_lru_cache.dart';
import '../scheduling/preparation_executor.dart';

final class _PreparationSlot {
  const _PreparationSlot(this.resource, this.fieldName);

  final ResourceKey resource;
  final String fieldName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _PreparationSlot &&
          other.resource == resource &&
          other.fieldName == fieldName;

  @override
  int get hashCode => Object.hash(resource, fieldName);
}

final class _PreparationState {
  _PreparationState(this.request);

  final PreparationRequest<Object?> request;
  PreparationStatus status = PreparationStatus.active;
}

/// Owns asynchronous preparation admission for a presentation runtime.
///
/// Every resource has one current request identity. A result may finish after
/// a source switch or a newer request; it remains a valid pure value, but
/// [acceptanceFor] rejects it so it cannot install into the new display owner.
final class ResourcePreparationManager {
  ResourcePreparationManager({required this.executor, required this.cache});

  final BoundedPreparationExecutor executor;
  final ByteLruCache<VersionedCacheKey, Object?> cache;
  final Map<_PreparationSlot, _PreparationState> _states =
      <_PreparationSlot, _PreparationState>{};
  final Map<VersionedCacheKey, Future<PreparedResource<Object?>>> _inFlight =
      <VersionedCacheKey, Future<PreparedResource<Object?>>>{};
  bool _disposed = false;

  bool get disposed => _disposed;

  /// Schedules a pure preparation and carries the exact source/generation
  /// identity through to its result.
  Future<PreparedResource<T>> prepare<T>({
    required ResourceSnapshot<T> snapshot,
    required RequestGeneration generation,
    required FutureOr<T> Function() operation,
    int estimatedBytes = 0,
    int? resultBytes,
    Object? variant,
    PreparationPriority priority = PreparationPriority.foreground,
  }) {
    if (_disposed)
      return Future<PreparedResource<T>>.error(
        StateError('preparation manager disposed'),
      );

    final request = PreparationRequest<T>.fromSnapshot(
      snapshot: snapshot,
      generation: generation,
    );
    final slot = _slot(request.resource);
    final current = _states[slot];
    if (current == null || _supersedes(request, current.request)) {
      if (current != null && current.request != request) {
        current.status = PreparationStatus.revoked;
      }
      _states[slot] = _PreparationState(request as PreparationRequest<Object?>);
    }

    final key = VersionedCacheKey.fromRequest(request, variant: variant);
    if (cache.containsKey(key)) {
      final value = cache.get(key) as T;
      return Future<PreparedResource<T>>.value(
        PreparedResource<T>(request: request, value: value),
      );
    }

    final existing = _inFlight[key];
    if (existing != null) {
      return existing.then(
        (result) =>
            PreparedResource<T>(request: request, value: result.value as T),
      );
    }

    final future = executor.submit<T>(
      operation,
      estimatedBytes: estimatedBytes,
      priority: priority,
    );
    final resultFuture = future.then<PreparedResource<Object?>>((value) {
      final bytes = resultBytes ?? estimatedBytes;
      cache.put(key, value, bytes: bytes);
      return PreparedResource<Object?>(
        request: request as PreparationRequest<Object?>,
        value: value,
      );
    });
    _inFlight[key] = resultFuture;
    unawaited(
      resultFuture.then<void>(
        (_) {
          if (identical(_inFlight[key], resultFuture)) {
            _inFlight.remove(key);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_inFlight[key], resultFuture)) {
            _inFlight.remove(key);
          }
        },
      ),
    );
    return resultFuture.then(
      (result) =>
          PreparedResource<T>(request: request, value: result.value as T),
    );
  }

  /// Marks the current request for one resource as no longer installable.
  ///
  /// When a source position or generation is supplied, only a request that
  /// differs from that identity is revoked. This lets a repeated read of the
  /// same snapshot preserve a valid preparation while a new epoch, version,
  /// or request generation invalidates the old one.
  void invalidate<T>(
    ResourceFieldGroup<T> resource, {
    SourcePosition? source,
    RequestGeneration? generation,
  }) {
    final state = _states[_slot(resource)];
    if (state == null) return;
    final sameSource = source == null || state.request.source == source;
    final sameGeneration =
        generation == null || state.request.generation == generation;
    if (source == null && generation == null ||
        !sameSource ||
        !sameGeneration) {
      state.status = PreparationStatus.revoked;
    }
  }

  /// Returns the current acceptance view for a result request.
  PreparationAcceptance<T> acceptanceFor<T>(PreparationRequest<T> request) {
    if (_disposed) {
      return PreparationAcceptance<T>(
        request: request,
        status: PreparationStatus.disposed,
      );
    }
    final state = _states[_slot(request.resource)];
    if (state == null || state.request != request) {
      return PreparationAcceptance<T>(
        request: request,
        status: PreparationStatus.revoked,
      );
    }
    return PreparationAcceptance<T>(request: request, status: state.status);
  }

  bool canInstall<T>(PreparedResource<T> result) =>
      acceptanceFor(result.request).canInstall(result);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final state in _states.values) {
      state.status = PreparationStatus.disposed;
    }
    _states.clear();
    _inFlight.clear();
    executor.dispose();
  }

  static _PreparationSlot _slot<T>(ResourceFieldGroup<T> resource) =>
      _PreparationSlot(resource.resource, resource.name);

  /// True when [candidate] may become the current installable request.
  ///
  /// Within one source epoch both the position and the request generation are
  /// monotonic: an older position, or an older generation of the same position,
  /// is a stale read. It still returns a valid pure value, but it never
  /// replaces the current request, so its acceptance stays revoked and an
  /// older preparation cannot install over a newer one. A different epoch is a
  /// rebuilt source, which starts the resource over.
  static bool _supersedes<T>(
    PreparationRequest<T> candidate,
    PreparationRequest<Object?> current,
  ) {
    final relation = candidate.source.compare(current.source);
    switch (relation) {
      case VersionRelation.differentEpoch:
        return true;
      case VersionRelation.older:
        return false;
      case VersionRelation.newer:
        return true;
      case VersionRelation.same:
        return candidate.generation.value >= current.generation.value;
    }
  }
}

typedef PreparationManager = ResourcePreparationManager;
typedef PreparationCoordinator = ResourcePreparationManager;

/// A small installation boundary for prepared values.
///
/// It performs the same acceptance check as the runtime before replacing the
/// installed value for a resource. It does not own business state or invoke
/// actions; it only stores the latest renderer-ready value.
///
/// A result that belongs to a consistency group is not installed on its own.
/// It is offered to the group's [ConsistencyGroupInstall] gate and becomes
/// visible only when every changed field group of that group has reported at
/// the group's own position, so a view never mixes two versions of one group.
/// A member whose acceptance is revoked before the group completes revokes the
/// whole gate instead of leaving a partial group visible, and every staged
/// member is re-checked against the manager right before publishing.
///
/// Each field group carries its own request generation, so generations are
/// compared per field: a member older than the installed one for that field is
/// stale and refused, while a newer one starts a new group run. The previously
/// installed values stay visible while the new run is incomplete, no member of
/// the old run is published again, and the new run's missing members are
/// reported through [ConsistencyGroupInstall.pending] until they are offered.
/// Once a newer position of one group publishes, the gates of its older
/// positions are revoked instead of being retained.
final class PreparedResourceInstaller<T> implements PresentationInstaller<T> {
  PreparedResourceInstaller(this.manager);

  final ResourcePreparationManager manager;
  final Map<_PreparationSlot, _InstalledValue<T>> _installed =
      <_PreparationSlot, _InstalledValue<T>>{};
  final Map<_GroupSlot, ConsistencyGroupInstall<T>> _groups =
      <_GroupSlot, ConsistencyGroupInstall<T>>{};
  final Map<_GroupSlot, Map<ResourceFieldGroup<T>, RequestGeneration>>
  _gateFields = <_GroupSlot, Map<ResourceFieldGroup<T>, RequestGeneration>>{};
  final List<void Function(Map<ResourceFieldGroup<T>, PreparedResource<T>>)>
  _installedListeners =
      <void Function(Map<ResourceFieldGroup<T>, PreparedResource<T>>)>[];
  bool _disposed = false;

  /// Field groups whose value is currently visible, group members included.
  Map<ResourceFieldGroup<T>, PreparedResource<T>> get installed =>
      Map<ResourceFieldGroup<T>, PreparedResource<T>>.unmodifiable(
        <ResourceFieldGroup<T>, PreparedResource<T>>{
          for (final value in _installed.values) value.fieldGroup: value.result,
        },
      );

  /// Consistency groups currently staging members.
  int get trackedGroups => _groups.length;

  PreparedResource<T>? current(ResourceFieldGroup<T> resource) =>
      _installed[_slot(resource)]?.result;

  /// The gate of one consistency group, when a member has been offered.
  ConsistencyGroupInstall<T>? gateFor(ConsistencyGroup group) =>
      _groups[_GroupSlot(group.id, group.position)];

  /// Notified after members became visible, as one map per install step.
  void onInstalled(
    void Function(Map<ResourceFieldGroup<T>, PreparedResource<T>> installed)
    listener,
  ) {
    _installedListeners.add(listener);
  }

  @override
  bool install(
    PreparedResource<T> result,
    PreparationAcceptance<T> acceptance,
  ) => offer(result, acceptance) == GroupInstallOutcome.installed;

  /// Offers one result and reports exactly what happened to it.
  ///
  /// A result without a consistency group installs immediately and reports
  /// [GroupInstallOutcome.installed]. A group member reports `staged` until its
  /// group completes, `installed` when it caused the group to publish, and
  /// `rejected` when it may not be installed at all.
  GroupInstallOutcome offer(
    PreparedResource<T> result,
    PreparationAcceptance<T> acceptance,
  ) {
    if (_disposed) return GroupInstallOutcome.rejected;
    if (!acceptance.canInstall(result) || !manager.canInstall(result)) {
      return GroupInstallOutcome.rejected;
    }
    final group = result.request.consistencyGroup;
    if (group == null) {
      _publish(<PreparedResource<T>>[result]);
      return GroupInstallOutcome.installed;
    }
    final slot = _GroupSlot(group.id, group.position);
    final field = result.request.resource;
    final generation = result.request.generation;
    var gate = _groups[slot];
    if (gate != null) {
      final installedMember = gate.installed[field];
      if (installedMember != null) {
        // Each field group carries its own request generation, so a group run
        // is compared per field: a member older than the installed one is
        // stale, and a newer one starts a new run. Old-run members are never
        // published a second time and never mix with the new run.
        final installedGeneration = installedMember.request.generation.value;
        if (generation.value < installedGeneration) {
          return GroupInstallOutcome.rejected;
        }
        if (generation.value == installedGeneration) {
          return identical(installedMember.request, result.request) ||
                  installedMember.request == result.request
              ? GroupInstallOutcome.installed
              : GroupInstallOutcome.rejected;
        }
        _removeGate(slot);
        gate = null;
      } else {
        final stagedGeneration = _gateFields[slot]?[field];
        if (stagedGeneration != null &&
            generation.value < stagedGeneration.value) {
          return GroupInstallOutcome.rejected;
        }
      }
    }
    final current = gate ?? _newGate(slot, group);
    final outcome = current.offer(result, acceptance);
    if (outcome != GroupInstallOutcome.rejected) {
      _gateFields[slot]![field] = generation;
    }
    if (outcome == GroupInstallOutcome.installed) {
      final members = current.installed.values.toList(growable: false);
      if (!_everyMemberStillInstallable(members)) {
        // Show nothing from this group rather than mix a revoked member with
        // its siblings. The group cannot install as it stands, so it is
        // dropped and will re-stage from a fresh offer.
        current.revoke();
        _removeGate(slot);
        return GroupInstallOutcome.rejected;
      }
      _pruneSupersededGates(group.id, group.position, slot);
      _publish(members);
    } else if (outcome == GroupInstallOutcome.rejected && !current.isActive) {
      _removeGate(slot);
    }
    return outcome;
  }

  ConsistencyGroupInstall<T> _newGate(_GroupSlot slot, ConsistencyGroup group) {
    _gateFields[slot] = <ResourceFieldGroup<T>, RequestGeneration>{};
    return _groups[slot] = ConsistencyGroupInstall<T>(group);
  }

  /// Revokes every gate at [position] and makes staged members un-installable.
  void revokeGroupAt(SourcePosition position) {
    for (final entry in _groups.entries.toList()) {
      if (entry.key.position != position) continue;
      entry.value.revoke();
      _removeGate(entry.key);
    }
  }

  /// Revokes every gate carrying [groupId].
  void revokeGroup(ConsistencyGroupId groupId) {
    for (final entry in _groups.entries.toList()) {
      if (entry.key.id != groupId) continue;
      entry.value.revoke();
      _removeGate(entry.key);
    }
  }

  /// Revokes every tracked gate. Staged members can no longer install.
  void revokeAllGroups() {
    for (final gate in _groups.values) {
      gate.revoke();
    }
    _groups.clear();
    _gateFields.clear();
  }

  /// Forgets one installed resource and revokes the group it came from.
  bool withdraw(ResourceFieldGroup<T> resource) {
    final removed = _installed.remove(_slot(resource));
    if (removed == null) return false;
    final group = removed.result.request.consistencyGroup;
    if (group != null) revokeGroup(group.id);
    return true;
  }

  /// Releases every installed value and gate. Nothing installs afterwards.
  void dispose() {
    _disposed = true;
    revokeAllGroups();
    _gateFields.clear();
    _installed.clear();
    _installedListeners.clear();
  }

  /// Revokes older positions of one group once a newer one installed.
  ///
  /// A gate that lost the race to a newer position of the same group can never
  /// publish a mix of positions, and retaining it would only grow the tracked
  /// set while a stream keeps appending. Positions of another epoch are not
  /// orderable and are left to the source lifecycle owner.
  void _pruneSupersededGates(
    ConsistencyGroupId groupId,
    SourcePosition installed,
    _GroupSlot slot,
  ) {
    for (final entry in _groups.entries.toList()) {
      if (entry.key == slot || entry.key.id != groupId) continue;
      if (entry.key.position.compare(installed) != VersionRelation.older) {
        continue;
      }
      entry.value.revoke();
      _removeGate(entry.key);
    }
  }

  void _removeGate(_GroupSlot slot) {
    _groups.remove(slot);
    _gateFields.remove(slot);
  }

  bool _everyMemberStillInstallable(List<PreparedResource<T>> members) {
    for (final member in members) {
      if (!manager.canInstall(member)) return false;
      if (!manager.acceptanceFor(member.request).canInstall(member)) {
        return false;
      }
    }
    return true;
  }

  void _publish(Iterable<PreparedResource<T>> results) {
    final published = <ResourceFieldGroup<T>, PreparedResource<T>>{};
    for (final result in results) {
      final resource = result.request.resource;
      _installed[_slot(resource)] = _InstalledValue<T>(resource, result);
      published[resource] = result;
    }
    if (published.isEmpty) return;
    final snapshot =
        Map<ResourceFieldGroup<T>, PreparedResource<T>>.unmodifiable(published);
    for (final listener in _installedListeners.toList()) {
      listener(snapshot);
    }
  }

  static _PreparationSlot _slot<T>(ResourceFieldGroup<T> resource) =>
      _PreparationSlot(resource.resource, resource.name);
}

/// One installed value and the field group it belongs to.
final class _InstalledValue<T> {
  const _InstalledValue(this.fieldGroup, this.result);

  final ResourceFieldGroup<T> fieldGroup;
  final PreparedResource<T> result;
}

final class _GroupSlot {
  const _GroupSlot(this.id, this.position);

  final ConsistencyGroupId id;
  final SourcePosition position;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _GroupSlot && other.id == id && other.position == position;

  @override
  int get hashCode => Object.hash(id, position);
}

typedef PreparationInstallerStore<T> = PreparedResourceInstaller<T>;
