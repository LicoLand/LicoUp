import 'package:presentation_contract/presentation_contract.dart';

import 'cache/byte_lru_cache.dart';
import 'preparation/preparation_manager.dart';
import 'resources/resource_observation.dart';
import 'scheduling/preparation_executor.dart';

/// Container-scoped presentation services.
///
/// Riverpod owns the lifetime of this object. It shares source observations,
/// source-version admission, preparation invalidation, scheduling, and the
/// byte cache for all providers in one [ProviderContainer]. Another container
/// receives a separate instance and therefore cannot leak observations or
/// prepared values across feature/test scopes.
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
      onSnapshot: (snapshot) {
        final typed = snapshot as ResourceSnapshot<Object?>;
        preparation.invalidate(typed.fieldGroup, source: typed.position);
      },
    );
  }

  final BoundedPreparationExecutor executor;
  final ByteLruCache<VersionedCacheKey, Object?> cache;
  late final ResourcePreparationManager preparation;
  late final ResourceObservationStore resources;
  bool _disposed = false;

  bool get disposed => _disposed;

  ResourceObservationSubscription<T> observe<T>(PresentationSource<T> source) {
    if (_disposed) throw StateError('presentation runtime disposed');
    return resources.observe(source);
  }

  ResourceSnapshot<T>? current<T>(ResourceFieldGroup<T> resource) =>
      resources.current(resource);

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
    preparation.dispose();
    cache.clear(force: true);
  }
}

typedef PresentationResourceRuntime = PresentationRuntime;
