import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/appearance_preference_owner.dart';
import 'package:licoup/src/application/controller/functional_status_runtime.dart';
import 'package:licoup/src/application/controller/locale_preference_owner.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/projections/application_projection_source.dart';
import 'package:licoup/src/projections/environment/environment_projection_source.dart';
import 'package:licoup/src/projections/shell/shell_projection_producer.dart';

import '../layout/layout_host_test_fixtures.dart';

void main() {
  test(
    '§42 counts owner emissions separately from production resolvers',
    () async {
      final appearanceOwner = AppearancePreferenceOwner();
      final localeOwner = LocalePreferenceOwner();
      final statusRuntime = FunctionalStatusRuntime();
      final conversationOwner = _ConversationOwner();
      final navigation = ClientNavigationController(
        isMobileRuntime: () => false,
      );
      final layoutRuntime = buildFixtureLayoutRuntime();
      final layoutManager = LayoutManager(
        catalog: layoutRuntime.catalog,
        preferencesRepository: _MemoryPreferencesRepository(),
        canonicalFallback: _preferences(),
      );
      await layoutManager.initialize();

      final resolverCalls = [0, 0, 0, 0];
      final environmentSource = EnvironmentProjectionSource(
        EnvironmentState(
          environment: _environment(800),
          runtimeSurface: LayoutRuntimeSurface.desktop,
        ),
        resolver: (state) {
          resolverCalls[3] += 1;
          return resolveEnvironmentProjection(state);
        },
      );
      final shell = ShellProjectionProducer(
        appearance: appearanceOwner,
        locale: localeOwner,
        status: statusRuntime,
        navigation: navigation,
        layoutManager: layoutManager,
        environment: environmentSource,
        appearanceResolver: (owner) {
          resolverCalls[2] += 1;
          return resolveAppearanceProjection(owner);
        },
        localeResolver: (owner) {
          resolverCalls[3] += 1;
          return resolveLocaleProjection(owner);
        },
        layoutResolver: (manager, environment) {
          resolverCalls[1] += 1;
          return resolveLayoutProjection(manager, environment);
        },
        statusResolver: (runtime) {
          resolverCalls[0] += 1;
          return resolveStatusProjection(runtime);
        },
      );
      final conversation = ApplicationProjectionSource<int>(
        changes: conversationOwner.changes,
        read: () {
          resolverCalls[0] += 1;
          return conversationOwner.revision;
        },
      );

      final projectionEmissions = [0, 0, 0, 0];
      final ownerEmissions = [0, 0, 0, 0];
      final subscriptions = <StreamSubscription<Object?>>[
        shell.status.changes.listen((_) => projectionEmissions[0] += 1),
        conversation.changes.listen((_) => projectionEmissions[0] += 1),
        shell.layout.changes.listen((_) => projectionEmissions[1] += 1),
        shell.appearance.changes.listen((_) => projectionEmissions[2] += 1),
        environmentSource.changes.listen((_) => projectionEmissions[3] += 1),
        shell.locale.changes.listen((_) => projectionEmissions[3] += 1),
        statusRuntime.changes.listen((_) => ownerEmissions[0] += 1),
        conversationOwner.changes.listen((_) => ownerEmissions[0] += 1),
        layoutManager.selectionChanges.listen((_) => ownerEmissions[1] += 1),
        appearanceOwner.changes.listen((_) => ownerEmissions[2] += 1),
        environmentSource.changes.listen((_) => ownerEmissions[3] += 1),
        localeOwner.changes.listen((_) => ownerEmissions[3] += 1),
      ];

      void reset() {
        projectionEmissions.fillRange(0, 4, 0);
        ownerEmissions.fillRange(0, 4, 0);
        resolverCalls.fillRange(0, 4, 0);
      }

      Future<void> expectMutation(
        List<int> expected,
        FutureOr<void> Function() mutation, {
        List<int>? ownerExpected,
      }) async {
        reset();
        await mutation();
        expect(
          ownerEmissions,
          ownerExpected ?? expected,
          reason: 'causal owner publish matrix',
        );
        expect(
          projectionEmissions,
          expected,
          reason: 'projection emission matrix',
        );
        expect(resolverCalls, expected, reason: 'resolver invocation matrix');
      }

      await expectMutation(
        const [0, 0, 1, 0],
        () => appearanceOwner.replacePreset(AppearancePresetIds.licoSodaLight),
      );
      await expectMutation(const [
        0,
        0,
        1,
        0,
      ], () => appearanceOwner.replaceFontPreference('synthetic-readable'));
      await expectMutation(const [0, 1, 0, 1], () {
        environmentSource.replace(
          EnvironmentState(
            environment: _environment(1400),
            runtimeSurface: LayoutRuntimeSurface.desktop,
          ),
        );
      }, ownerExpected: const [0, 0, 0, 1]);
      await expectMutation(const [1, 0, 0, 0], conversationOwner.message);
      await expectMutation(const [
        0,
        1,
        0,
        0,
      ], () => layoutManager.selectLayout(LayoutProfileId.parse('atlas')));
      await expectMutation(const [
        1,
        0,
        0,
        0,
      ], () => statusRuntime.replaceMessage('Agent ready'));

      reset();
      localeOwner.replace(LocalePreference.chinese);
      expect(ownerEmissions, const [0, 0, 0, 1]);
      expect(projectionEmissions, const [0, 0, 0, 1]);
      expect(resolverCalls, const [0, 0, 0, 1]);

      for (final subscription in subscriptions.reversed) {
        await subscription.cancel();
      }
      await conversation.dispose();
      await shell.dispose();
      await environmentSource.dispose();
      layoutManager.dispose();
      navigation.dispose();
      conversationOwner.dispose();
      statusRuntime.dispose();
      localeOwner.dispose();
      appearanceOwner.dispose();
    },
  );
}

final class _ConversationOwner extends ApplicationStateOwner {
  int revision = 0;

  void message() {
    revision += 1;
    publishChange();
  }
}

LayoutEnvironment _environment(double width) =>
    LayoutEnvironment.fromConstraints(
      surface: LayoutRuntimeSurface.desktop,
      width: width,
      height: 800,
      textScale: 1,
      hasPointer: true,
      hasKeyboard: true,
    );

PresentationPreferences _preferences() => PresentationPreferences(
  layoutProfileId: LayoutProfileId.parse('dashboard'),
  appearancePresetId: AppearancePresetIds.defaultSystem,
  localePreference: LocalePreference.system,
);

final class _MemoryPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences value = _preferences();

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
