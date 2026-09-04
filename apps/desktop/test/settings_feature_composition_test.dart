import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/composition/features/settings/settings_feature_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'layout/layout_host_test_fixtures.dart';

void main() {
  test(
    'semantic preference intents update Application and projection',
    () async {
      final runtime = buildFixtureLayoutRuntime();
      final preferences = _SettingsPreferencesRepository();
      final layoutManager = LayoutManager(
        catalog: runtime.catalog,
        preferencesRepository: preferences,
        canonicalFallback: preferences.value,
        initialEnvironment: LayoutEnvironment.fromConstraints(
          surface: LayoutRuntimeSurface.desktop,
          width: 900,
          height: 800,
          textScale: 1,
          hasPointer: true,
          hasKeyboard: true,
        ),
      );
      final controller = ClientController(
        agentService: FakeAgentService(),
        layoutCatalog: runtime.catalog,
        layoutManager: layoutManager,
      );
      await controller.layoutManager.initialize();
      final feature = SettingsFeatureComposition(controller: controller);
      addTearDown(() async {
        await feature.dispose();
        controller.dispose();
      });

      final localeUpdate = feature.binding.projection.changes.first;
      feature.binding.intents.send(
        const SetLocalePreference(LocalePreference.chinese),
      );
      await localeUpdate;
      expect(controller.localePreference, LocalePreference.chinese);
      expect(preferences.value.localePreference, LocalePreference.chinese);
      expect(
        feature.binding.projection.current.localeChoices
            .singleWhere((choice) => choice.id == LocalePreference.chinese)
            .selected,
        isTrue,
      );

      final appearanceUpdate = feature.binding.projection.changes.first;
      feature.binding.intents.send(
        const SetAppearancePreference(AppearancePresetIds.licoSodaLight),
      );
      await appearanceUpdate;
      expect(controller.appearancePresetId, AppearancePresetIds.licoSodaLight);
      expect(
        preferences.value.appearancePresetId,
        AppearancePresetIds.licoSodaLight,
      );

      await feature.dispose();
      await feature.dispose();
    },
  );
}

final class _SettingsPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences value = PresentationPreferences(
    layoutProfileId: LayoutProfileId.parse('dashboard'),
    appearancePresetId: AppearancePresetIds.licoSodaLight,
    localePreference: LocalePreference.system,
  );

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: value);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      value = value.copyWith(appearancePresetId: id);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      value = value.copyWith(layoutProfileId: id);

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => value = value.copyWith(localePreference: preference);
}
