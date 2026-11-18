import 'package:presentation_contract/presentation_contract.dart';

import 'cache/byte_lru_cache.dart';
import 'preparation/preparation_manager.dart';
import 'resources/prepared_display.dart';
import 'resources/resource_observation.dart';
import 'resources/source_invalidation.dart';
import 'scheduling/preparation_executor.dart';

/// Container-scoped presentation services.
///
/// Riverpod owns the lifetime of this object. It shares source observations,
/// source-version admission, preparation invalidation, scheduling, and the
/// byte cache for all providers in one [ProviderContainer]. Another container
/// receives a separate instance and therefore cannot leak observations or
/// prepared values across feature/test scopes.
///
/// The runtime is also the application scope that owns source bindings
/// ([own]), the prepared install surfaces ([preparedDisplay]), and authority
/// revocation ([revoke]): a widget's lifetime only ever subscribes to what the
/// runtime presents, so a rebuild cannot reopen a source or re-fetch its data.
final class PresentationRuntime implements PresentationLifecycle {
  PresentationRuntime({
    BoundedPreparationExecutor? executor,
    ByteLruCache<VersionedCacheKey, Object?>? cache,
  }) : executor = executor ?? BoundedPreparationExecutor(),
       cache =
           cache ??
           ByteLruCache<VersionedCacheKey, Object?>(
             capacityBytes: 4 * 1024 * 1024,
           ) {
    preparation = ResourcePreparationManager(
      executor: this.executor,
      cache: this.cache,
    );
    resources = ResourceObservationStore(
      onSnapshot: _onSnapshot,
      onInvalidated: _onInvalidated,
    );
  }

  final BoundedPreparationExecutor executor;
  final ByteLruCache<VersionedCacheKey, Object?> cache;
  late final ResourcePreparationManager preparation;
  late final ResourceObservationStore resources;
  final Map<Type, PreparedInventory> _preparedDisplays =
      <Type, PreparedInventory>{};
  final List<void Function(SourceInvalidation invalidation)>
  _invalidationListeners = <void Function(SourceInvalidation invalidation)>[];
  bool _disposed = false;

  bool get disposed => _disposed;

  ResourceObservationSubscription<T> observe<T>(PresentationSource<T> source) {
    if (_disposed) throw StateError('presentation runtime disposed');
    return resources.observe(source);
  }

  /// Takes application-scope ownership of one source binding.
  ///
  /// Hold the lease for as long as the application needs the resource: while it
  /// is held, dropping the last presentation subscriber neither closes the
  /// source nor re-reads it, and a subscriber that comes back renders the value
  /// already admitted. Release it when the application stops needing the
  /// resource, not when a widget stops looking at it.
  SourceOwnership<T> own<T>(PresentationSource<T> source) {
    if (_disposed) throw StateError('presentation runtime disposed');
    return resources.own(source);
  }

  ResourceSnapshot<T>? current<T>(ResourceFieldGroup<T> resource) =>
      resources.current(resource);

  /// The prepared install surface for one prepared value type.
  ///
  /// The surface is owned by this runtime, so authority revocation and source
  /// replacement observed here also withdraw the prepared values it shows. The
  /// display keeps the consistency group of every value it was offered, and
  /// installs a group's members together.
  PreparedDisplay<T> preparedDisplay<T>() {
    if (_disposed) throw StateError('presentation runtime disposed');
    final existing = _preparedDisplays[T];
    if (existing != null) return existing as PreparedDisplay<T>;
    final display = PreparedDisplay<T>(preparation: preparation);
    _preparedDisplays[T] = display;
    return display;
  }

  /// Withdraws authority over [resource].
  ///
  /// Whatever was read or prepared for that resource stops being visible at
  /// once, staged consistency-group members are dropped rather than completed,
  /// and every result prepared before this call is refused. Prepared values
  /// derived from the resource are withdrawn too, so an incomplete group is
  /// preferred to one that keeps content the application may no longer show.
  void revoke(ResourceKey resource) {
    if (_disposed) return;
    for (final display in _preparedDisplays.values) {
      display.revokeResource(resource);
    }
    resources.revokeResource(resource);
  }

  /// Notified when a value this runtime read loses its validity, after the
  /// runtime has already withdrawn what was derived from it.
  ///
  /// The application scope uses this to re-read a replaced source or to stop a
  /// session it no longer has authority for; the runtime itself only changes
  /// what it presents.
  void onSourceInvalidated(
    void Function(SourceInvalidation invalidation) listener,
  ) {
    _invalidationListeners.add(listener);
  }

  @override
  void pause() {
    if (_disposed) return;
    resources.pause();
  }

  /// Resumes paused source observations without changing durable application
  /// work. This is intentionally separate from [recompute].
  void resume() {
    if (_disposed) return;
    resources.resume();
  }

  @override
  void recompute() {
    if (_disposed) return;
    resources.recompute();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    resources.dispose();
    for (final display in _preparedDisplays.values) {
      display.dispose();
    }
    _preparedDisplays.clear();
    _invalidationListeners.clear();
    preparation.dispose();
    cache.clear(force: true);
  }

  void _onSnapshot(Object snapshot) {
    if (_disposed) return;
    final typed = snapshot as ResourceSnapshot<Object?>;
    preparation.invalidate(typed.fieldGroup, source: typed.position);
  }

  /// One read value lost its validity.
  ///
  /// A revoked resource never installs what was prepared before the
  /// revocation. A replaced source incarnation also makes everything prepared
  /// from the previous epoch un-installable and invisible, because offsets and
  /// block identities only resolve inside the epoch that issued them.
  void _onInvalidated(SourceInvalidation invalidation) {
    if (_disposed) return;
    preparation.invalidate(invalidation.fieldGroup);
    final replaced =
        invalidation.reason == SourceInvalidationReason.epochReplaced
        ? invalidation.replacedEpoch
        : null;
    if (invalidation.reason == SourceInvalidationReason.revoked) {
      for (final display in _preparedDisplays.values) {
        display.revokeResource(invalidation.resource);
      }
    }
    if (replaced != null) {
      for (final display in _preparedDisplays.values) {
        display.revokeEpoch(replaced);
      }
    }
    for (final listener in _invalidationListeners.toList()) {
      listener(invalidation);
    }
  }
}

typedef PresentationResourceRuntime = PresentationRuntime;
