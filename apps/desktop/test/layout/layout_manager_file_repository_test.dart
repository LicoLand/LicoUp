import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/platform/presentation/presentation_preferences_repository.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

import 'layout_manager_test.dart' show createManager, preferences;

void main() {
  late Directory temporaryRoot;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp(
      'layout-manager-file-repo-',
    );
  });

  tearDown(() async {
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  FilePresentationPreferencesRepository fileRepository() =>
      FilePresentationPreferencesRepository(
        portableData: PortableDataRoot(dataDirectoryOverride: temporaryRoot),
        fallback: preferences(),
      );

  test(
    'switching forth and back with the file repository commits both writes',
    () async {
      final repository = fileRepository();
      final manager = createManager(repository);
      await manager.initialize();
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));

      expect(
        await manager.selectLayout(LayoutProfileId.parse('atlas')),
        isTrue,
      );
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
      expect(manager.state.effectiveId, LayoutProfileId.parse('atlas'));

      expect(
        await manager.selectLayout(LayoutProfileId.parse('dashboard')),
        isTrue,
      );
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));
      expect(manager.state.effectiveId, LayoutProfileId.parse('dashboard'));

      final loaded = await repository.load();
      expect(
        loaded.preferences.layoutProfileId,
        LayoutProfileId.parse('dashboard'),
      );
      manager.dispose();
    },
  );

  test(
    'switching forth and back after hydrating a stored non-default profile',
    () async {
      final seeded = fileRepository();
      await seeded.setLayoutProfile(LayoutProfileId.parse('atlas'));

      final repository = fileRepository();
      final manager = createManager(repository);
      await manager.initialize();
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('atlas'));

      expect(
        await manager.selectLayout(LayoutProfileId.parse('dashboard')),
        isTrue,
      );
      expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));

      expect(
        await manager.selectLayout(LayoutProfileId.parse('atlas')),
        isTrue,
      );
      expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
      manager.dispose();
    },
  );

  test(
    'an unexpected repository failure ends the commit instead of freezing',
    () async {
      final manager = createManager(_ExplodingPreferencesRepository());
      await manager.initialize();
      expect(manager.state.status, LayoutSelectionStatus.stable);

      expect(
        await manager.selectLayout(LayoutProfileId.parse('atlas')),
        isFalse,
      );
      expect(manager.state.status, LayoutSelectionStatus.error);
      expect(
        manager.state.errorCode,
        LayoutSelectionErrorCode.persistenceFailed,
      );
      // The selector must stay usable: a later selection attempt runs.
      expect(
        await manager.selectLayout(LayoutProfileId.parse('atlas')),
        isFalse,
      );
      expect(manager.state.status, LayoutSelectionStatus.error);
      manager.dispose();
    },
  );

  test(
    'a repository write that never settles times out instead of freezing',
    () async {
      final manager = createManager(
        _HangingPreferencesRepository(),
        persistenceTimeout: const Duration(milliseconds: 50),
      );
      await manager.initialize();
      expect(manager.state.status, LayoutSelectionStatus.stable);

      expect(
        await manager.selectLayout(LayoutProfileId.parse('atlas')),
        isFalse,
      );
      expect(manager.state.status, LayoutSelectionStatus.error);
      expect(
        manager.state.errorCode,
        LayoutSelectionErrorCode.persistenceFailed,
      );
      // The selector recovers: a later attempt reaches the repository again.
      expect(
        await manager.selectLayout(LayoutProfileId.parse('atlas')),
        isFalse,
      );
      manager.dispose();
    },
  );
}

final class _HangingPreferencesRepository
    implements PresentationPreferencesRepository {
  final PresentationPreferences _preferences = PresentationPreferences(
    layoutProfileId: LayoutProfileId.parse('dashboard'),
    appearancePresetId: 'default-system',
    localePreference: 'system',
  );

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: _preferences);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) =>
      Completer<PresentationPreferences>().future;

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      _preferences;

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => _preferences;
}

final class _ExplodingPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences _preferences = PresentationPreferences(
    layoutProfileId: LayoutProfileId.parse('dashboard'),
    appearancePresetId: 'default-system',
    localePreference: 'system',
  );

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: _preferences);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) =>
      Future.error(StateError('unexpected_store_failure'));

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async {
    _preferences = _preferences.copyWith(appearancePresetId: id);
    return _preferences;
  }

  @override
  Future<PresentationPreferences> setLocalePreference(String preference) async {
    _preferences = _preferences.copyWith(localePreference: preference);
    return _preferences;
  }
}
