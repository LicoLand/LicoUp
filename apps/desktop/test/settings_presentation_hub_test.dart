import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/composition/features/settings/settings_feature_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/settings/settings_inputs.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'layout/layout_host_test_fixtures.dart';

void main() {
  test('a theme switch publishes only the appearance region', () async {
    final runtime = buildFixtureLayoutRuntime();
    final preferences = _HubPreferencesRepository();
    final controller = ClientController(
      agentService: FakeAgentService(),
      layoutCatalog: runtime.catalog,
      layoutManager: LayoutManager(
        catalog: runtime.catalog,
        preferencesRepository: preferences,
        canonicalFallback: preferences.value,
      ),
    );
    await controller.layoutManager.initialize();
    final feature = SettingsFeatureComposition(controller: controller);
    final container = ProviderContainer(overrides: feature.providerOverrides);
    addTearDown(() async {
      container.dispose();
      await feature.dispose();
      controller.dispose();
    });

    final general = container.read(settingsGeneralSourceProvider);
    final appearance = container.read(settingsAppearanceSourceProvider);
    final layout = container.read(settingsLayoutSourceProvider);
    final generalObservation = await general.open();
    final appearanceObservation = await appearance.open();
    final layoutObservation = await layout.open();
    final generalChanges = <SourceChange<SettingsGeneralInputs>>[];
    final appearanceChanges = <SourceChange<SettingsAppearanceInputs>>[];
    final layoutChanges = <SourceChange<SettingsLayoutInputs>>[];
    final delivered = Completer<void>();
    final subscriptions = [
      generalObservation.changes.listen(generalChanges.add),
      appearanceObservation.changes.listen((change) {
        appearanceChanges.add(change);
        if (!delivered.isCompleted) delivered.complete();
      }),
      layoutObservation.changes.listen(layoutChanges.add),
    ];
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });

    feature.binding.intents.send(
      const SetAppearancePreference(AppearancePresetIds.licoSodaLight),
    );
    await delivered.future;

    expect(appearanceChanges, hasLength(1));
    expect(
      appearanceChanges.single.snapshot.value.appearancePresetId,
      AppearancePresetIds.licoSodaLight,
    );
    expect(
      appearanceChanges.single.base,
      appearanceObservation.initial.position,
      reason: 'the first change must be base-matched to the initial snapshot',
    );
    // The theme switch never touches the general or layout region chains.
    expect(generalChanges, isEmpty);
    expect(layoutChanges, isEmpty);
  });

  test(
    'disposing the feature while regions are observed completes cleanly',
    () async {
      final runtime = buildFixtureLayoutRuntime();
      final preferences = _HubPreferencesRepository();
      final controller = ClientController(
        agentService: FakeAgentService(),
        layoutCatalog: runtime.catalog,
        layoutManager: LayoutManager(
          catalog: runtime.catalog,
          preferencesRepository: preferences,
          canonicalFallback: preferences.value,
        ),
      );
      await controller.layoutManager.initialize();
      final feature = SettingsFeatureComposition(controller: controller);
      final container = ProviderContainer(overrides: feature.providerOverrides);

      // Open several regions and keep them open across disposal: closing a
      // region fires its cancellation, which must not mutate the hub's observed
      // set while disposal iterates it.
      await container.read(settingsGeneralSourceProvider).open();
      await container.read(settingsAppearanceSourceProvider).open();
      await container.read(settingsLayoutSourceProvider).open();

      await feature.dispose();
      container.dispose();
      controller.dispose();
    },
  );
}

final class _HubPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences value = PresentationPreferences(
    layoutProfileId: LayoutProfileId.parse('dashboard'),
    appearancePresetId: AppearancePresetIds.defaultSystem,
    localePreference: LocalePreference.system,
  );

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: value);

  @override
  Future<PresentationPreferences> setReduceMotion(bool enabled) async =>
      value = value.copyWith(reduceMotion: enabled);

  @override
  Future<PresentationPreferences> setLoadingEffect(String id) async =>
      value = value.copyWith(loadingEffectId: id);

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
