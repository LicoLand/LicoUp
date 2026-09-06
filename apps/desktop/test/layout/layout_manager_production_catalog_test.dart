import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/platform/presentation/presentation_preferences_repository.dart';
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
    'production wiring: dashboard default switches to desktop and back',
    () async {
      final composition = BuiltInLayoutComposition();
      final catalog = composition.catalog;
      // Mirror client_controller.dart exactly.
      final preferredLayout = LayoutProfileId.parse('dashboard');
      expect(preferredLayout, LayoutProfileId.parse('dashboard'));
      expect(
        catalog.containsProfile(LayoutProfileId.parse('desktop')),
        isTrue,
        reason: 'desktop profile must be registered in the built-in catalog',
      );
      expect(catalog.containsProfile(preferredLayout), isTrue);

      final fallback = PresentationPreferences(
        layoutProfileId: preferredLayout,
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
        preferredDefaultId: preferredLayout,
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
