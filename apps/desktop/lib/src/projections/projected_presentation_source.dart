import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

int _sourceIncarnations = 0;

/// The client's single presentation-source lifecycle.
///
/// Every feature resource adapter over a [ProjectionSource] is one instance of
/// this class, so pages, dialogs, sidebars and background tabs observe their
/// resources through one lifecycle instead of one private implementation per
/// feature. A feature declares its own resource identity and value read; it
/// never implements listening, race handling, version assignment or cleanup.
///
/// The lifecycle owns, once:
///
/// * **Source identity.** One [SourceEpoch] per incarnation, so a replaced
///   source is a different epoch rather than a newer version of the old one and
///   an old source's position can never be compared as newer.
/// * **Monotonic versions and one consistency group per accepted change**, so
///   an observer installs a whole change or nothing.
/// * **Subscribe-before-read opening.** The producer subscription is
///   established before the initial read and the initial read happens on the
///   same synchronous boundary, so no producer update can fall between them.
/// * **One producer subscription per live observer set.** The first `open()`
///   subscribes, the last cancelled observation releases the subscription, and
///   the installed snapshot survives that release so a reconnect continues the
///   version sequence instead of restarting or rewinding it.
class ProjectedPresentationSource<P, V> implements PresentationSource<V> {
  /// Adapts [projection] to one typed resource [fieldGroup].
  ///
  /// [read] selects the region's value out of the projection; when the
  /// resource value is the projection itself, it may be omitted. [epochKey]
  /// names the source family; uniqueness of the resulting epoch is owned here.
  ProjectedPresentationSource({
    required ProjectionSource<P> projection,
    required this.fieldGroup,
    required String epochKey,
    V Function(P projection)? read,
  }) : _projection = projection,
       _read = read ?? ((P value) => value as V),
       _epoch = SourceEpoch('$epochKey-${++_sourceIncarnations}');

  final ProjectionSource<P> _projection;
  final V Function(P projection) _read;
  final SourceEpoch _epoch;

  @override
  final ResourceFieldGroup<V> fieldGroup;

  final Set<StreamController<SourceChange<V>>> _observers =
      <StreamController<SourceChange<V>>>{};
  StreamSubscription<ProjectionUpdate<P>>? _subscription;
  ResourceSnapshot<V>? _installed;
  bool _disposed = false;

  /// The identity of this source incarnation.
  SourceEpoch get epoch => _epoch;

  /// Whether observers currently hold a producer subscription.
  bool get isObserved => _subscription != null;

  @override
  Future<SourceObservation<V>> open() {
    if (_disposed) {
      return Future<SourceObservation<V>>.error(
        StateError('presentation source is disposed'),
      );
    }
    _subscription ??= _projection.changes.listen(_accept);
    final initial = _snapshotOf(_projection.current);
    final controller = StreamController<SourceChange<V>>(sync: true);
    controller.onCancel = () => _release(controller);
    _observers.add(controller);
    return Future<SourceObservation<V>>.value(
      SourceObservation<V>(initial: initial, changes: controller.stream),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _cancelSubscription();
    for (final controller in _observers.toList()) {
      // A controller whose stream was never attached completes its close
      // future only once a listener drains it; disposal is terminal anyway.
      unawaited(controller.close());
    }
    _observers.clear();
  }

  Future<void> _cancelSubscription() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  void _release(StreamController<SourceChange<V>> controller) {
    if (!_observers.remove(controller)) return;
    unawaited(controller.close());
    if (_observers.isEmpty) unawaited(_cancelSubscription());
  }

  ResourceSnapshot<V> _snapshotOf(P projection) {
    final value = _read(projection);
    final installed = _installed;
    if (installed != null && installed.value == value) return installed;
    final version = SourceVersion((installed?.version.value ?? 0) + 1);
    final position = SourcePosition(epoch: _epoch, version: version);
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        '${fieldGroup.resource.stableKey}-${version.value}',
        source: SourceIdentity(
          scope: fieldGroup.resource.scope,
          stableKey: fieldGroup.resource.stableKey,
        ),
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    final snapshot = ResourceSnapshot<V>(
      fieldGroup: fieldGroup,
      epoch: _epoch,
      version: version,
      value: value,
      consistencyGroup: group,
    );
    _installed = snapshot;
    return snapshot;
  }

  void _accept(ProjectionUpdate<P> update) {
    if (_disposed || _observers.isEmpty) return;
    final previous = _installed;
    final next = _snapshotOf(update.value);
    if (previous == null || identical(next, previous)) return;
    final change = SourceChange<V>(
      snapshot: next,
      base: previous.position,
      group: next.consistencyGroup!,
      trace: update.trace,
    );
    for (final controller in _observers.toList()) {
      if (!controller.isClosed) controller.add(change);
    }
  }
}
