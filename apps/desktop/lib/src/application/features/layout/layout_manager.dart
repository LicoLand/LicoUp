import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_client/src/application/features/layout/layout_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_selection.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';

typedef LayoutSelectionListener = void Function(LayoutSelectionState state);

/// Owns the single transactional selection state independently of widgets.
final class LayoutManager {
  LayoutManager({
    required LayoutCatalog catalog,
    required PresentationPreferencesRepository preferencesRepository,
    required PresentationPreferences canonicalFallback,
    required LayoutEnvironment initialEnvironment,
    LayoutProfileId? preferredDefaultId,
    this.previewTimeout = const Duration(seconds: 12),
  }) : _catalog = catalog,
       _preferencesRepository = preferencesRepository,
       _preferredDefaultId = preferredDefaultId ?? catalog.defaultProfile.id,
       _canonicalFallback = canonicalFallback.copyWith(
         layoutProfileId: preferredDefaultId ?? catalog.defaultProfile.id,
       ),
       _environment = initialEnvironment,
       _state = LayoutSelectionState(
         committedId: preferredDefaultId ?? catalog.defaultProfile.id,
         effectiveId: preferredDefaultId ?? catalog.defaultProfile.id,
         status: LayoutSelectionStatus.loading,
         surface: initialEnvironment.surface,
         viewport: initialEnvironment.viewport,
         operationEpoch: 0,
       ) {
    if (!catalog.containsProfile(_preferredDefaultId)) {
      throw const FormatException('layout_manager_preferred_default_missing');
    }
  }

  final LayoutCatalog _catalog;
  final PresentationPreferencesRepository _preferencesRepository;
  final PresentationPreferences _canonicalFallback;
  final LayoutProfileId _preferredDefaultId;
  final Duration previewTimeout;
  final Set<LayoutSelectionListener> _listeners = {};

  LayoutEnvironment _environment;
  LayoutSelectionState _state;
  PresentationPreferences? _preferences;
  Timer? _previewTimer;
  int _epoch = 0;
  bool _needsCanonicalPersistence = false;
  bool _disposed = false;
  Future<void> _preferenceOperationTail = Future<void>.value();
  Future<void>? _initialization;
  bool _notifyingListeners = false;

  LayoutCatalog get catalog => _catalog;

  /// Platform-preferred default used for first run, recovery, and reset.
  LayoutProfileId get preferredDefaultId => _preferredDefaultId;

  LayoutSelectionState get state => _state;

  PresentationPreferences? get preferences => _preferences;

  bool get initialized => _preferences != null;

  void addListener(LayoutSelectionListener listener) {
    if (_disposed) {
      throw StateError('layout_manager_disposed');
    }
    _listeners.add(listener);
  }

  void removeListener(LayoutSelectionListener listener) {
    _listeners.remove(listener);
  }

  Future<void> initialize() =>
      _initialization ??= _enqueuePreferenceOperation(_initialize);

  Future<void> _initialize() async {
    if (_preferences != null || _disposed) {
      return;
    }
    final epoch = _beginOperation();
    _emit(
      LayoutSelectionState(
        committedId: _state.committedId,
        effectiveId: _state.committedId,
        status: LayoutSelectionStatus.loading,
        surface: _environment.surface,
        viewport: _environment.viewport,
        operationEpoch: epoch,
      ),
    );
    try {
      final loaded = await _preferencesRepository.load();
      if (!_isCurrent(epoch)) {
        return;
      }
      _preferences = loaded.preferences;
      final selected = loaded.preferences.layoutProfileId;
      final available = _catalog.containsProfile(selected);
      final committed = available ? selected : _preferredDefaultId;
      final error = loaded.recovered
          ? LayoutSelectionErrorCode.invalidStoredPreference
          : available
          ? null
          : LayoutSelectionErrorCode.unavailableProfile;
      _needsCanonicalPersistence = error != null;
      if (committed != selected) {
        _preferences = loaded.preferences.copyWith(layoutProfileId: committed);
      }
      _emit(
        LayoutSelectionState(
          committedId: committed,
          effectiveId: committed,
          status: error == null
              ? LayoutSelectionStatus.stable
              : LayoutSelectionStatus.error,
          surface: _environment.surface,
          viewport: _environment.viewport,
          operationEpoch: epoch,
          errorCode: error,
        ),
      );
    } on PresentationPreferencesRepositoryException {
      if (_isCurrent(epoch)) {
        _preferences = _canonicalFallback;
        _needsCanonicalPersistence = true;
        _emit(
          LayoutSelectionState(
            committedId: _preferredDefaultId,
            effectiveId: _preferredDefaultId,
            status: LayoutSelectionStatus.error,
            surface: _environment.surface,
            viewport: _environment.viewport,
            operationEpoch: epoch,
            errorCode: LayoutSelectionErrorCode.persistenceFailed,
          ),
        );
      }
    }
  }

  bool beginPreview(LayoutProfileId candidate) {
    _requireInitialized();
    if (_state.status == LayoutSelectionStatus.committing) {
      return false;
    }
    if (!_catalog.containsProfile(candidate)) {
      final epoch = _beginOperation();
      _emitError(LayoutSelectionErrorCode.unavailableProfile, epoch: epoch);
      return false;
    }
    if (candidate == _state.committedId) {
      cancelPreview();
      return true;
    }

    final epoch = _beginOperation();
    _emit(
      LayoutSelectionState(
        committedId: _state.committedId,
        effectiveId: candidate,
        previewId: candidate,
        status: LayoutSelectionStatus.previewing,
        surface: _environment.surface,
        viewport: _environment.viewport,
        operationEpoch: epoch,
      ),
    );
    _previewTimer = Timer(previewTimeout, () {
      if (_isCurrent(epoch) &&
          _state.status == LayoutSelectionStatus.previewing) {
        final timeoutEpoch = _beginOperation();
        _emitError(
          LayoutSelectionErrorCode.previewExpired,
          epoch: timeoutEpoch,
        );
      }
    });
    return true;
  }

  bool beginPreviewId(String candidate) {
    try {
      return beginPreview(LayoutProfileId.parse(candidate));
    } on FormatException {
      _requireInitialized();
      final epoch = _beginOperation();
      _emitError(LayoutSelectionErrorCode.invalidProfile, epoch: epoch);
      return false;
    }
  }

  void cancelPreview() {
    _requireInitialized();
    if (_state.status == LayoutSelectionStatus.committing) {
      return;
    }
    final epoch = _beginOperation();
    _emitStable(epoch: epoch);
  }

  Future<bool> confirmPreview() async {
    _requireInitialized();
    final candidate = _state.status == LayoutSelectionStatus.previewing
        ? _state.previewId
        : null;
    if (candidate == null) {
      return false;
    }
    return _commit(candidate);
  }

  Future<bool> resetLayout() async {
    _requireInitialized();
    if (_state.status == LayoutSelectionStatus.committing) {
      return false;
    }
    final candidate = _preferredDefaultId;
    if (_state.committedId == candidate && !_needsCanonicalPersistence) {
      final epoch = _beginOperation();
      _emitStable(epoch: epoch);
      return true;
    }
    return _commit(candidate);
  }

  bool updateEnvironment(LayoutEnvironment environment, {bool notify = true}) {
    _requireActive();
    if (_environment == environment) {
      return false;
    }
    _environment = environment;
    final next = LayoutSelectionState(
      committedId: _state.committedId,
      effectiveId: _state.effectiveId,
      previewId: _state.previewId,
      status: _state.status,
      surface: environment.surface,
      viewport: environment.viewport,
      operationEpoch: _state.operationEpoch,
      errorCode: _state.errorCode,
    );
    if (notify) {
      _emit(next);
    } else {
      _state = next;
    }
    return true;
  }

  /// Persists appearance through the same serialized repository as layout.
  /// The layout state machine remains untouched unless this write also
  /// canonicalizes a previously recovered preference document.
  Future<bool> setAppearancePreset(String id) => _updatePresentationPreferences(
    () => _preferencesRepository.setAppearancePreset(id),
  );

  /// Persists locale through the same serialized repository as layout.
  Future<bool> setLocalePreference(String preference) =>
      _updatePresentationPreferences(
        () => _preferencesRepository.setLocalePreference(preference),
      );

  Future<bool> _updatePresentationPreferences(
    Future<PresentationPreferences> Function() update,
  ) {
    _requireInitialized();
    if (_state.status == LayoutSelectionStatus.committing) {
      return Future<bool>.value(false);
    }
    final canonicalLayoutId = _state.committedId;
    return _enqueuePreferenceOperation(() async {
      try {
        var saved = await update();
        if (_disposed) {
          return false;
        }
        if (saved.layoutProfileId != canonicalLayoutId) {
          saved = await _preferencesRepository.setLayoutProfile(
            canonicalLayoutId,
          );
          if (_disposed) {
            return false;
          }
        }
        _preferences = saved;
        _needsCanonicalPersistence = false;
        if (_state.status == LayoutSelectionStatus.error) {
          final epoch = _beginOperation();
          _emitStable(epoch: epoch);
        }
        return true;
      } on PresentationPreferencesRepositoryException {
        return false;
      }
    });
  }

  Future<bool> _commit(LayoutProfileId candidate) async {
    final previousCommitted = _state.committedId;
    final epoch = _beginOperation();
    _emit(
      LayoutSelectionState(
        committedId: previousCommitted,
        effectiveId: candidate,
        previewId: candidate,
        status: LayoutSelectionStatus.committing,
        surface: _environment.surface,
        viewport: _environment.viewport,
        operationEpoch: epoch,
      ),
    );
    try {
      final saved = await _enqueuePreferenceOperation(
        () => _preferencesRepository.setLayoutProfile(candidate),
      );
      if (!_isCurrent(epoch)) {
        return false;
      }
      _preferences = saved;
      _needsCanonicalPersistence = false;
      _emit(
        LayoutSelectionState(
          committedId: candidate,
          effectiveId: candidate,
          status: LayoutSelectionStatus.stable,
          surface: _environment.surface,
          viewport: _environment.viewport,
          operationEpoch: epoch,
        ),
      );
      return true;
    } on PresentationPreferencesRepositoryException {
      if (_isCurrent(epoch)) {
        _emitError(LayoutSelectionErrorCode.persistenceFailed, epoch: epoch);
      }
      return false;
    }
  }

  int _beginOperation() {
    _requireActive();
    if (_notifyingListeners) {
      throw StateError('layout_manager_listener_reentrancy');
    }
    _previewTimer?.cancel();
    _previewTimer = null;
    return ++_epoch;
  }

  void _emitStable({required int epoch}) {
    _emit(
      LayoutSelectionState(
        committedId: _state.committedId,
        effectiveId: _state.committedId,
        status: LayoutSelectionStatus.stable,
        surface: _environment.surface,
        viewport: _environment.viewport,
        operationEpoch: epoch,
      ),
    );
  }

  void _emitError(LayoutSelectionErrorCode code, {required int epoch}) {
    _emit(
      LayoutSelectionState(
        committedId: _state.committedId,
        effectiveId: _state.committedId,
        status: LayoutSelectionStatus.error,
        surface: _environment.surface,
        viewport: _environment.viewport,
        operationEpoch: epoch,
        errorCode: code,
      ),
    );
  }

  void _emit(LayoutSelectionState next) {
    if (_disposed) {
      return;
    }
    _state = next;
    _notifyingListeners = true;
    try {
      for (final listener in List<LayoutSelectionListener>.of(_listeners)) {
        try {
          listener(next);
        } catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'Lico Arc layout manager',
              context: ErrorDescription(
                'while notifying a layout selection listener',
              ),
            ),
          );
        }
      }
    } finally {
      _notifyingListeners = false;
    }
  }

  bool _isCurrent(int epoch) => !_disposed && epoch == _epoch;

  Future<T> _enqueuePreferenceOperation<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _preferenceOperationTail = _preferenceOperationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _requireInitialized() {
    _requireActive();
    if (!initialized) {
      throw StateError('layout_manager_not_initialized');
    }
  }

  void _requireActive() {
    if (_disposed) {
      throw StateError('layout_manager_disposed');
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _previewTimer?.cancel();
    _previewTimer = null;
    _epoch += 1;
    _listeners.clear();
    _disposed = true;
  }
}
