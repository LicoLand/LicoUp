import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

/// Reads the region's own slice out of a projected value.
typedef ProjectionSelector<T, S> = S Function(T projection);

/// Receives one committed region value and the cause that produced it.
///
/// [cause] is the trace of the accepted update, or null when the value came
/// from the region's own read of [ProjectionSource.current] — the first attach
/// and a reconnect after a detached background tab.
typedef ProjectionCommit<S> = void Function(S value, TraceContext? cause);

/// The lifecycle class of the region a binding serves.
///
/// Every component that renders business facts — a page, a dialog, a sidebar
/// or a background tab — binds them through [ProjectionBinding]. Two kinds of
/// component are explicitly not business regions, and neither declares a
/// business binding of its own:
///
/// * [appearanceOnly] renders appearance resources only (theme, palette,
///   typography, motion). It may still observe an appearance projection
///   through the same facility, but it is not a business region and does not
///   participate in region invalidation accounting.
/// * [renderingExtension] is registered by the layout registry and renders the
///   subtrees it is handed. It owns local focus and animation, and declares no
///   resource; its registry entry is the classification.
enum ShellRegionClass { business, appearance, renderingExtension }

/// One region's subscription to one projection source.
///
/// This is the client's single region lifecycle. It owns the generation fence,
/// the subscribe-before-read order, gap recovery on reconnect, detach for a
/// background tab, revoke, and the cancel/dispose ordering, so no page, dialog,
/// sidebar or background tab implements its own listening, race handling,
/// debouncing or cleanup.
///
/// **Generations.** Every (re)subscribe, detach and revoke advances
/// [generation] *before* the previous subscription is cancelled. A delivery
/// carrying a superseded generation is dropped, so A→B→A, an out-of-order
/// producer and a revoke can never mix two sources' values, and a value
/// removed by revocation is never echoed back.
///
/// **Attach and detach.** [activate] subscribes first and then reads
/// [ProjectionSource.current] on the same synchronous boundary, so an update
/// published between the two cannot be dropped. [deactivate] releases the
/// subscription while the region keeps its last committed value; the next
/// [activate] re-reads the source, which closes whatever gap opened while the
/// region was detached. A reattach publishes only a real change, so an
/// unchanged value never rebuilds the region.
final class ProjectionBinding<T, S> {
  ProjectionBinding({
    required ProjectionSource<T> source,
    required ProjectionSelector<T, S> select,
    required ProjectionCommit<S> onValue,
    void Function()? onRevoked,
    this.region = ShellRegionClass.business,
  }) : assert(
         region != ShellRegionClass.renderingExtension,
         'a registered rendering extension declares no resource binding; '
         'its registry entry is its classification',
       ),
       _source = source,
       _select = select,
       _onValue = onValue,
       _onRevoked = onRevoked,
       _value = select(source.current);

  ProjectionSource<T> _source;
  ProjectionSelector<T, S> _select;
  final ProjectionCommit<S> _onValue;
  final void Function()? _onRevoked;

  /// The lifecycle class this region was declared with.
  final ShellRegionClass region;

  StreamSubscription<ProjectionUpdate<T>>? _subscription;
  S _value;
  int _generation = 0;
  bool _attached = false;
  bool _observed = false;
  bool _revoked = false;
  bool _disposed = false;

  /// The current generation. It advances on every rebind, detach and revoke.
  int get generation => _generation;

  /// The last committed value of this region.
  S get value => _value;

  /// The source this region observes.
  ProjectionSource<T> get source => _source;

  /// Whether the region currently holds a subscription.
  bool get isAttached => _attached;

  /// Whether the source was revoked. A revoked region renders absence and
  /// accepts no further delivery until a source is installed again.
  bool get isRevoked => _revoked;

  /// Subscribes to the source and reads its current value on the same
  /// synchronous boundary.
  void activate() {
    if (_disposed || _revoked || _attached) return;
    _attached = true;
    _subscribe();
  }

  /// Releases the subscription while keeping the last committed value.
  ///
  /// A background tab uses this while it is not visible. The value it renders
  /// stays at the last committed generation; the next [activate] re-reads the
  /// source so no update that happened while detached is lost.
  void deactivate() {
    if (!_attached) return;
    _attached = false;
    _releaseSubscription();
  }

  /// Revokes the source: the region stops observing it and a business region
  /// is told to render its absence.
  ///
  /// The generation advances before the subscription is cancelled, so a
  /// delivery already in flight from the revoked source is dropped instead of
  /// resurrecting content the owner removed. An [ShellRegionClass.appearance]
  /// region keeps its last committed value, because an uninstalled appearance
  /// package resolves to a platform fallback rather than to an absent window.
  void revoke() {
    if (_disposed || _revoked) return;
    _revoked = true;
    _attached = false;
    _releaseSubscription();
    if (region == ShellRegionClass.business) _onRevoked?.call();
  }

  /// Replaces the observed source and/or the selector.
  ///
  /// Rebinding installs the new generation before the previous subscription is
  /// cancelled, so a delivery racing the cancel is dropped. An attached region
  /// reads the new source immediately, which is what makes A→B→A return to A's
  /// current facts instead of B's stale ones.
  void rebind({ProjectionSource<T>? source, ProjectionSelector<T, S>? select}) {
    if (_disposed) return;
    if (select != null) _select = select;
    final next = source;
    if (next != null && !identical(next, _source)) {
      final wasRevoked = _revoked;
      _revoked = false;
      _source = next;
      _releaseSubscription();
      if (_attached) {
        _subscribe();
      } else if (wasRevoked) {
        // The region was told to render an absence; installing a source is a
        // real change from that absence even while the region is detached.
        _value = _select(_source.current);
      }
      if (wasRevoked) _onValue(_value, null);
      return;
    }
    if (_attached) {
      _commit(_generation, _select(_source.current), null);
    } else {
      _value = _select(_source.current);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _attached = false;
    final subscription = _subscription;
    _subscription = null;
    _generation++;
    await subscription?.cancel();
  }

  void _subscribe() {
    final generation = ++_generation;
    _subscription = _source.changes.listen(
      (update) => _handle(generation, update),
    );
    _commit(generation, _select(_source.current), null);
    _observed = true;
  }

  void _releaseSubscription() {
    _generation++;
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
  }

  void _handle(int generation, ProjectionUpdate<T> update) {
    if (_disposed || _revoked || !_attached) return;
    _commit(generation, _select(update.value), update.trace);
  }

  void _commit(int generation, S next, TraceContext? cause) {
    if (generation != _generation) return;
    if (next == _value) return;
    _value = next;
    // The first attach reports through [value]; a reconnect reports the gap it
    // closed, because the region was rendering the detached generation.
    if (!_observed) return;
    _onValue(next, cause);
  }
}
