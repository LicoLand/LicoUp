import 'dart:async';

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
    required LayoutEnvironment initialEnvironment,
    this.previewTimeout = const Duration(seconds: 12),
  }) : _catalog = catalog,
       _preferencesRepository = preferencesRepository,
       _environment = initialEnvironment,
       _state = LayoutSelectionState(
         committedId: catalog.defaultProfile.id,
         effectiveId: catalog.defaultProfile.id,
         status: LayoutSelectionStatus.loading,
         surface: initialEnvironment.surface,
         viewport: initialEnvironment.viewport,
         operationEpoch: 0,
       );

  final LayoutCatalog _catalog;
  final PresentationPreferencesRepository _preferencesRepository;
  final Duration previewTimeout;
  final Set<LayoutSelectionListener> _listeners = {};

  LayoutEnvironment _environment;
  LayoutSelectionState _state;
  PresentationPreferences? _preferences;
  Timer? _previewTimer;
  int _epoch = 0;
  bool _disposed = false;

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

  Future<void> initialize() async {
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
      final committed = available ? selected : _catalog.defaultProfile.id;
      final error = loaded.recovered
          ? LayoutSelectionErrorCode.invalidStoredPreference
          : available
          ? null
          : LayoutSelectionErrorCode.unavailableProfile;
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
        _emitError(LayoutSelectionErrorCode.persistenceFailed, epoch: epoch);
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
        _emitStable(epoch: timeoutEpoch);
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
    final candidate = _catalog.defaultProfile.id;
    if (_state.committedId == candidate) {
      final epoch = _beginOperation();
      _emitStable(epoch: epoch);
      return true;
    }
    return _commit(candidate);
  }

  void updateEnvironment(LayoutEnvironment environment) {
    _requireActive();
    _environment = environment;
    _emit(
      LayoutSelectionState(
        committedId: _state.committedId,
        effectiveId: _state.effectiveId,
        previewId: _state.previewId,
        status: _state.status,
        surface: environment.surface,
        viewport: environment.viewport,
        operationEpoch: _state.operationEpoch,
        errorCode: _state.errorCode,
      ),
    );
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
      final saved = await _preferencesRepository.setLayoutProfile(candidate);
      if (!_isCurrent(epoch)) {
        return false;
      }
      _preferences = saved;
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
    for (final listener in List<LayoutSelectionListener>.of(_listeners)) {
      listener(next);
    }
  }

  bool _isCurrent(int epoch) => !_disposed && epoch == _epoch;

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
