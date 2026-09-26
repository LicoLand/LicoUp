import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/composition/features/settings/settings_feature_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_resources.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/models/models_resources.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_inputs.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';
import 'package:licoup/src/projections/agent_hub/agent_hub_presentation_source.dart';
import 'package:licoup/src/projections/models/models_presentation_source.dart';
import 'package:licoup/src/projections/settings/settings_presentation_sources.dart';

import '../fixtures/client_controller/support/fake_agent_service.dart';
import '../layout/layout_host_test_fixtures.dart';

/// A13 @contract for the V7-F6 feature sources.
///
/// The prepared runtime is exercised through the real feature adapters and the
/// production settings composition: independent consistency groups keep
/// progressing without waiting for each other, and revocation invalidates the
/// old lineage immediately - a late update never resurrects it, while an
/// explicit fresh read is admitted normally.
void main() {
  test('settings regions advance in independent consistency groups', () async {
    final harness = await _SettingsHarness.create();
    addTearDown(harness.dispose);
    final runtime = harness.container.read(presentationRuntimeProvider);
    final appearanceSource = harness.container.read(
      settingsAppearanceSourceProvider,
    );
    final generalSource = harness.container.read(settingsGeneralSourceProvider);
    final appearance = runtime.observe(appearanceSource);
    final general = runtime.observe(generalSource);
    final appearanceSnapshots = <ResourceSnapshot<SettingsAppearanceInputs>>[];
    final generalSnapshots = <ResourceSnapshot<SettingsGeneralInputs>>[];
    final subscriptions = <StreamSubscription<Object?>>[
      appearance.stream.listen(appearanceSnapshots.add),
      general.stream.listen(generalSnapshots.add),
    ];
    addTearDown(() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });
    await pumpEventQueue();
    expect(appearanceSnapshots, hasLength(1));
    expect(generalSnapshots, hasLength(1));
    final generalPosition = generalSnapshots.single.position;

    harness.feature.binding.intents.send(
      const SetAppearancePreference(AppearancePresetIds.licoSodaLight),
    );
    await _until(() => appearanceSnapshots.length == 2);

    expect(appearanceSnapshots, hasLength(2));
    expect(
      generalSnapshots,
      hasLength(1),
      reason: 'an appearance change must not refresh an unrelated group',
    );
    expect(
      runtime
          .current(SettingsPresentationHub.settingsGeneralRegion.fieldGroup)
          ?.position,
      generalPosition,
    );
    expect(
      appearanceSnapshots.last.consistencyGroup,
      isNot(generalSnapshots.single.consistencyGroup),
    );
    expect(
      appearanceSnapshots.last.value.appearancePresetId,
      AppearancePresetIds.licoSodaLight,
    );

    harness.feature.binding.intents.send(
      const SetLocalePreference(LocalePreference.chinese),
    );
    await _until(() => generalSnapshots.length == 2);

    expect(
      appearanceSnapshots,
      hasLength(2),
      reason: 'a locale change must not refresh the appearance group',
    );
    expect(
      runtime
          .current(SettingsPresentationHub.settingsAppearanceRegion.fieldGroup)
          ?.value
          .appearancePresetId,
      AppearancePresetIds.licoSodaLight,
    );
  });

  test(
    'revoking one settings region invalidates it without waiting for a group '
    'and refuses the late lineage',
    () async {
      final harness = await _SettingsHarness.create();
      addTearDown(harness.dispose);
      final runtime = harness.container.read(presentationRuntimeProvider);
      final appearanceSource = harness.container.read(
        settingsAppearanceSourceProvider,
      );
      final fieldGroup =
          SettingsPresentationHub.settingsAppearanceRegion.fieldGroup;
      final observation = runtime.observe(appearanceSource);
      // The lease is the application scope that can read the resource again
      // after authority was withdrawn.
      final lease = runtime.own(appearanceSource);
      addTearDown(lease.release);
      final snapshots = <ResourceSnapshot<SettingsAppearanceInputs>>[];
      final errors = <Object>[];
      final subscription = observation.stream.listen(
        snapshots.add,
        onError: errors.add,
      );
      addTearDown(subscription.cancel);
      await pumpEventQueue();
      expect(runtime.current(fieldGroup), isNotNull);
      expect(snapshots, hasLength(1));

      runtime.revoke(fieldGroup.resource);
      await pumpEventQueue();

      expect(runtime.current(fieldGroup), isNull);
      expect(
        errors,
        isNotEmpty,
        reason: 'a withdrawn value must be reported, not kept visible',
      );
      final visibleBefore = snapshots.length;

      harness.feature.binding.intents.send(
        const SetAppearancePreference(AppearancePresetIds.licoSodaLight),
      );
      await _until(
        () =>
            harness.controller.appearancePresetId ==
            AppearancePresetIds.licoSodaLight,
      );
      await pumpEventQueue();

      expect(
        runtime.current(fieldGroup),
        isNull,
        reason: 'an update based on the revoked position must be refused',
      );
      expect(snapshots, hasLength(visibleBefore));

      await lease.reconnect();
      await _until(() => snapshots.length > visibleBefore);

      expect(runtime.current(fieldGroup), isNotNull);
      expect(
        runtime.current(fieldGroup)?.value.appearancePresetId,
        AppearancePresetIds.licoSodaLight,
      );
      expect(snapshots.last.value.appearancePresetId, isNotNull);
    },
  );

  test(
    'a settings value prepared before revocation can never install',
    () async {
      final harness = await _SettingsHarness.create();
      addTearDown(harness.dispose);
      final runtime = harness.container.read(presentationRuntimeProvider);
      final source = harness.container.read(settingsAppearanceSourceProvider);
      // The container owns the observation; disposing the harness runtime
      // closes it, so nothing here waits on a stream nobody listened to.
      runtime.observe(source);
      await pumpEventQueue();
      final fieldGroup =
          SettingsPresentationHub.settingsAppearanceRegion.fieldGroup;
      final snapshot = runtime.current(fieldGroup);
      expect(snapshot, isNotNull);

      final display = runtime.preparedDisplay<SettingsAppearanceInputs>();
      final outcome = await display.prepareAndOffer(
        snapshot: snapshot!,
        generation: const RequestGeneration(1),
        operation: () => snapshot.value,
      );
      expect(outcome, GroupInstallOutcome.installed);
      expect(display.current(fieldGroup), isNotNull);

      // A newer value prepared from the same position, still waiting to be
      // offered when authority is withdrawn.
      final pending = await runtime.preparation
          .prepare<SettingsAppearanceInputs>(
            snapshot: snapshot,
            generation: const RequestGeneration(2),
            operation: () => snapshot.value,
          );

      runtime.revoke(fieldGroup.resource);
      await pumpEventQueue();

      expect(display.current(fieldGroup), isNull);
      expect(
        display.trackedGroups,
        0,
        reason: 'a revoked group is dropped instead of completed',
      );
      expect(
        display.offer(pending),
        GroupInstallOutcome.rejected,
        reason: 'revocation wins over a value prepared before it',
      );
      expect(display.current(fieldGroup), isNull);
      expect(runtime.current(fieldGroup), isNull);
    },
  );

  test(
    'models catalog refuses its revoked lineage until a fresh read',
    () async {
      final producer = _FakeModelsSource(_modelsProjection());
      final source = ModelsPresentationSource(projection: producer);
      addTearDown(source.dispose);
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final observation = runtime.observe(source);
      final lease = runtime.own(source);
      addTearDown(lease.release);
      final snapshots = <ResourceSnapshot<ModelsProjection>>[];
      final errors = <Object>[];
      final subscription = observation.stream.listen(
        snapshots.add,
        onError: errors.add,
      );
      addTearDown(subscription.cancel);
      await pumpEventQueue();
      expect(runtime.current(modelsCatalogFields)?.value, producer.current);

      producer.publish(_modelsProjection(phase: PresentationPhase.loading));
      await _until(
        () =>
            runtime.current(modelsCatalogFields)?.value.phase ==
            PresentationPhase.loading,
      );
      expect(snapshots.length, greaterThanOrEqualTo(2));

      runtime.revoke(modelsCatalogResource);
      await pumpEventQueue();

      expect(runtime.current(modelsCatalogFields), isNull);
      expect(errors, isNotEmpty);
      final visibleBefore = snapshots.length;

      producer.publish(
        _modelsProjection(
          phase: PresentationPhase.ready,
          gatewayStateLabel: 'fresh-read',
        ),
      );
      await pumpEventQueue();

      expect(
        runtime.current(modelsCatalogFields),
        isNull,
        reason: 'the revoked epoch lineage cannot come back through an update',
      );
      expect(snapshots, hasLength(visibleBefore));

      await lease.reconnect();
      await _until(() => snapshots.length > visibleBefore);

      expect(runtime.current(modelsCatalogFields), isNotNull);
      expect(
        runtime.current(modelsCatalogFields)?.value.gatewayStateLabel,
        'fresh-read',
        reason: 'a fresh read admits the value the source holds now',
      );
    },
  );

  test(
    'agent hub catalog refuses its revoked lineage until a fresh read',
    () async {
      final producer = _FakeAgentHubSource(_agentHubProjection());
      final source = AgentHubPresentationSource(projection: producer);
      addTearDown(source.dispose);
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final observation = runtime.observe(source);
      final lease = runtime.own(source);
      addTearDown(lease.release);
      final snapshots = <ResourceSnapshot<AgentHubProjection>>[];
      final errors = <Object>[];
      final subscription = observation.stream.listen(
        snapshots.add,
        onError: errors.add,
      );
      addTearDown(subscription.cancel);
      await pumpEventQueue();
      expect(runtime.current(agentHubCatalogFields)?.value, producer.current);

      producer.publish(_agentHubProjection(phase: PresentationPhase.loading));
      await _until(
        () =>
            runtime.current(agentHubCatalogFields)?.value.phase ==
            PresentationPhase.loading,
      );

      runtime.revoke(agentHubCatalogResource);
      await pumpEventQueue();

      expect(runtime.current(agentHubCatalogFields), isNull);
      expect(errors, isNotEmpty);
      final visibleBefore = snapshots.length;
      producer.publish(_agentHubProjection(phase: PresentationPhase.ready));
      await pumpEventQueue();
      expect(runtime.current(agentHubCatalogFields), isNull);
      expect(snapshots, hasLength(visibleBefore));

      await lease.reconnect();
      await _until(() => snapshots.length > visibleBefore);
      expect(
        runtime.current(agentHubCatalogFields)?.value.phase,
        PresentationPhase.ready,
      );
    },
  );
}

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 64 && !condition(); attempt += 1) {
    await pumpEventQueue();
  }
  expect(condition(), isTrue, reason: 'condition was not reached in time');
}

final class _SettingsHarness {
  _SettingsHarness._(
    this.controller,
    this.feature,
    this.container,
    this.preferences,
  );

  static Future<_SettingsHarness> create() async {
    final layoutRuntime = buildFixtureLayoutRuntime();
    final preferences = _HarnessPreferencesRepository();
    final controller = ClientController(
      agentService: FakeAgentService(),
      layoutCatalog: layoutRuntime.catalog,
      layoutManager: LayoutManager(
        catalog: layoutRuntime.catalog,
        preferencesRepository: preferences,
        canonicalFallback: preferences.value,
      ),
    );
    await controller.layoutManager.initialize();
    final feature = SettingsFeatureComposition(controller: controller);
    final container = ProviderContainer(overrides: feature.providerOverrides);
    return _SettingsHarness._(controller, feature, container, preferences);
  }

  final ClientController controller;
  final SettingsFeatureComposition feature;
  final ProviderContainer container;
  final _HarnessPreferencesRepository preferences;

  Future<void> dispose() async {
    container.dispose();
    await feature.dispose();
    controller.dispose();
  }
}

final class _HarnessPreferencesRepository
    implements PresentationPreferencesRepository {
  int appearanceWrites = 0;
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
  Future<PresentationPreferences> setAppearancePreset(String id) async {
    appearanceWrites += 1;
    return value = value.copyWith(appearancePresetId: id);
  }

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      value = value.copyWith(layoutProfileId: id);

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => value = value.copyWith(localePreference: preference);
}

ModelsProjection _modelsProjection({
  PresentationPhase phase = PresentationPhase.ready,
  String gatewayStateLabel = '',
}) => ModelsProjection(
  providers: const <ModelProviderProjection>[],
  gatewayEnabled: false,
  gatewayStateLabel: gatewayStateLabel,
  phase: phase,
);

AgentHubProjection _agentHubProjection({
  PresentationPhase phase = PresentationPhase.ready,
}) => AgentHubProjection(
  entries: const <AgentHubEntryProjection>[],
  phase: phase,
);

final class _FakeModelsSource implements ProjectionSource<ModelsProjection> {
  _FakeModelsSource(this._current);

  ModelsProjection _current;
  final StreamController<ProjectionUpdate<ModelsProjection>> _changes =
      StreamController<ProjectionUpdate<ModelsProjection>>.broadcast(
        sync: true,
      );

  @override
  ModelsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<ModelsProjection>> get changes => _changes.stream;

  void publish(ModelsProjection value) {
    _current = value;
    _changes.add(ProjectionUpdate<ModelsProjection>(value));
  }
}

final class _FakeAgentHubSource
    implements ProjectionSource<AgentHubProjection> {
  _FakeAgentHubSource(this._current);

  AgentHubProjection _current;
  final StreamController<ProjectionUpdate<AgentHubProjection>> _changes =
      StreamController<ProjectionUpdate<AgentHubProjection>>.broadcast(
        sync: true,
      );

  @override
  AgentHubProjection get current => _current;

  @override
  Stream<ProjectionUpdate<AgentHubProjection>> get changes => _changes.stream;

  void publish(AgentHubProjection value) {
    _current = value;
    _changes.add(ProjectionUpdate<AgentHubProjection>(value));
  }
}
