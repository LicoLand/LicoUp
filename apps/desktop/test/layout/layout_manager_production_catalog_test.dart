import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/platform/presentation/file_presentation_preferences_repository.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

void main() {
  late Directory temporaryRoot;

  setUp(() async {
    temporaryRoot = await Directory.systemTemp.createTemp(
      'layout-manager-prod-catalog-',
    );
  });

  tearDown(() async {
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  test(
    'production wiring: a fresh data root starts on the dashboard layout',
    () async {
      final catalog = BuiltInLayoutComposition().catalog;
      // Mirror client_controller.dart exactly: the catalog owns the default.
      final fallback = PresentationPreferences(
        layoutProfileId: catalog.defaultProfile.id,
        appearancePresetId: 'default-system',
        localePreference: 'system',
      );
      final manager = LayoutManager(
        catalog: catalog,
        preferencesRepository: FilePresentationPreferencesRepository(
          portableData: PortableDataRoot(dataDirectoryOverride: temporaryRoot),
          fallback: fallback,
        ),
        canonicalFallback: fallback,
      );

      await manager.initialize();
      expect(catalog.defaultProfile.id, LayoutProfileId.parse('dashboard'));
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));
      manager.dispose();
    },
  );

  test(
    'production wiring: a stored dashboard layout is kept and switches to desktop and back',
    () async {
      final composition = BuiltInLayoutComposition();
      final catalog = composition.catalog;
      expect(
        catalog.containsProfile(LayoutProfileId.parse('desktop')),
        isTrue,
        reason: 'desktop profile must be registered in the built-in catalog',
      );

      final fallback = PresentationPreferences(
        layoutProfileId: catalog.defaultProfile.id,
        appearancePresetId: 'default-system',
        localePreference: 'system',
      );
      final repository = FilePresentationPreferencesRepository(
        portableData: PortableDataRoot(dataDirectoryOverride: temporaryRoot),
        fallback: fallback,
      );
      // Seed the user's real on-disk state: dashboard persisted.
      await repository.setLayoutProfile(LayoutProfileId.parse('dashboard'));

      final manager = LayoutManager(
        catalog: catalog,
        preferencesRepository: repository,
        canonicalFallback: fallback,
      );
      final transitions = <LayoutSelectionStatus>[];
      manager.changes.listen((_) => transitions.add(manager.state.status));

      await manager.initialize();
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));

      expect(
        await manager.selectLayout(LayoutProfileId.parse('desktop')),
        isTrue,
        reason: 'first switch must commit, got ${manager.state}',
      );
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('desktop'));

      expect(
        await manager.selectLayout(LayoutProfileId.parse('dashboard')),
        isTrue,
        reason: 'switching back must commit, got ${manager.state}',
      );
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));

      final loaded = await repository.load();
      expect(
        loaded.preferences.layoutProfileId,
        LayoutProfileId.parse('dashboard'),
      );
      manager.dispose();
    },
  );
}
