import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

final class _ResourceFieldIdentity {
  const _ResourceFieldIdentity(this.resource, this.name);

  static _ResourceFieldIdentity of<T>(ResourceFieldGroup<T> group) =>
      _ResourceFieldIdentity(group.resource, group.name);

  final ResourceKey resource;
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ResourceFieldIdentity &&
          other.resource == resource &&
          other.name == name;

  @override
  int get hashCode => Object.hash(resource, name);
}

final class _ConsistencyKey {
  const _ConsistencyKey(this.id, this.position);

  final ConsistencyGroupId id;
  final SourcePosition position;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ConsistencyKey && other.id == id && other.position == position;

  @override
  int get hashCode => Object.hash(id, position);
}

final class _PendingMember {
  const _PendingMember({required this.snapshot, required this.isChange});

  final ResourceSnapshot<Object?> snapshot;
  final bool isChange;
}

final class _PendingGroup {
  _PendingGroup(this.group);

  final ConsistencyGroup group;
  final Map<_ResourceFieldIdentity, _PendingMember> members =
      <_ResourceFieldIdentity, _PendingMember>{};
}

/// A subscription to one resource observation.
final class ResourceObservationSubscription<T> {
  ResourceObservationSubscription._(this.stream, this._close);

  final Stream<ResourceSnapshot<T>> stream;
  final Future<void> Function() _close;
  bool _closed = false;

  bool get closed => _closed;

  Stream<ResourceSnapshot<T>> get snapshots => stream;

  Stream<ResourceSnapshot<T>> get changes => stream;

  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    return _close();
  }
}

typedef SourceObservationStore = ResourceObservationStore;

/// Source observation and consistency-group admission shared by providers in
/// one [ProviderContainer].
final class ResourceObservationStore {
  ResourceObservationStore({this.onSnapshot});

  /// Called after a snapshot has been atomically installed. The value is an
  /// object here so the store remains independent of preparation type erasure.
  final void Function(Object snapshot)? onSnapshot;
  final Map<_ResourceFieldIdentity, _ResourceObservation<Object?>>
  _observations = <_ResourceFieldIdentity, _ResourceObservation<Object?>>{};
  final Map<_ResourceFieldIdentity, ResourceSnapshot<Object?>> _installed =
      <_ResourceFieldIdentity, ResourceSnapshot<Object?>>{};
  final Map<_ConsistencyKey, _PendingGroup> _pending =
      <_ConsistencyKey, _PendingGroup>{};
  bool _disposed = false;

  ResourceObservationSubscription<T> observe<T>(PresentationSource<T> source) {
    if (_disposed) throw StateError('resource observation store disposed');
    final key = _ResourceFieldIdentity.of(source.fieldGroup);
    final existing = _observations[key];
    final observation = existing == null
        ? _ResourceObservation<T>(this, source)
        : existing as _ResourceObservation<T>;
    if (existing == null) {
      _observations[key] = observation as _ResourceObservation<Object?>;
    } else if (!identical(existing.source, source)) {
      throw StateError('two sources registered for the same resource field');
    }
    return observation.attach();
  }

  ResourceSnapshot<T>? current<T>(ResourceFieldGroup<T> resource) {
    return _installed[_ResourceFieldIdentity.of(resource)]
        as ResourceSnapshot<T>?;
  }

  void pause() {
    for (final observation in _observations.values) {
      observation.pause();
    }
  }

  void resume() {
    for (final observation in _observations.values) {
      observation.resume();
    }
  }

  void recompute() {
    for (final observation in _observations.values) {
      observation.restart();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final observation in _observations.values) {
      observation.dispose();
    }
    _pending.clear();
    _installed.clear();
    _observations.clear();
  }

  void _admitInitial<T>(
    _ResourceObservation<T> observation,
    ResourceSnapshot<T> snapshot,
  ) {
    if (snapshot.fieldGroup != observation.fieldGroup) {
      observation.emitError(
        StateError('source initial snapshot has a different field group'),
        StackTrace.current,
      );
      return;
    }
    final group = snapshot.consistencyGroup;
    if (group == null) {
      _installSingle(observation, snapshot);
      return;
    }
    _stage(
      group,
      _ResourceFieldIdentity.of(snapshot.fieldGroup),
      _PendingMember(
        snapshot: snapshot as ResourceSnapshot<Object?>,
        isChange: false,
      ),
    );
    _tryCommit(_ConsistencyKey(group.id, group.position));
  }

  void _admitChange<T>(
    _ResourceObservation<T> observation,
    SourceChange<T> change,
  ) {
    if (!change.hasValidGroup ||
        change.snapshot.fieldGroup != observation.fieldGroup) {
      return;
    }
    final key = _ResourceFieldIdentity.of(change.snapshot.fieldGroup);
    final installed = _installed[key];
    if (installed == null ||
        !change.matchesBase(installed as ResourceSnapshot<T>)) {
      return;
    }
    final group = change.group;
    _stage(
      group,
      key,
      _PendingMember(
        snapshot: change.snapshot as ResourceSnapshot<Object?>,
        isChange: true,
      ),
    );
    _tryCommit(_ConsistencyKey(group.id, group.position));
  }

  void _stage(
    ConsistencyGroup group,
    _ResourceFieldIdentity key,
    _PendingMember member,
  ) {
    if (!group.changed.any(
      (entry) => entry.resource == key.resource && entry.name == key.name,
    )) {
      return;
    }
    final consistencyKey = _ConsistencyKey(group.id, group.position);
    final pending = _pending.putIfAbsent(
      consistencyKey,
      () => _PendingGroup(group),
    );
    pending.members[key] = member;
  }

  void _tryCommit(_ConsistencyKey consistencyKey) {
    final pending = _pending[consistencyKey];
    if (pending == null) return;
    final expected = <_ResourceFieldIdentity>{
      for (final changed in pending.group.changed)
        if (_observations[_ResourceFieldIdentity(
                  changed.resource,
                  changed.name,
                )]
                ?.hasListeners ==
            true)
          _ResourceFieldIdentity(changed.resource, changed.name),
    };
    for (final key in expected) {
      final current = _installed[key];
      if (current == null || pending.members.containsKey(key)) continue;
      final relation = current.position.compare(pending.group.position);
      if (relation == VersionRelation.newer ||
          relation == VersionRelation.differentEpoch ||
          relation == VersionRelation.same &&
              current.consistencyGroup != pending.group) {
        _pending.remove(consistencyKey);
        return;
      }
    }
    if (expected.isEmpty ||
        !expected.every(
          (key) =>
              pending.members.containsKey(key) ||
              _alreadyInstalledAt(key, pending.group),
        )) {
      return;
    }

    for (final key in expected) {
      final member = pending.members[key];
      if (member == null) continue;
      final current = _installed[key];
      if (member.isChange) {
        if (current == null ||
            !member.snapshot.position.isSameEpochAs(current.position) ||
            !member.snapshot.position.isAfter(current.position)) {
          _pending.remove(consistencyKey);
          return;
        }
      } else if (current != null) {
        final relation = member.snapshot.position.compare(current.position);
        if (relation == VersionRelation.older) {
          _pending.remove(consistencyKey);
          return;
        }
        if (relation == VersionRelation.same) {
          if (current.consistencyGroup != pending.group) {
            _pending.remove(consistencyKey);
            return;
          }
          continue;
        }
      }
    }

    _pending.remove(consistencyKey);
    final installed = <_ResourceFieldIdentity, ResourceSnapshot<Object?>>{};
    for (final key in expected) {
      final member = pending.members[key];
      final current = _installed[key];
      if (member != null &&
          (current == null ||
              current.position != member.snapshot.position ||
              current.consistencyGroup != pending.group)) {
        installed[key] = member.snapshot;
      }
    }
    for (final entry in installed.entries) {
      _installed[entry.key] = entry.value;
    }
    for (final entry in installed.entries) {
      final observation = _observations[entry.key];
      observation?.setCurrentAndEmit(entry.value);
      onSnapshot?.call(entry.value);
    }
  }

  bool _alreadyInstalledAt(_ResourceFieldIdentity key, ConsistencyGroup group) {
    final current = _installed[key];
    return current != null &&
        current.position == group.position &&
        current.consistencyGroup == group;
  }

  void _installSingle<T>(
    _ResourceObservation<T> observation,
    ResourceSnapshot<T> snapshot,
  ) {
    final key = _ResourceFieldIdentity.of(snapshot.fieldGroup);
    final current = _installed[key];
    if (current != null) {
      final relation = snapshot.position.compare(current.position);
      if (relation == VersionRelation.older ||
          relation == VersionRelation.same) {
        return;
      }
    }
    _installed[key] = snapshot as ResourceSnapshot<Object?>;
    observation.setCurrentAndEmit(snapshot);
    onSnapshot?.call(snapshot);
  }

  void _listenerCountChanged() {
    for (final key in _pending.keys.toList()) {
      _tryCommit(key);
    }
  }
}

final class _ResourceObservation<T> {
  _ResourceObservation(this.owner, this.source)
    : fieldGroup = source.fieldGroup;

  final ResourceObservationStore owner;
  final PresentationSource<T> source;
  final ResourceFieldGroup<T> fieldGroup;
  final Set<_ResourceListener<T>> _listeners = <_ResourceListener<T>>{};
  ResourceSnapshot<T>? current;
  StreamSubscription<SourceChange<T>>? _sourceSubscription;
  Future<void>? _opening;
  int _lifecycle = 0;
  bool _disposed = false;

  bool get hasListeners => _listeners.isNotEmpty;

  ResourceObservationSubscription<T> attach() {
    if (_disposed) throw StateError('resource observation disposed');
    final controller = StreamController<ResourceSnapshot<T>>();
    late final _ResourceListener<T> listener;
    listener = _ResourceListener<T>(controller, () {
      _listeners.remove(listener);
      owner._listenerCountChanged();
      if (_listeners.isEmpty) _stop();
    });
    controller.onCancel = () {
      if (listener.closed) return;
      listener.closed = true;
      listener.onClose();
    };
    _listeners.add(listener);
    final existing = current;
    if (existing != null) {
      scheduleMicrotask(() {
        if (!listener.closed && !controller.isClosed) controller.add(existing);
      });
    }
    _ensureStarted();
    return ResourceObservationSubscription<T>._(controller.stream, () async {
      if (listener.closed) return;
      listener.closed = true;
      listener.onClose();
      await controller.close();
    });
  }

  void setCurrentAndEmit(ResourceSnapshot<Object?> snapshot) {
    final typed = snapshot as ResourceSnapshot<T>;
    current = typed;
    for (final listener in _listeners.toList()) {
      if (!listener.closed && !listener.controller.isClosed) {
        listener.controller.add(typed);
      }
    }
  }

  void emitError(Object error, StackTrace stack) {
    for (final listener in _listeners.toList()) {
      if (!listener.closed && !listener.controller.isClosed) {
        listener.controller.addError(error, stack);
      }
    }
  }

  void pause() => _stop();

  void resume() => _ensureStarted();

  void restart() {
    _stop();
    _ensureStarted();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stop();
    for (final listener in _listeners.toList()) {
      listener.closed = true;
      unawaited(listener.controller.close());
    }
    _listeners.clear();
  }

  void _ensureStarted() {
    if (_disposed ||
        !hasListeners ||
        _opening != null ||
        _sourceSubscription != null) {
      return;
    }
    final token = ++_lifecycle;
    final opening = _open(token);
    _opening = opening;
    unawaited(opening);
  }

  Future<void> _open(int token) async {
    try {
      final observation = await source.open();
      if (_disposed || token != _lifecycle || !hasListeners) {
        await _discardObservation(observation);
        return;
      }
      if (observation.initial.fieldGroup != fieldGroup) {
        emitError(
          StateError('source observation changed its field group'),
          StackTrace.current,
        );
        await _discardObservation(observation);
        return;
      }
      owner._admitInitial(this, observation.initial);
      if (_disposed || token != _lifecycle || !hasListeners) {
        await _discardObservation(observation);
        return;
      }
      _sourceSubscription = observation.changes.listen(
        (change) {
          if (!_disposed && token == _lifecycle) {
            owner._admitChange(this, change);
          }
        },
        onError: emitError,
        onDone: () {
          _sourceSubscription = null;
        },
      );
    } catch (error, stack) {
      if (!_disposed && token == _lifecycle) emitError(error, stack);
    } finally {
      _opening = null;
      if (!_disposed && token != _lifecycle && hasListeners) _ensureStarted();
    }
  }

  Future<void> _discardObservation(SourceObservation<T> observation) async {
    try {
      await observation.changes.listen((_) {}).cancel();
    } catch (_) {
      // The source is already abandoned; a close race has no presentation
      // listener that could usefully receive the error.
    }
  }

  void _stop() {
    _lifecycle++;
    _opening = null;
    final subscription = _sourceSubscription;
    _sourceSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }
}

final class _ResourceListener<T> {
  _ResourceListener(this.controller, this.onClose);

  final StreamController<ResourceSnapshot<T>> controller;
  final void Function() onClose;
  bool closed = false;
}
