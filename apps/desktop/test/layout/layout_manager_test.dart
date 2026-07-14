import 'dart:async';

import 'package:flutter_client/src/application/features/layout/layout_manager.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_selection.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_catalog_test_fixtures.dart';

void main() {
  test('initialize hydrates before reaching a stable selection', () async {
    final repository = FakePreferencesRepository(
      preferences: preferences(layout: LayoutProfileId.studio),
    );
    final manager = createManager(repository);

    expect(manager.state.status, LayoutSelectionStatus.loading);
    expect(manager.initialized, isFalse);
    await manager.initialize();

    expect(manager.initialized, isTrue);
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.committedId, LayoutProfileId.studio);
    manager.dispose();
  });

  test('preview is memory-only and cancel restores committed state', () async {
    final repository = FakePreferencesRepository(preferences: preferences());
    final manager = createManager(repository);
    await manager.initialize();

    expect(manager.beginPreview(LayoutProfileId.studio), isTrue);
    expect(manager.state.status, LayoutSelectionStatus.previewing);
    expect(manager.state.effectiveId, LayoutProfileId.studio);
    expect(repository.layoutWriteCount, 0);

    manager.cancelPreview();
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.effectiveId, LayoutProfileId.workbench);
    expect(repository.layoutWriteCount, 0);
    manager.dispose();
  });

  test('confirm persists before promoting the committed profile', () async {
    final repository = FakePreferencesRepository(preferences: preferences());
    final manager = createManager(repository);
    await manager.initialize();
    manager.beginPreview(LayoutProfileId.studio);
    repository.layoutWriteGate = Completer<void>();

    final confirmation = manager.confirmPreview();
    await repository.layoutWriteStarted.future;
    expect(manager.state.status, LayoutSelectionStatus.committing);
    expect(manager.state.committedId, LayoutProfileId.workbench);
    expect(repository.preferences.layoutProfileId, LayoutProfileId.workbench);

    repository.layoutWriteGate!.complete();
    expect(await confirmation, isTrue);
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.committedId, LayoutProfileId.studio);
    expect(repository.preferences.layoutProfileId, LayoutProfileId.studio);
    manager.dispose();
  });

  test('save failure rolls back and exposes only a safe code', () async {
    final repository = FakePreferencesRepository(preferences: preferences());
    final manager = createManager(repository);
    await manager.initialize();
    manager.beginPreview(LayoutProfileId.studio);
    repository.failNextLayoutWrite = true;

    expect(await manager.confirmPreview(), isFalse);
    expect(manager.state.status, LayoutSelectionStatus.error);
    expect(manager.state.committedId, LayoutProfileId.workbench);
    expect(manager.state.effectiveId, LayoutProfileId.workbench);
    expect(manager.state.errorCode, LayoutSelectionErrorCode.persistenceFailed);
    manager.dispose();
  });

  test('reset uses the same commit path and preserves other fields', () async {
    final repository = FakePreferencesRepository(
      preferences: preferences(
        layout: LayoutProfileId.studio,
        appearance: 'dark',
        locale: 'zh',
      ),
    );
    final manager = createManager(repository);
    await manager.initialize();

    expect(await manager.resetLayout(), isTrue);
    expect(manager.state.committedId, LayoutProfileId.workbench);
    expect(repository.preferences.appearancePresetId, 'dark');
    expect(repository.preferences.localePreference, 'zh');
    manager.dispose();
  });

  test(
    'timeout, invalid, and unavailable previews recover deterministically',
    () async {
      final repository = FakePreferencesRepository(preferences: preferences());
      final manager = createManager(
        repository,
        previewTimeout: const Duration(milliseconds: 10),
      );
      await manager.initialize();

      manager.beginPreview(LayoutProfileId.studio);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.effectiveId, LayoutProfileId.workbench);
      expect(repository.layoutWriteCount, 0);

      expect(manager.beginPreviewId('layout-2'), isFalse);
      expect(manager.state.errorCode, LayoutSelectionErrorCode.invalidProfile);
      expect(manager.beginPreview(LayoutProfileId.parse('focus')), isFalse);
      expect(
        manager.state.errorCode,
        LayoutSelectionErrorCode.unavailableProfile,
      );
      manager.dispose();
    },
  );

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
      expect(failedManager.state.status, LayoutSelectionStatus.error);
      expect(
        failedManager.state.errorCode,
        LayoutSelectionErrorCode.persistenceFailed,
      );
      failedManager.dispose();
    },
  );

  test('newer initialization suppresses stale commit promotion', () async {
    final repository = FakePreferencesRepository(preferences: preferences());
    final manager = createManager(repository);
    await manager.initialize();
    manager.beginPreview(LayoutProfileId.studio);
    repository.layoutWriteGate = Completer<void>();

    final oldConfirmation = manager.confirmPreview();
    await repository.layoutWriteStarted.future;
    final newerInitialization = manager.initialize();
    repository.layoutWriteGate!.complete();

    expect(await oldConfirmation, isFalse);
    await newerInitialization;
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.committedId, LayoutProfileId.studio);
    expect(manager.state.operationEpoch, greaterThan(1));
    manager.dispose();
  });

  test('resize updates only the surface-local variant state', () async {
    final repository = FakePreferencesRepository(
      preferences: preferences(layout: LayoutProfileId.studio),
    );
    final manager = createManager(repository);
    await manager.initialize();

    manager.updateEnvironment(desktopEnvironment(width: 1400));
    expect(manager.state.committedId, LayoutProfileId.studio);
    expect(manager.state.viewport, LayoutViewportClass.expanded);
    expect(repository.layoutWriteCount, 0);
    manager.dispose();
  });
}

LayoutManager createManager(
  PresentationPreferencesRepository repository, {
  Duration previewTimeout = const Duration(seconds: 12),
}) => LayoutManager(
  catalog: fixtureLayoutCatalog(),
  preferencesRepository: repository,
  initialEnvironment: desktopEnvironment(width: 800),
  previewTimeout: previewTimeout,
);

PresentationPreferences preferences({
  LayoutProfileId layout = LayoutProfileId.workbench,
  String appearance = 'default-system',
  String locale = 'system',
}) => PresentationPreferences(
  layoutProfileId: layout,
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
  int layoutWriteCount = 0;
  Completer<void>? layoutWriteGate;
  Completer<void> layoutWriteStarted = Completer<void>();
  Future<void> _tail = Future<void>.value();

  @override
  Future<PresentationPreferencesLoadResult> load() => _enqueue(() async {
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
