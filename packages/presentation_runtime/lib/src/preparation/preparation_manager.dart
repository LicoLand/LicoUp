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
    if (current != null && current.request != request) {
      current.status = PreparationStatus.revoked;
    }
    _states[slot] = _PreparationState(request as PreparationRequest<Object?>);

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
}

typedef PreparationManager = ResourcePreparationManager;
typedef PreparationCoordinator = ResourcePreparationManager;

/// A small installation boundary for prepared values.
///
/// It performs the same acceptance check as the runtime before replacing the
/// installed value for a resource. It does not own business state or invoke
/// actions; it only stores the latest renderer-ready value.
final class PreparedResourceInstaller<T> implements PresentationInstaller<T> {
  PreparedResourceInstaller(this.manager);

  final ResourcePreparationManager manager;
  final Map<_PreparationSlot, PreparedResource<T>> _installed =
      <_PreparationSlot, PreparedResource<T>>{};

  PreparedResource<T>? current(ResourceFieldGroup<T> resource) =>
      _installed[_slot(resource)];

  @override
  bool install(
    PreparedResource<T> result,
    PreparationAcceptance<T> acceptance,
  ) {
    if (!acceptance.canInstall(result) || !manager.canInstall(result)) {
      return false;
    }
    _installed[_slot(result.request.resource)] = result;
    return true;
  }

  static _PreparationSlot _slot<T>(ResourceFieldGroup<T> resource) =>
      _PreparationSlot(resource.resource, resource.name);
}

typedef PreparationInstallerStore<T> = PreparedResourceInstaller<T>;
