import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'source_invalidation.dart';

final class _ResourceFieldIdentity {
  const _ResourceFieldIdentity(this.resource, this.name);

  static _ResourceFieldIdentity of<T>(ResourceFieldGroup<T> group) =>
      _ResourceFieldIdentity(group.resource, group.name);

  final ResourceKey resource;
  final String name;

  /// The same identity as an untyped field group, so code that is not generic
  /// over the value type can still name it.
  ResourceFieldGroup<Object?> get fieldGroup =>
      ResourceFieldGroup<Object?>(resource: resource, name: name);

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
  const _PendingMember({required this.snapshot, this.base});

  final ResourceSnapshot<Object?> snapshot;
  final SourcePosition? base;
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

/// Connection state of one source binding.
enum SourceConnectionState {
  /// Nothing is open: the source was never read, or its subscription was
  /// released.
  idle,

  /// The source is open, and every update it publishes is merged.
  open,

  /// The source stream ended or failed. Reading again needs an explicit
  /// [SourceOwnership.reconnect]; nothing is retried on a widget's behalf.
  disconnected,
}

/// Application-scope ownership of one source binding.
///
/// The binding belongs to the scope that holds the lease, not to the widgets
/// that happen to display it. A presentation subscriber may come and go without
/// closing the source or reading it again, and the value already admitted is
/// replayed to the next subscriber. Only [release] (or the owning runtime's
/// disposal) lets the source go, so a rebuild that briefly stops watching a
/// resource cannot reopen a session or re-fetch its data.
abstract interface class SourceOwnership<T> {
  ResourceFieldGroup<T> get resource;

  /// The value most recently admitted for [resource], when one was read.
  ResourceSnapshot<T>? get current;

  SourceConnectionState get connection;

  bool get isOpen;

  bool get isDisconnected;

  bool get isPaused;

  /// A presentation subscriber. Closing it never closes an owned binding.
  ResourceObservationSubscription<T> subscribe();

  /// Reads the source again after a disconnect.
  ///
  /// The reopened value is admitted by the same position rules as a live
  /// update: an older version inside the same epoch keeps the installed value,
  /// and a value from another epoch replaces the source incarnation, which
  /// invalidates everything prepared from the previous one.
  Future<void> reconnect();

  /// Gives up one lease. The source is released only when the last lease and
  /// the last presentation subscriber are gone.
  Future<void> release();
}

/// Source observation and consistency-group admission shared by providers in
/// one [ProviderContainer].
final class ResourceObservationStore {
  ResourceObservationStore({this.onSnapshot, this.onInvalidated});

  /// Called after a snapshot has been atomically installed. The value is an
  /// object here so the store remains independent of preparation type erasure.
  final void Function(Object snapshot)? onSnapshot;

  /// Called when a value that was already read loses its validity: the source
  /// incarnation was replaced, or the application withdrew authority.
  final void Function(SourceInvalidation invalidation)? onInvalidated;
  final Map<_ResourceFieldIdentity, _ResourceObservation<Object?>>
  _observations = <_ResourceFieldIdentity, _ResourceObservation<Object?>>{};

  /// Values visible to presentation, advanced only when a whole consistency
  /// group is installable. A view therefore never mixes two group versions.
  final Map<_ResourceFieldIdentity, ResourceSnapshot<Object?>> _installed =
      <_ResourceFieldIdentity, ResourceSnapshot<Object?>>{};

  /// Lossless business admission. It advances as reliable source events are
  /// merged, even while presentation waits for a lagging sibling, so a chained
  /// update is not dropped merely because the previous group is still staging.
  final Map<_ResourceFieldIdentity, ResourceSnapshot<Object?>> _admitted =
      <_ResourceFieldIdentity, ResourceSnapshot<Object?>>{};
  final Map<_ConsistencyKey, _PendingGroup> _pending =
      <_ConsistencyKey, _PendingGroup>{};
  bool _disposed = false;
  bool _draining = false;

  ResourceObservationSubscription<T> observe<T>(PresentationSource<T> source) {
    if (_disposed) throw StateError('resource observation store disposed');
    return _observationFor(source).attach();
  }

  /// Takes application-scope ownership of one source binding.
  ///
  /// The lease keeps the source open across presentation subscribers: a widget
  /// that stops watching no longer closes the binding, and the next subscriber
  /// renders the admitted value without reading the source again. Presentation
  /// subscribers and the lease share one observation, so the source is opened
  /// once per container.
  SourceOwnership<T> own<T>(PresentationSource<T> source) {
    if (_disposed) throw StateError('resource observation store disposed');
    return _observationFor(source).lease();
  }

  /// The value visible for [resource], once it was read and installable.
  ///
  /// Business admission can be ahead of this while a consistency group still
  /// waits for a lagging sibling; a view never observes that half step.
  ResourceSnapshot<T>? current<T>(ResourceFieldGroup<T> resource) {
    return _installed[_ResourceFieldIdentity.of(resource)]
        as ResourceSnapshot<T>?;
  }

  /// Withdraws authority over every field group of [resource].
  ///
  /// The value already read stops being visible, staged group members are
  /// dropped so a revoked member cannot be completed later by its siblings, and
  /// the application scope is told that values derived from the resource are no
  /// longer installable. A change whose base is a withdrawn position is refused
  /// afterwards, so the revoked lineage cannot come back through a late update;
  /// a fresh read (a reconnect, or a new incarnation) is admitted normally,
  /// because the source session belongs to the application.
  void revokeResource(ResourceKey resource) {
    if (_disposed) return;
    _pending.removeWhere(
      (_, pending) => pending.group.changedKeys.contains(resource),
    );
    final revoked = <_ResourceFieldIdentity>[];
    for (final entry in _observations.entries) {
      if (entry.key.resource != resource) continue;
      revoked.add(entry.key);
    }
    final previous = <_ResourceFieldIdentity, ResourceSnapshot<Object?>?>{
      for (final key in revoked) key: _installed.remove(key),
    };
    for (final key in revoked) {
      _admitted.remove(key);
      _observations[key]?.revoke();
    }
    for (final key in revoked) {
      onInvalidated?.call(
        SourceInvalidation(
          reason: SourceInvalidationReason.revoked,
          fieldGroup: key.fieldGroup,
          previous: previous[key]?.position,
        ),
      );
    }
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
    _admitted.clear();
    _observations.clear();
  }

  _ResourceObservation<T> _observationFor<T>(PresentationSource<T> source) {
    final key = _ResourceFieldIdentity.of(source.fieldGroup);
    final existing = _observations[key];
    if (existing == null) {
      final observation = _ResourceObservation<T>(this, source);
      _observations[key] = observation as _ResourceObservation<Object?>;
      return observation;
    }
    if (!identical(existing.source, source)) {
      throw StateError('two sources registered for the same resource field');
    }
    return existing as _ResourceObservation<T>;
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
    final key = _ResourceFieldIdentity.of(snapshot.fieldGroup);
    final installed = _installed[key];
    // Acceptance and rollback protection follow the newest admission, not only
    // what presentation happens to show: a re-read of a position that a staged
    // group already owns is a repeat, not a new value.
    final previous = _admitted[key] ?? installed;
    if (previous != null &&
        !previous.position.isSameEpochAs(snapshot.position)) {
      // The source was replaced. Members staged from the incarnation that is
      // gone cannot complete a group in the new one.
      _pending.removeWhere(
        (consistency, _) =>
            consistency.position.epoch == previous.position.epoch,
      );
    }
    final group = snapshot.consistencyGroup;
    if (group != null &&
        (group.position != snapshot.position ||
            !group.affects(snapshot.fieldGroup))) {
      observation.emitError(
        StateError('source initial snapshot carries an inconsistent group'),
        StackTrace.current,
      );
      return;
    }
    final admitted = _admitted[key];
    if (admitted != null &&
        snapshot.position.compare(admitted.position) == VersionRelation.older) {
      return;
    }
    if (group == null) {
      if (!_acceptsInitialPosition(previous, snapshot)) return;
      _admitted[key] = snapshot as ResourceSnapshot<Object?>;
      _apply(<
        (
          _ResourceFieldIdentity,
          ResourceSnapshot<Object?>?,
          ResourceSnapshot<Object?>,
        )
      >[(key, installed, snapshot as ResourceSnapshot<Object?>)]);
      return;
    }
    _stage(
      group,
      key,
      _PendingMember(snapshot: snapshot as ResourceSnapshot<Object?>),
    );
    _drain();
  }

  /// True when a reopened [snapshot] may replace the [previous] value.
  ///
  /// A source that reconnects can come back with a value it has already moved
  /// past; an older or repeated version inside one epoch is not a new value, so
  /// the installed one stays and the display never rolls back. A position from
  /// another epoch is another incarnation and is admitted as a replacement.
  bool _acceptsInitialPosition<T>(
    ResourceSnapshot<T>? previous,
    ResourceSnapshot<T> snapshot,
  ) {
    if (previous == null) return true;
    final relation = snapshot.position.compare(previous.position);
    return relation == VersionRelation.newer ||
        relation == VersionRelation.differentEpoch;
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
    final installed = _admitted[key] ?? _installed[key];
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
        base: change.base,
      ),
    );
    _drain();
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
    if (pending.group != group) return;
    pending.members[key] = member;
    _admitted[key] = member.snapshot;
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
                ?.hasConsumer ==
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
      if (member.base != null) {
        if (current != null &&
            current.position != member.base &&
            member.base!.isAfter(current.position))
          return;
        if (current == null ||
            current.position != member.base ||
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
    final installs =
        <
          (
            _ResourceFieldIdentity,
            ResourceSnapshot<Object?>?,
            ResourceSnapshot<Object?>,
          )
        >[];
    for (final key in expected) {
      final member = pending.members[key];
      final current = _installed[key];
      if (member != null &&
          (current == null ||
              current.position != member.snapshot.position ||
              current.consistencyGroup != pending.group)) {
        installs.add((key, current, member.snapshot));
      }
    }
    _apply(installs);
  }

  /// Installs one step of member values as a single step.
  ///
  /// Group identity, invalidation of the replaced incarnation, and delivery to
  /// listeners all belong to the same step, so no listener ever observes half a
  /// consistency group, and nothing prepared from a replaced source stays
  /// installable once the replacement is visible.
  void _apply(
    List<
      (
        _ResourceFieldIdentity,
        ResourceSnapshot<Object?>?,
        ResourceSnapshot<Object?>,
      )
    >
    installs,
  ) {
    for (final install in installs) {
      _installed[install.$1] = install.$3;
      _observations[install.$1]?.current = install.$3;
    }
    for (final install in installs) {
      final previous = install.$2;
      if (previous == null) continue;
      final snapshot = install.$3;
      if (previous.position.isSameEpochAs(snapshot.position)) continue;
      onInvalidated?.call(
        SourceInvalidation(
          reason: SourceInvalidationReason.epochReplaced,
          fieldGroup: snapshot.fieldGroup,
          previous: previous.position,
          position: snapshot.position,
        ),
      );
    }
    for (final install in installs) {
      final snapshot = install.$3;
      _observations[install.$1]?.setCurrentAndEmit(snapshot);
      onSnapshot?.call(snapshot);
    }
  }

  bool _alreadyInstalledAt(_ResourceFieldIdentity key, ConsistencyGroup group) {
    final current = _installed[key];
    return current != null &&
        current.position == group.position &&
        current.consistencyGroup == group;
  }

  void _listenerCountChanged() {
    _drain();
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    try {
      int before;
      do {
        before = _pending.length;
        for (final key in _pending.keys.toList()) {
          _tryCommit(key);
        }
      } while (_pending.length < before);
    } finally {
      _draining = false;
    }
  }
}

final class _ResourceObservation<T> implements SourceOwnership<T> {
  _ResourceObservation(this.owner, this.source)
    : fieldGroup = source.fieldGroup;

  final ResourceObservationStore owner;
  final PresentationSource<T> source;

  final ResourceFieldGroup<T> fieldGroup;
  final Set<_ResourceListener<T>> _listeners = <_ResourceListener<T>>{};
  @override
  ResourceSnapshot<T>? current;
  StreamSubscription<SourceChange<T>>? _sourceSubscription;
  Future<void>? _opening;
  int _lifecycle = 0;
  int _leases = 0;
  bool _paused = false;

  SourceConnectionState _connection = SourceConnectionState.idle;
  bool _disposed = false;

  @override
  ResourceFieldGroup<T> get resource => fieldGroup;

  @override
  SourceConnectionState get connection => _connection;

  @override
  bool get isOpen => _connection == SourceConnectionState.open;

  @override
  bool get isDisconnected => _connection == SourceConnectionState.disconnected;

  @override
  bool get isPaused => _paused;

  bool get hasListeners => _listeners.isNotEmpty;

  /// True while the application scope holds this binding.
  bool get isOwned => _leases > 0;

  /// True while something still consumes this binding.
  ///
  /// An application-scope lease merges the source even when no widget is
  /// looking, so a consistency group it belongs to has to complete instead of
  /// waiting for a presentation subscriber that may never arrive.
  bool get hasConsumer => hasListeners || isOwned;

  /// True while anything still needs the source to run.
  bool get _needed => hasConsumer;

  /// Takes one application-scope lease on this binding.
  SourceOwnership<T> lease() {
    if (_disposed) throw StateError('resource observation disposed');
    _leases++;
    _ensureStarted();
    return _SourceLease<T>(this);
  }

  @override
  ResourceObservationSubscription<T> subscribe() => attach();

  ResourceObservationSubscription<T> attach() {
    if (_disposed) throw StateError('resource observation disposed');
    final controller = StreamController<ResourceSnapshot<T>>();
    late final _ResourceListener<T> listener;
    listener = _ResourceListener<T>(controller, () {
      _listeners.remove(listener);
      owner._listenerCountChanged();
      _releaseIfUnneeded();
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
        if (!listener.closed &&
            !controller.isClosed &&
            identical(current, existing) &&
            !_paused) {
          listener.lastPosition = existing.position;
          controller.add(existing);
        }
      });
    }
    _ensureStarted();
    return ResourceObservationSubscription<T>._(
      controller.stream.where(
        (snapshot) => !_disposed && identical(current, snapshot),
      ),
      () async {
        if (listener.closed) return;
        listener.closed = true;
        listener.onClose();
        await controller.close();
      },
    );
  }

  @override
  Future<void> reconnect() {
    if (_disposed) {
      return Future<void>.error(StateError('resource observation disposed'));
    }
    unawaited(_stop());
    return _start();
  }

  @override
  Future<void> release() async {
    if (_leases == 0) return;
    _leases--;
    owner._listenerCountChanged();
    if (_leases > 0 || hasListeners) return;
    await _stop();
  }

  void setCurrentAndEmit(ResourceSnapshot<Object?> snapshot) {
    final typed = snapshot as ResourceSnapshot<T>;
    current = typed;
    if (_paused) return;
    _deliver(typed);
  }

  void emitError(Object error, StackTrace stack) {
    for (final listener in _listeners.toList()) {
      if (!listener.closed && !listener.controller.isClosed) {
        listener.controller.addError(error, stack);
      }
    }
  }

  /// Withdraws the admitted value without touching the source subscription.
  ///
  /// The application scope owns the source session, so authority loss stops the
  /// value being visible here; whether the session itself ends is the
  /// application's decision.
  void revoke() {
    // Fence pending opens and queued stream callbacks without closing a session
    // owned by the application. Only an explicit fresh read can restore it.
    final hadValue = current != null;
    _lifecycle++;
    _opening = null;
    current = null;
    // Presentation keeps no copy of a value the application may no longer show.
    // The withdrawal is reported because a raw data-only stream would otherwise
    // keep rendering the revoked value.
    if (hadValue) {
      emitError(StateError('source authority revoked'), StackTrace.current);
    }
  }

  void pause() {
    _paused = true;
    if (!isOwned) unawaited(_stop());
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _ensureStarted();
    final snapshot = current;
    if (snapshot == null) return;
    // Every listener receives the merged value once, including a subscriber
    // that arrived while delivery was paused; intermediate values stay
    // discardable presentation notifications.
    for (final listener in _listeners.toList()) {
      if (listener.closed || listener.controller.isClosed) continue;
      if (listener.lastPosition == snapshot.position) continue;
      listener.lastPosition = snapshot.position;
      listener.controller.add(snapshot);
    }
  }

  void restart() {
    unawaited(_stop());
    _ensureStarted();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_stop());
    for (final listener in _listeners.toList()) {
      listener.closed = true;
      unawaited(listener.controller.close());
    }
    _listeners.clear();
  }

  void _deliver(ResourceSnapshot<T> snapshot) {
    for (final listener in _listeners.toList()) {
      if (!listener.closed && !listener.controller.isClosed) {
        listener.lastPosition = snapshot.position;
        listener.controller.add(snapshot);
      }
    }
  }

  /// Releases the source when neither presentation nor the application needs
  /// it.
  void _releaseIfUnneeded() {
    if (_needed) return;
    unawaited(_stop());
  }

  void _ensureStarted() {
    unawaited(_start());
  }

  Future<void> _start() {
    if (_disposed || !_needed || (_paused && !isOwned) || isDisconnected) {
      return Future<void>.value();
    }
    final opening = _opening;
    if (opening != null) return opening;
    // A binding that is already open serves every new subscriber from the
    // observation it holds; only [reconnect] and [restart] read it again.
    if (_sourceSubscription != null) return Future<void>.value();
    final token = ++_lifecycle;
    final started = _open(token);
    _opening = started;
    unawaited(started);
    return started;
  }

  Future<void> _stop() {
    _lifecycle++;
    _opening = null;
    _connection = SourceConnectionState.idle;
    final subscription = _sourceSubscription;
    _sourceSubscription = null;
    if (subscription == null) return Future<void>.value();
    return subscription.cancel();
  }

  Future<void> _open(int token) async {
    try {
      final observation = await source.open();
      if (_disposed || token != _lifecycle || !_needed) {
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
      _connection = SourceConnectionState.open;
      owner._admitInitial(this, observation.initial);
      if (_disposed || token != _lifecycle || !_needed) {
        await _discardObservation(observation);
        return;
      }
      _sourceSubscription = observation.changes.listen(
        (change) {
          if (!_disposed && token == _lifecycle) {
            owner._admitChange(this, change);
          }
        },
        onError: (Object error, StackTrace stack) {
          if (_disposed || token != _lifecycle) return;
          _connection = SourceConnectionState.disconnected;
          emitError(error, stack);
        },
        onDone: () {
          if (_disposed || token != _lifecycle) return;
          _sourceSubscription = null;
          _connection = SourceConnectionState.disconnected;
        },
      );
    } catch (error, stack) {
      if (!_disposed && token == _lifecycle) {
        _connection = SourceConnectionState.disconnected;
        emitError(error, stack);
      }
    } finally {
      if (token == _lifecycle) _opening = null;
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
}

/// Each ownership handle releases only its own reference, like Riverpod's
/// keep-alive links; sharing the observation must not share release state.
final class _SourceLease<T> implements SourceOwnership<T> {
  _SourceLease(this.observation);
  final _ResourceObservation<T> observation;
  bool _released = false;

  @override
  ResourceFieldGroup<T> get resource => observation.resource;
  @override
  ResourceSnapshot<T>? get current => observation.current;
  @override
  SourceConnectionState get connection => observation.connection;
  @override
  bool get isOpen => observation.isOpen;
  @override
  bool get isDisconnected => observation.isDisconnected;
  @override
  bool get isPaused => observation.isPaused;
  @override
  ResourceObservationSubscription<T> subscribe() {
    if (_released) throw StateError('source ownership released');
    return observation.subscribe();
  }

  @override
  Future<void> reconnect() {
    if (_released)
      return Future<void>.error(StateError('source ownership released'));
    return observation.reconnect();
  }

  @override
  Future<void> release() {
    if (_released) return Future<void>.value();
    _released = true;
    return observation.release();
  }
}

final class _ResourceListener<T> {
  _ResourceListener(this.controller, this.onClose);

  final StreamController<ResourceSnapshot<T>> controller;
  final void Function() onClose;
  bool closed = false;

  /// The last position handed to this listener, so a resume delivers the merged
  /// value exactly once per listener.
  SourcePosition? lastPosition;
}
