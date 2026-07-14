import 'package:flutter_client/src/application/features/layout/layout_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_selection.dart';
import 'package:flutter_client/src/contracts/presentation/layout_variant.dart';

final class LayoutResolution {
  const LayoutResolution({
    required this.requestedProfileId,
    required this.profile,
    required this.variant,
    required this.recoveryError,
  });

  final LayoutProfileId? requestedProfileId;
  final LayoutProfileDescriptor profile;
  final LayoutVariantCoverage variant;
  final LayoutSelectionErrorCode? recoveryError;

  bool get recoveredToDefault => recoveryError != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutResolution &&
          other.requestedProfileId == requestedProfileId &&
          other.profile == profile &&
          other.variant.key == variant.key &&
          other.recoveryError == recoveryError;

  @override
  int get hashCode =>
      Object.hash(requestedProfileId, profile, variant.key, recoveryError);
}

/// Resolves only the active tuple and retains at most one cached result.
final class LayoutResolver {
  LayoutResolver(LayoutCatalog catalog) : _catalog = catalog;

  LayoutCatalog _catalog;
  _LayoutResolutionCache? _cache;

  LayoutCatalog get catalog => _catalog;

  int get cachedResolutionCount => _cache == null ? 0 : 1;

  LayoutResolution resolve({
    required LayoutProfileId selectedProfileId,
    required LayoutEnvironment environment,
  }) {
    final available = _catalog.containsProfile(selectedProfileId);
    return _resolve(
      requestedProfileId: selectedProfileId,
      resolvedProfileId: available
          ? selectedProfileId
          : _catalog.defaultProfile.id,
      environment: environment,
      recoveryError: available
          ? null
          : LayoutSelectionErrorCode.unavailableProfile,
    );
  }

  LayoutResolution resolveStoredProfile({
    required String storedProfileId,
    required LayoutEnvironment environment,
  }) {
    try {
      return resolve(
        selectedProfileId: LayoutProfileId.parse(storedProfileId),
        environment: environment,
      );
    } on FormatException {
      return _resolve(
        requestedProfileId: null,
        resolvedProfileId: _catalog.defaultProfile.id,
        environment: environment,
        recoveryError: LayoutSelectionErrorCode.invalidStoredPreference,
      );
    }
  }

  void replaceCatalog(LayoutCatalog catalog) {
    if (identical(catalog, _catalog)) {
      return;
    }
    _catalog = catalog;
    _cache = null;
  }

  LayoutResolution _resolve({
    required LayoutProfileId? requestedProfileId,
    required LayoutProfileId resolvedProfileId,
    required LayoutEnvironment environment,
    required LayoutSelectionErrorCode? recoveryError,
  }) {
    final cacheKey = (
      requestedProfileId,
      resolvedProfileId,
      environment.surface,
      environment.viewport,
      _catalog.revision,
      recoveryError,
    );
    final cached = _cache;
    if (cached != null && cached.key == cacheKey) {
      return cached.resolution;
    }

    final profile = _catalog.profile(resolvedProfileId);
    if (profile == null) {
      throw StateError('layout_resolver_default_missing');
    }
    final key = LayoutVariantKey(
      profileId: resolvedProfileId,
      surface: environment.surface,
      viewport: environment.viewport,
    );
    final resolution = LayoutResolution(
      requestedProfileId: requestedProfileId,
      profile: profile,
      variant: _catalog.coverage(key),
      recoveryError: recoveryError,
    );
    _cache = _LayoutResolutionCache(key: cacheKey, resolution: resolution);
    return resolution;
  }
}

typedef _ResolutionCacheKey = (
  LayoutProfileId?,
  LayoutProfileId,
  LayoutRuntimeSurface,
  LayoutViewportClass,
  int,
  LayoutSelectionErrorCode?,
);

final class _LayoutResolutionCache {
  const _LayoutResolutionCache({required this.key, required this.resolution});

  final _ResolutionCacheKey key;
  final LayoutResolution resolution;
}
