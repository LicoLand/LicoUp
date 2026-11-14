import 'dart:async';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/layout/layout_catalog.dart';
import 'package:licoup/src/application/features/layout/layout_preference_state.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';

import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';

/// Owns the single transactional selection state independently of widgets.
final class LayoutManager {
  LayoutManager({
    required LayoutCatalog catalog,
    required PresentationPreferencesRepository preferencesRepository,
    required PresentationPreferences canonicalFallback,
    this.persistenceTimeout = const Duration(seconds: 5),
  }) : _catalog = catalog,
       _preferencesRepository = preferencesRepository,
       _defaultId = catalog.defaultProfile.id,
       _canonicalFallback = canonicalFallback.copyWith(
         layoutProfileId: catalog.defaultProfile.id,
       ),
       _state = LayoutPreferenceState(
         committedId: catalog.defaultProfile.id,
         effectiveId: catalog.defaultProfile.id,
         status: LayoutSelectionStatus.loading,
         operationEpoch: 0,
       );

  final LayoutCatalog _catalog;
  final PresentationPreferencesRepository _preferencesRepository;
  final PresentationPreferences _canonicalFallback;
  final LayoutProfileId _defaultId;

  /// Upper bound for any single repository call the manager performs. A
  /// repository that hangs (file lock held by a rogue process, blocked I/O)
  /// must not freeze the selection state machine: the timeout fires inside
  /// the serialized queue so the queue tail always advances again.
  final Duration persistenceTimeout;
  final StreamController<ApplicationChange> _changes =
      StreamController<ApplicationChange>.broadcast(sync: true);
  final StreamController<ApplicationChange> _selectionChanges =
      StreamController<ApplicationChange>.broadcast(sync: true);

  LayoutPreferenceState _state;
  PresentationPreferences? _preferences;
  int _epoch = 0;
  bool _needsCanonicalPersistence = false;
  bool _disposed = false;
  Future<void> _preferenceOperationTail = Future<void>.value();
  Future<void>? _initialization;
  bool _publishing = false;

  LayoutCatalog get catalog => _catalog;

  /// The catalog default used for first run, recovery, and reset.
  LayoutProfileId get defaultId => _defaultId;

  LayoutPreferenceState get state => _state;

  PresentationPreferences? get preferences => _preferences;

  bool get initialized => _preferences != null;

  Stream<ApplicationChange> get changes => _changes.stream;
  Stream<ApplicationChange> get selectionChanges => _selectionChanges.stream;

  Future<void> initialize({bool loadStoredState = true}) =>
      _initialization ??= _enqueuePreferenceOperation(
        () => _initialize(loadStoredState: loadStoredState),
      );

  Future<void> _initialize({required bool loadStoredState}) async {
    if (_preferences != null || _disposed) {
      return;
    }
    final epoch = _beginOperation();
    _emit(
      LayoutPreferenceState(
        committedId: _state.committedId,
        effectiveId: _state.committedId,
        status: LayoutSelectionStatus.loading,
        operationEpoch: epoch,
      ),
    );
    if (!loadStoredState) {
      _useCanonicalFallback(epoch);
      return;
    }
    try {
      final loaded = await _preferencesRepository.load().timeout(
        persistenceTimeout,
      );
      if (!_isCurrent(epoch)) {
        return;
      }
      _preferences = loaded.preferences;
      final selected = loaded.preferences.layoutProfileId;
      final available = _catalog.containsProfile(selected);
      final committed = available ? selected : _defaultId;
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
        LayoutPreferenceState(
          committedId: committed,
          effectiveId: committed,
          status: error == null
              ? LayoutSelectionStatus.stable
              : LayoutSelectionStatus.error,
          operationEpoch: epoch,
          errorCode: error,
          effectiveStyleId: _effectiveStyleFor(committed),
        ),
      );
    } catch (_) {
      _useCanonicalFallback(epoch);
    }
  }

  void _useCanonicalFallback(int epoch) {
    if (!_isCurrent(epoch)) return;
    _preferences = _canonicalFallback;
    _needsCanonicalPersistence = true;
    _emit(
      LayoutPreferenceState(
        committedId: _defaultId,
        effectiveId: _defaultId,
        status: LayoutSelectionStatus.error,
        operationEpoch: epoch,
        errorCode: LayoutSelectionErrorCode.persistenceFailed,
        effectiveStyleId: _effectiveStyleFor(_defaultId),
      ),
    );
  }

  /// The style the effective profile renders with: the stored choice when
  /// the profile declares it, else the profile's declared default. Profiles
  /// without styles resolve to null.
  LayoutStyleId? _effectiveStyleFor(LayoutProfileId profileId) {
    final descriptor = _catalog.profile(profileId);
    final defaultStyleId = descriptor?.defaultStyleId;
    if (defaultStyleId == null) {
      return null;
    }
    final stored = _preferences?.layoutStyleIds[profileId];
    if (stored != null &&
        descriptor!.styles.any((style) => style.id == stored)) {
      return stored;
    }
    return defaultStyleId;
  }

  /// Selects a layout directly: the candidate becomes effective immediately
  /// while the preference write commits in the background.
  Future<bool> selectLayout(
    LayoutProfileId candidate, {
    ApplicationCause? cause,
  }) {
    _requireInitialized();
    if (_state.status == LayoutSelectionStatus.committing) {
      return Future<bool>.value(false);
    }
    if (!_catalog.containsProfile(candidate)) {
      final epoch = _beginOperation();
      _emitError(
        LayoutSelectionErrorCode.unavailableProfile,
        epoch: epoch,
        cause: cause,
      );
      return Future<bool>.value(false);
    }
    if (candidate == _state.committedId && !_needsCanonicalPersistence) {
      final epoch = _beginOperation();
      _emitStable(epoch: epoch, cause: cause);
      return Future<bool>.value(true);
    }
    return _commit(candidate, cause: cause);
  }

  Future<bool> resetLayout() async {
    _requireInitialized();
    if (_state.status == LayoutSelectionStatus.committing) {
      return false;
    }
    final candidate = _defaultId;
    if (_state.committedId == candidate && !_needsCanonicalPersistence) {
      final epoch = _beginOperation();
      _emitStable(epoch: epoch);
      return true;
    }
    return _commit(candidate);
  }

  /// Persists one profile's column-style choice through the same serialized
  /// repository and epoch semantics as the profile selection. A style the
  /// profile does not declare is rejected without a repository write.
  Future<bool> selectStyle(
    LayoutProfileId profile,
    LayoutStyleId style, {
    ApplicationCause? cause,
  }) {
    _requireInitialized();
    if (_state.status == LayoutSelectionStatus.committing) {
      return Future<bool>.value(false);
    }
    final descriptor = _catalog.profile(profile);
    final declared =
        descriptor != null &&
        descriptor.styles.any((candidate) => candidate.id == style);
    if (!declared) {
      final epoch = _beginOperation();
      _emitError(
        LayoutSelectionErrorCode.unavailableProfile,
        epoch: epoch,
        cause: cause,
      );
      return Future<bool>.value(false);
    }
    if (_preferences?.layoutStyleIds[profile] == style &&
        !_needsCanonicalPersistence) {
      final epoch = _beginOperation();
      _emitStable(epoch: epoch, cause: cause);
      return Future<bool>.value(true);
    }
    return _commitStyle(profile, style, cause: cause);
  }

  /// Persists appearance through the same serialized repository as layout.
  /// The layout state machine remains untouched unless this write also
  /// canonicalizes a previously recovered preference document.
  Future<bool> setAppearancePreset(String id, {ApplicationCause? cause}) =>
      _updatePresentationPreferences(
        () => _preferencesRepository.setAppearancePreset(id),
        cause: cause,
      );

  /// Persists locale through the same serialized repository as layout.
  Future<bool> setLocalePreference(
    String preference, {
    ApplicationCause? cause,
  }) => _updatePresentationPreferences(
    () => _preferencesRepository.setLocalePreference(preference),
    cause: cause,
  );

  Future<bool> setReduceMotion(
    ReduceMotionPreference preference, {
    ApplicationCause? cause,
  }) => _updatePresentationPreferences(
    () => _preferencesRepository.setReduceMotion(preference),
    cause: cause,
  );

  Future<bool> setLoadingEffect(String id, {ApplicationCause? cause}) =>
      _updatePresentationPreferences(
        () => _preferencesRepository.setLoadingEffect(id),
        cause: cause,
      );

  Future<bool> _updatePresentationPreferences(
    Future<PresentationPreferences> Function() update, {
    ApplicationCause? cause,
  }) async {
    _requireInitialized();
    if (_state.status == LayoutSelectionStatus.committing &&
        !await _waitForLayoutCommit()) {
      return false;
    }
    final canonicalLayoutId = _state.committedId;
    return _enqueuePreferenceOperation(() async {
      try {
        var saved = await update().timeout(persistenceTimeout);
        if (_disposed) {
          return false;
        }
        if (saved.layoutProfileId != canonicalLayoutId) {
          saved = await _preferencesRepository
              .setLayoutProfile(canonicalLayoutId)
              .timeout(persistenceTimeout);
          if (_disposed) {
            return false;
          }
        }
        _preferences = saved;
        _needsCanonicalPersistence = false;
        if (_state.status == LayoutSelectionStatus.error) {
          final epoch = _beginOperation();
          _emitStable(epoch: epoch, cause: cause);
        }
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  Future<bool> _waitForLayoutCommit() async {
    if (_state.status != LayoutSelectionStatus.committing) return true;
    if (_state.status == LayoutSelectionStatus.committing) {
      try {
        await changes
            .firstWhere(
              (_) => _state.status != LayoutSelectionStatus.committing,
            )
            .timeout(persistenceTimeout);
      } on TimeoutException {
        return false;
      }
    }
    return !_disposed;
  }

  Future<bool> _commit(
    LayoutProfileId candidate, {
    ApplicationCause? cause,
  }) async {
    final previousCommitted = _state.committedId;
    final epoch = _beginOperation();
    _emit(
      LayoutPreferenceState(
        committedId: previousCommitted,
        effectiveId: candidate,
        status: LayoutSelectionStatus.committing,
        operationEpoch: epoch,
        effectiveStyleId: _effectiveStyleFor(candidate),
      ),
      cause: cause,
    );
    try {
      final saved = await _enqueuePreferenceOperation(
        () => _preferencesRepository
            .setLayoutProfile(candidate)
            .timeout(persistenceTimeout),
      );
      if (!_isCurrent(epoch)) {
        return false;
      }
      _preferences = saved;
      _needsCanonicalPersistence = false;
      _emit(
        LayoutPreferenceState(
          committedId: candidate,
          effectiveId: candidate,
          status: LayoutSelectionStatus.stable,
          operationEpoch: epoch,
          effectiveStyleId: _effectiveStyleFor(candidate),
        ),
        cause: cause,
      );
      return true;
    } catch (_) {
      // Any repository failure — declared persistence errors, unexpected
      // throws, or a hung write cut off by the timeout — must end the commit
      // so the selector never freezes in the committing state.
      if (_isCurrent(epoch)) {
        _emitError(
          LayoutSelectionErrorCode.persistenceFailed,
          epoch: epoch,
          cause: cause,
        );
      }
      return false;
    }
  }

  Future<bool> _commitStyle(
    LayoutProfileId profile,
    LayoutStyleId style, {
    ApplicationCause? cause,
  }) async {
    final epoch = _beginOperation();
    _emit(
      LayoutPreferenceState(
        committedId: _state.committedId,
        effectiveId: _state.effectiveId,
        status: LayoutSelectionStatus.committing,
        operationEpoch: epoch,
        // The style applies optimistically while the write commits, the same
        // way a candidate profile becomes effective before its write lands.
        effectiveStyleId: profile == _state.effectiveId
            ? style
            : _state.effectiveStyleId,
      ),
      cause: cause,
    );
    try {
      final saved = await _enqueuePreferenceOperation(
        () => _preferencesRepository
            .setLayoutStyle(profile, style)
            .timeout(persistenceTimeout),
      );
      if (!_isCurrent(epoch)) {
        return false;
      }
      _preferences = saved;
      _needsCanonicalPersistence = false;
      _emit(
        LayoutPreferenceState(
          committedId: _state.committedId,
          effectiveId: _state.effectiveId,
          status: LayoutSelectionStatus.stable,
          operationEpoch: epoch,
          effectiveStyleId: _effectiveStyleFor(_state.effectiveId),
        ),
        cause: cause,
      );
      return true;
    } catch (_) {
      // Mirror the profile commit: any repository failure ends the commit so
      // the selector never freezes in the committing state.
      if (_isCurrent(epoch)) {
        _emitError(
          LayoutSelectionErrorCode.persistenceFailed,
          epoch: epoch,
          cause: cause,
        );
      }
      return false;
    }
  }

  int _beginOperation() {
    _requireActive();
    if (_publishing) {
      throw StateError('layout_manager_listener_reentrancy');
    }
    return ++_epoch;
  }

  void _emitStable({required int epoch, ApplicationCause? cause}) {
    _emit(
      LayoutPreferenceState(
        committedId: _state.committedId,
        effectiveId: _state.committedId,
        status: LayoutSelectionStatus.stable,
        operationEpoch: epoch,
        effectiveStyleId: _effectiveStyleFor(_state.committedId),
      ),
      cause: cause,
    );
  }

  void _emitError(
    LayoutSelectionErrorCode code, {
    required int epoch,
    ApplicationCause? cause,
  }) {
    _emit(
      LayoutPreferenceState(
        committedId: _state.committedId,
        effectiveId: _state.committedId,
        status: LayoutSelectionStatus.error,
        operationEpoch: epoch,
        errorCode: code,
        effectiveStyleId: _effectiveStyleFor(_state.committedId),
      ),
      cause: cause,
    );
  }

  void _emit(LayoutPreferenceState next, {ApplicationCause? cause}) {
    if (_disposed) {
      return;
    }
    // The selection projection reads effectiveId, effectiveStyleId and the
    // loading bit, so subscribers need an event when either moves or when
    // the state leaves the initial loading bit — otherwise an unchanged
    // stored preference would leave the shell on the loading spinner forever.
    final selectionChanged =
        next.effectiveId != _state.effectiveId ||
        next.effectiveStyleId != _state.effectiveStyleId ||
        _state.status == LayoutSelectionStatus.loading;
    _state = next;
    _publishing = true;
    try {
      _changes.add(ApplicationChange(cause: cause));
      if (selectionChanged) {
        _selectionChanges.add(ApplicationChange(cause: cause));
      }
    } finally {
      _publishing = false;
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
    _epoch += 1;
    _disposed = true;
    unawaited(_changes.close());
    unawaited(_selectionChanges.close());
  }
}
