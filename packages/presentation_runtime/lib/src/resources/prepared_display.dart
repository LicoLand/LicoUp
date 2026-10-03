import 'dart:async';
import 'dart:collection';

import 'package:presentation_contract/presentation_contract.dart';

import '../preparation/preparation_manager.dart';
import '../scheduling/preparation_executor.dart' show PreparationPriority;

/// Untyped view of one prepared install surface.
///
/// A runtime holds one surface per prepared value type, so replacing a source or
/// withdrawing authority can reach every visible prepared value without knowing
/// how those values are typed.
abstract interface class PreparedInventory {
  /// Withdraws every visible value prepared for [resource].
  Set<ResourceFieldGroup<Object?>> revokeResource(ResourceKey resource);

  /// Withdraws every visible value prepared from [epoch].
  Set<ResourceFieldGroup<Object?>> revokeEpoch(SourceEpoch epoch);

  /// Releases every visible value and gate. Nothing installs afterwards.
  void dispose();
}

/// The prepared values one display shows, installed a consistency group at a
/// time and withdrawn the moment authority is lost.
///
/// This is the application-facing install surface above the preparation
/// manager: it preserves the consistency group a source read carried all the
/// way to the final install, so a view never mixes two versions of one group
/// and a group that is still loading delays only itself.
///
/// Revocation wins over completeness. Withdrawing authority over a resource, or
/// replacing the source incarnation a value was prepared from, drops the group
/// identity as a whole: the staged members, the members that are already
/// visible, and the positions still waiting all go in the same step, and every
/// result prepared before the withdrawal is refused from then on. An incomplete
/// group is the accepted outcome; a group that keeps content nobody is
/// authorised to show is not.
final class PreparedDisplay<T> implements PreparedInventory {
  PreparedDisplay({required this.preparation})
    : _installer = PreparedResourceInstaller<T>(preparation);

  final ResourcePreparationManager preparation;
  final PreparedResourceInstaller<T> _installer;
  final Map<ResourceFieldGroup<T>, PreparationRequest<T>> _requestOf =
      <ResourceFieldGroup<T>, PreparationRequest<T>>{};
  final Map<ConsistencyGroup, Set<ResourceFieldGroup<T>>> _membersOf =
      <ConsistencyGroup, Set<ResourceFieldGroup<T>>>{};
  final Map<ResourceKey, Set<ResourceFieldGroup<T>>> _fieldsOf =
      <ResourceKey, Set<ResourceFieldGroup<T>>>{};
  final List<void Function(Set<ResourceFieldGroup<T>> withdrawn)>
  _withdrawnListeners = <void Function(Set<ResourceFieldGroup<T>> withdrawn)>[];
  bool _disposed = false;

  bool get disposed => _disposed;

  /// Field groups whose value is visible now, group members included.
  Map<ResourceFieldGroup<T>, PreparedResource<T>> get installed =>
      _installer.installed;

  /// Consistency groups currently staging members.
  int get trackedGroups => _installer.trackedGroups;

  PreparedResource<T>? current(ResourceFieldGroup<T> resource) =>
      _installer.current(resource);

  /// The gate of one consistency group, when a member has been offered.
  ///
  /// [ConsistencyGroupInstall.pending] is the group's own loading state, so a
  /// view can show a local placeholder without waiting for anything else.
  ConsistencyGroupInstall<T>? gateFor(ConsistencyGroup group) =>
      _installer.gateFor(group);

  /// Notified after members became visible, as one map per install step.
  void onInstalled(
    void Function(Map<ResourceFieldGroup<T>, PreparedResource<T>> installed)
    listener,
  ) {
    _installer.onInstalled(listener);
  }

  /// Notified after values stopped being visible, as one set per withdrawal.
  void onWithdrawn(
    void Function(Set<ResourceFieldGroup<T>> withdrawn) listener,
  ) {
    _withdrawnListeners.add(listener);
  }

  bool install(PreparedResource<T> result) =>
      offer(result) == GroupInstallOutcome.installed;

  /// Offers one prepared result and reports exactly what happened to it.
  GroupInstallOutcome offer(PreparedResource<T> result) {
    if (_disposed) return GroupInstallOutcome.rejected;
    if (!preparation.canInstall(result)) return GroupInstallOutcome.rejected;
    _track(result.request);
    final outcome = _installer.offer(
      result,
      preparation.acceptanceFor(result.request),
    );
    _indexGroups();
    return outcome;
  }

  /// Prepares one source position and offers the result to its group.
  ///
  /// [snapshot] is the value being prepared - the field group the preparation
  /// produces, at the position it was read from, carrying the consistency group
  /// the source reported. That group identity is preserved here, so the members
  /// of one group become visible together or not at all.
  Future<GroupInstallOutcome> prepareAndOffer({
    required ResourceSnapshot<T> snapshot,
    required RequestGeneration generation,
    required FutureOr<T> Function() operation,
    Object? variant,
    int estimatedBytes = 0,
    int? resultBytes,
    PreparationPriority priority = PreparationPriority.foreground,
  }) async {
    if (_disposed) return GroupInstallOutcome.rejected;
    // Tracked before the work starts, so a source replacement or a revocation
    // that happens while this preparation is in flight still revokes it.
    _track(
      PreparationRequest<T>.fromSnapshot(
        snapshot: snapshot,
        generation: generation,
      ),
    );
    final result = await preparation.prepare<T>(
      snapshot: snapshot,
      generation: generation,
      operation: operation,
      estimatedBytes: estimatedBytes,
      resultBytes: resultBytes,
      variant: variant,
      priority: priority,
    );
    return offer(result);
  }

  @override
  Set<ResourceFieldGroup<T>> revokeResource(ResourceKey resource) {
    if (_disposed) return <ResourceFieldGroup<T>>{};
    final fields = <ResourceFieldGroup<T>>{
      ...?_fieldsOf[resource],
      for (final value in _installer.installed.values)
        if (value.request.resourceKey == resource) value.request.resource,
    };
    if (fields.isEmpty) return <ResourceFieldGroup<T>>{};
    return _withdraw(fields);
  }

  @override
  Set<ResourceFieldGroup<T>> revokeEpoch(SourceEpoch epoch) {
    if (_disposed) return <ResourceFieldGroup<T>>{};
    final fields = <ResourceFieldGroup<T>>{
      for (final entry in _requestOf.entries)
        if (entry.value.source.epoch == epoch) entry.key,
      for (final value in _installer.installed.values)
        if (value.request.source.epoch == epoch) value.request.resource,
    };
    if (fields.isEmpty) return <ResourceFieldGroup<T>>{};
    return _withdraw(fields);
  }

  /// Releases every visible value and gate. Nothing installs afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _installer.dispose();
    _requestOf.clear();
    _membersOf.clear();
    _fieldsOf.clear();
    _withdrawnListeners.clear();
  }

  void _track(PreparationRequest<T> request) {
    final field = request.resource;
    _requestOf[field] = request;
    _fieldsOf
        .putIfAbsent(request.resourceKey, () => <ResourceFieldGroup<T>>{})
        .add(field);
    _indexGroups();
  }

  void _indexGroups() {
    _membersOf.clear();
    // A field may have an old visible group and a newer in-flight group.
    // Both must be withdrawn; rejected late results never change this index.
    for (final request in <PreparationRequest<T>>[
      ..._requestOf.values,
      for (final value in _installer.installed.values) value.request,
    ]) {
      final group = request.consistencyGroup;
      if (group == null) continue;
      _membersOf
          .putIfAbsent(group, () => <ResourceFieldGroup<T>>{})
          .add(request.resource);
    }
  }

  /// Makes [fields] and every member of their groups invisible at once.
  Set<ResourceFieldGroup<T>> _withdraw(Iterable<ResourceFieldGroup<T>> fields) {
    final targets = <ResourceFieldGroup<T>>{};
    final groups = <ConsistencyGroup>{};
    final queue = ListQueue<ResourceFieldGroup<T>>()..addAll(fields);
    while (queue.isNotEmpty) {
      final field = queue.removeFirst();
      if (!targets.add(field)) continue;
      for (final entry in _membersOf.entries) {
        if (!entry.key.affects(field) || !groups.add(entry.key)) continue;
        queue.addAll(entry.value);
      }
    }
    for (final group in groups) {
      targets.addAll(_membersOf.remove(group) ?? <ResourceFieldGroup<T>>{});
    }
    for (final entry in _fieldsOf.entries.toList()) {
      entry.value.removeAll(targets);
      if (entry.value.isEmpty) _fieldsOf.remove(entry.key);
    }

    final withdrawn = <ResourceFieldGroup<T>>{};
    for (final field in targets) {
      _requestOf.remove(field);
      if (_installer.withdraw(field)) withdrawn.add(field);
      preparation.invalidate(field);
    }
    for (final group in groups) {
      _installer.gateFor(group)?.revoke();
      _installer.revokeGroup(group.id);
    }
    if (withdrawn.isEmpty) return withdrawn;
    final report = Set<ResourceFieldGroup<T>>.unmodifiable(withdrawn);
    for (final listener in _withdrawnListeners.toList()) {
      listener(report);
    }
    return withdrawn;
  }
}

typedef PreparedResourceDisplay<T> = PreparedDisplay<T>;
