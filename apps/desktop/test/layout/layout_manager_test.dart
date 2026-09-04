import 'dart:async';

import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_catalog_test_fixtures.dart';

void main() {
  test('initialize hydrates before reaching a stable selection', () async {
    final repository = FakePreferencesRepository(
      preferences: preferences(layout: LayoutProfileId.parse('atlas')),
    );
    final manager = createManager(repository);

    expect(manager.state.status, LayoutSelectionStatus.loading);
    expect(manager.initialized, isFalse);
    await manager.initialize();

    expect(manager.initialized, isTrue);
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
    manager.dispose();
  });

  test('selecting the committed profile stays stable without writes', () async {
    final repository = FakePreferencesRepository(preferences: preferences());
    final manager = createManager(repository);
    await manager.initialize();

    expect(
      await manager.selectLayout(LayoutProfileId.parse('dashboard')),
      isTrue,
    );
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.effectiveId, LayoutProfileId.parse('dashboard'));
    expect(repository.layoutWriteCount, 0);
    manager.dispose();
  });

  test('selection persists before promoting the committed profile', () async {
    final repository = FakePreferencesRepository(preferences: preferences());
    final manager = createManager(repository);
    await manager.initialize();
    repository.layoutWriteGate = Completer<void>();

    final selection = manager.selectLayout(LayoutProfileId.parse('atlas'));
    await repository.layoutWriteStarted.future;
    expect(manager.state.status, LayoutSelectionStatus.committing);
    expect(manager.state.effectiveId, LayoutProfileId.parse('atlas'));
    expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));
    expect(
      repository.preferences.layoutProfileId,
      LayoutProfileId.parse('dashboard'),
    );
    // A second selection cannot start while a commit is in flight.
    expect(await manager.selectLayout(LayoutProfileId.parse('focus')), isFalse);
    expect(manager.state.status, LayoutSelectionStatus.committing);

    repository.layoutWriteGate!.complete();
    expect(await selection, isTrue);
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
    expect(
      repository.preferences.layoutProfileId,
      LayoutProfileId.parse('atlas'),
    );
    manager.dispose();
  });

  test('save failure rolls back and exposes only a safe code', () async {
    final repository = FakePreferencesRepository(preferences: preferences());
    final manager = createManager(repository);
    await manager.initialize();
    repository.failNextLayoutWrite = true;

    expect(await manager.selectLayout(LayoutProfileId.parse('atlas')), isFalse);
    expect(manager.state.status, LayoutSelectionStatus.error);
    expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));
    expect(manager.state.effectiveId, LayoutProfileId.parse('dashboard'));
    expect(manager.state.errorCode, LayoutSelectionErrorCode.persistenceFailed);
    manager.dispose();
  });

  test('reset uses the same commit path and preserves other fields', () async {
    final repository = FakePreferencesRepository(
      preferences: preferences(
        layout: LayoutProfileId.parse('atlas'),
        appearance: 'dark',
        locale: 'zh',
      ),
    );
    final manager = createManager(repository);
    await manager.initialize();

    expect(await manager.resetLayout(), isTrue);
    expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));
    expect(repository.preferences.appearancePresetId, 'dark');
    expect(repository.preferences.localePreference, 'zh');
    manager.dispose();
  });

  test('unavailable selections recover deterministically', () async {
    final repository = FakePreferencesRepository(preferences: preferences());
    final manager = createManager(repository);
    await manager.initialize();

    expect(await manager.selectLayout(LayoutProfileId.parse('focus')), isFalse);
    expect(manager.state.status, LayoutSelectionStatus.error);
    expect(manager.state.effectiveId, LayoutProfileId.parse('dashboard'));
    expect(
      manager.state.errorCode,
      LayoutSelectionErrorCode.unavailableProfile,
    );
    expect(repository.layoutWriteCount, 0);

    // A valid selection clears the error and commits normally.
    expect(await manager.selectLayout(LayoutProfileId.parse('atlas')), isTrue);
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
    manager.dispose();
  });

  test(
    'invalid stored document and read failure produce bounded errors',
    () async {
      final invalidRepository = FakePreferencesRepository(
        preferences: preferences(),
        loadIssue: PresentationPreferencesLoadIssue.invalidDocument,
      );
      final invalidManager = createManager(invalidRepository);
      await invalidManager.initialize();
      expect(invalidManager.state.status, LayoutSelectionStatus.error);
      expect(
        invalidManager.state.errorCode,
        LayoutSelectionErrorCode.invalidStoredPreference,
      );
      invalidManager.dispose();

      final failedRepository = FakePreferencesRepository(
        preferences: preferences(),
        failLoad: true,
      );
      final failedManager = createManager(failedRepository);
      await failedManager.initialize();
      expect(failedManager.initialized, isTrue);
      expect(failedManager.preferences, preferences());
      expect(failedManager.state.status, LayoutSelectionStatus.error);
      expect(
        failedManager.state.errorCode,
        LayoutSelectionErrorCode.persistenceFailed,
      );
      expect(await failedManager.resetLayout(), isTrue);
      expect(failedRepository.layoutWriteCount, 1);
      expect(failedManager.state.status, LayoutSelectionStatus.stable);
      failedManager.dispose();
    },
  );

  test('recovery reset persists a canonical default document', () async {
    final invalidRepository = FakePreferencesRepository(
      preferences: preferences(),
      loadIssue: PresentationPreferencesLoadIssue.invalidDocument,
    );
    final invalidManager = createManager(invalidRepository);
    await invalidManager.initialize();

    expect(await invalidManager.resetLayout(), isTrue);
    expect(invalidRepository.layoutWriteCount, 1);
    expect(invalidManager.state.status, LayoutSelectionStatus.stable);
    invalidManager.dispose();

    final unavailableRepository = FakePreferencesRepository(
      preferences: preferences(layout: LayoutProfileId.parse('focus')),
    );
    final unavailableManager = createManager(unavailableRepository);
    await unavailableManager.initialize();

    expect(
      unavailableManager.state.errorCode,
      LayoutSelectionErrorCode.unavailableProfile,
    );
    expect(await unavailableManager.resetLayout(), isTrue);
    expect(unavailableRepository.layoutWriteCount, 1);
    expect(
      unavailableRepository.preferences.layoutProfileId,
      LayoutProfileId.parse('dashboard'),
    );
    unavailableManager.dispose();
  });

  test(
    'all recovery and reset paths use the injected preferred default',
    () async {
      final repository = FakePreferencesRepository(
        preferences: preferences(layout: LayoutProfileId.parse('unavailable')),
      );
      final manager = createManager(
        repository,
        preferredDefaultId: LayoutProfileId.parse('atlas'),
      );

      await manager.initialize();
      expect(manager.preferredDefaultId, LayoutProfileId.parse('atlas'));
      expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
      expect(
        manager.state.errorCode,
        LayoutSelectionErrorCode.unavailableProfile,
      );
      expect(await manager.resetLayout(), isTrue);
      expect(
        repository.preferences.layoutProfileId,
        LayoutProfileId.parse('atlas'),
      );
      manager.dispose();
    },
  );

  test('appearance and locale writes refresh the shared snapshot', () async {
    final repository = FakePreferencesRepository(preferences: preferences());
    final manager = createManager(repository);
    await manager.initialize();

    expect(await manager.setAppearancePreset('dark'), isTrue);
    expect(await manager.setLocalePreference('zh'), isTrue);
    expect(manager.preferences?.appearancePresetId, 'dark');
    expect(manager.preferences?.localePreference, 'zh');
    expect(manager.state.status, LayoutSelectionStatus.stable);
    manager.dispose();
  });

  test(
    'presentation writes serialize safely with a layout selection',
    () async {
      final repository = FakePreferencesRepository(preferences: preferences());
      final manager = createManager(repository);
      await manager.initialize();

      final appearance = manager.setAppearancePreset('dark');
      final selection = manager.selectLayout(LayoutProfileId.parse('atlas'));
      expect(await appearance, isTrue);
      expect(await selection, isTrue);
      expect(
        manager.preferences?.layoutProfileId,
        LayoutProfileId.parse('atlas'),
      );
      expect(manager.preferences?.appearancePresetId, 'dark');
      expect(repository.preferences, manager.preferences);
      manager.dispose();
    },
  );

  test(
    'locale write waits for an active layout commit instead of dropping',
    () async {
      final repository = FakePreferencesRepository(preferences: preferences())
        ..layoutWriteGate = Completer<void>();
      final manager = createManager(repository);
      await manager.initialize();

      final selection = manager.selectLayout(LayoutProfileId.parse('atlas'));
      await repository.layoutWriteStarted.future;
      final locale = manager.setLocalePreference('zh');

      repository.layoutWriteGate!.complete();
      expect(await selection, isTrue);
      expect(await locale, isTrue);
      expect(
        manager.preferences?.layoutProfileId,
        LayoutProfileId.parse('atlas'),
      );
      expect(manager.preferences?.localePreference, 'zh');
      expect(repository.preferences, manager.preferences);
      manager.dispose();
    },
  );

  test(
    'unavailable recovery cannot overwrite a later layout selection',
    () async {
      final repository = FakePreferencesRepository(
        preferences: preferences(layout: LayoutProfileId.parse('focus')),
      );
      final manager = createManager(repository);
      await manager.initialize();
      expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));

      repository.layoutWriteGate = Completer<void>();
      final appearance = manager.setAppearancePreset('dark');
      final selection = manager.selectLayout(LayoutProfileId.parse('atlas'));

      await repository.layoutWriteStarted.future;
      repository.layoutWriteGate!.complete();
      expect(await appearance, isTrue);
      expect(await selection, isTrue);
      expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
      expect(
        repository.preferences.layoutProfileId,
        LayoutProfileId.parse('atlas'),
      );
      expect(repository.preferences.appearancePresetId, 'dark');
      expect(manager.preferences, repository.preferences);
      manager.dispose();
    },
  );

  test(
    'initialization is memoized while the repository load is pending',
    () async {
      final repository = FakePreferencesRepository(preferences: preferences())
        ..loadGate = Completer<void>();
      final manager = createManager(repository);

      final first = manager.initialize();
      final second = manager.initialize();
      expect(identical(first, second), isTrue);
      await repository.loadStarted.future;
      expect(repository.loadCount, 1);

      repository.loadGate!.complete();
      await Future.wait([first, second]);
      await manager.initialize();
      expect(repository.loadCount, 1);
      expect(manager.state.status, LayoutSelectionStatus.stable);
      manager.dispose();
    },
  );

  test(
    'repeated initialization does not invalidate an in-flight commit',
    () async {
      final repository = FakePreferencesRepository(preferences: preferences());
      final manager = createManager(repository);
      await manager.initialize();
      repository.layoutWriteGate = Completer<void>();

      final oldSelection = manager.selectLayout(LayoutProfileId.parse('atlas'));
      await repository.layoutWriteStarted.future;
      final newerInitialization = manager.initialize();
      repository.layoutWriteGate!.complete();

      expect(await oldSelection, isTrue);
      await newerInitialization;
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
      manager.dispose();
    },
  );

  test(
    'listener failures and reentrancy cannot corrupt selection state',
    () async {
      final manager = createManager(
        FakePreferencesRepository(preferences: preferences()),
      );
      await manager.initialize();
      final reported = <Object>[];
      var trailingNotifications = 0;
      Future<bool>? reentrantSelection;

      manager.changes.listen((_) {
        try {
          throw StateError('listener_failed');
        } catch (error) {
          reported.add(error);
        }
      });
      manager.changes.listen((_) {
        if (manager.state.status == LayoutSelectionStatus.stable &&
            reentrantSelection == null) {
          reentrantSelection = manager.selectLayout(
            LayoutProfileId.parse('dashboard'),
          );
        }
      });
      manager.changes.listen((_) => trailingNotifications += 1);

      expect(
        await manager.selectLayout(LayoutProfileId.parse('atlas')),
        isTrue,
      );
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
      expect(trailingNotifications, 2);
      expect(reported, hasLength(2));
      // The reentrant selection from inside the notification is rejected by
      // the operation guard and surfaces as a failed future.
      await expectLater(
        reentrantSelection,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'layout_manager_listener_reentrancy',
          ),
        ),
      );

      expect(
        await manager.selectLayout(LayoutProfileId.parse('dashboard')),
        isTrue,
      );
      expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));
      manager.dispose();
    },
  );

  test('resize updates only the surface-local variant state', () async {
    final repository = FakePreferencesRepository(
      preferences: preferences(layout: LayoutProfileId.parse('atlas')),
    );
    final manager = createManager(repository);
    await manager.initialize();

    manager.updateEnvironment(desktopEnvironment(width: 1400));
    expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
    expect(manager.state.viewport, LayoutViewportClass.expanded);
    expect(repository.layoutWriteCount, 0);
    manager.dispose();
  });

  test('equivalent and silent environment updates do not notify', () async {
    final manager = createManager(
      FakePreferencesRepository(preferences: preferences()),
    );
    await manager.initialize();
    var notifications = 0;
    manager.changes.listen((_) => notifications += 1);

    expect(manager.updateEnvironment(desktopEnvironment(width: 800)), isFalse);
    expect(notifications, 0);
    expect(
      manager.updateEnvironment(desktopEnvironment(width: 1400), notify: false),
      isTrue,
    );
    expect(manager.state.viewport, LayoutViewportClass.expanded);
    expect(notifications, 0);
    expect(manager.updateEnvironment(desktopEnvironment(width: 800)), isTrue);
    expect(notifications, 1);
    manager.dispose();
  });
}

LayoutManager createManager(
  PresentationPreferencesRepository repository, {
  LayoutProfileId? preferredDefaultId,
  Duration? persistenceTimeout,
}) => LayoutManager(
  catalog: fixtureLayoutCatalog(),
  preferencesRepository: repository,
  canonicalFallback: preferences(),
  preferredDefaultId: preferredDefaultId,
  persistenceTimeout: persistenceTimeout ?? const Duration(seconds: 5),
  initialEnvironment: desktopEnvironment(width: 800),
);

PresentationPreferences preferences({
  LayoutProfileId? layout,
  String appearance = 'default-system',
  String locale = 'system',
}) => PresentationPreferences(
  layoutProfileId: layout ?? LayoutProfileId.parse('dashboard'),
  appearancePresetId: appearance,
  localePreference: locale,
);

LayoutEnvironment desktopEnvironment({required double width}) =>
    LayoutEnvironment.fromConstraints(
      surface: LayoutRuntimeSurface.desktop,
      width: width,
      height: 800,
      textScale: 1,
      hasPointer: true,
      hasKeyboard: true,
    );

final class FakePreferencesRepository
    implements PresentationPreferencesRepository {
  FakePreferencesRepository({
    required this.preferences,
    this.loadIssue,
    this.failLoad = false,
  });

  PresentationPreferences preferences;
  final PresentationPreferencesLoadIssue? loadIssue;
  final bool failLoad;
  bool failNextLayoutWrite = false;
  int loadCount = 0;
  int layoutWriteCount = 0;
  Completer<void>? loadGate;
  Completer<void> loadStarted = Completer<void>();
  Completer<void>? layoutWriteGate;
  Completer<void> layoutWriteStarted = Completer<void>();
  Future<void> _tail = Future<void>.value();

  @override
  Future<PresentationPreferencesLoadResult> load() => _enqueue(() async {
    loadCount += 1;
    if (!loadStarted.isCompleted) {
      loadStarted.complete();
    }
    await loadGate?.future;
    if (failLoad) {
      throw const PresentationPreferencesRepositoryException(
        PresentationPreferencesRepositoryErrorCode.readFailed,
      );
    }
    return PresentationPreferencesLoadResult(
      preferences: preferences,
      issue: loadIssue,
    );
  });

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) =>
      _enqueue(() async {
        layoutWriteCount += 1;
        if (!layoutWriteStarted.isCompleted) {
          layoutWriteStarted.complete();
        }
        await layoutWriteGate?.future;
        if (failNextLayoutWrite) {
          failNextLayoutWrite = false;
          throw const PresentationPreferencesRepositoryException(
            PresentationPreferencesRepositoryErrorCode.writeFailed,
          );
        }
        preferences = preferences.copyWith(layoutProfileId: id);
        return preferences;
      });

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) =>
      _enqueue(() async {
        preferences = preferences.copyWith(appearancePresetId: id);
        return preferences;
      });

  @override
  Future<PresentationPreferences> setLocalePreference(String preference) =>
      _enqueue(() async {
        preferences = preferences.copyWith(localePreference: preference);
        return preferences;
      });

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
