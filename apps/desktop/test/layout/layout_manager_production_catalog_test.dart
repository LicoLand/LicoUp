import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/composition/built_in_layout_composition.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
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
    'production wiring: messaging default switches to dashboard and back',
    () async {
      final composition = BuiltInLayoutComposition();
      final catalog = composition.catalog;
      // Mirror client_presentation_component_assembly.dart exactly.
      final preferredLayout = LayoutProfileDefaults.preferredForPlatform(
        defaultTargetPlatform,
      );
      expect(preferredLayout, LayoutProfileId.parse('messaging'));
      expect(
        catalog.containsProfile(LayoutProfileId.parse('dashboard')),
        isTrue,
        reason: 'dashboard profile must be registered in the built-in catalog',
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
      // Seed the user's real on-disk state: messaging persisted.
      await repository.setLayoutProfile(LayoutProfileId.parse('messaging'));

      final manager = LayoutManager(
        catalog: catalog,
        preferencesRepository: repository,
        canonicalFallback: fallback,
        preferredDefaultId: preferredLayout,
        initialEnvironment: LayoutEnvironment.fromConstraints(
          surface: LayoutRuntimeSurface.desktop,
          width: 1280,
          height: 800,
          textScale: 1,
          hasPointer: true,
          hasKeyboard: true,
        ),
      );
      final transitions = <LayoutSelectionStatus>[];
      manager.addListener((state) => transitions.add(state.status));

      await manager.initialize();
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('messaging'));

      expect(
        await manager.selectLayout(LayoutProfileId.parse('dashboard')),
        isTrue,
        reason: 'first switch must commit, got ${manager.state}',
      );
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('dashboard'));

      expect(
        await manager.selectLayout(LayoutProfileId.parse('messaging')),
        isTrue,
        reason: 'switching back must commit, got ${manager.state}',
      );
      expect(manager.state.status, LayoutSelectionStatus.stable);
      expect(manager.state.committedId, LayoutProfileId.parse('messaging'));

      final loaded = await repository.load();
      expect(
        loaded.preferences.layoutProfileId,
        LayoutProfileId.parse('messaging'),
      );
      manager.dispose();
    },
  );
}
