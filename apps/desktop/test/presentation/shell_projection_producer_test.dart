import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/appearance_preference_owner.dart';
import 'package:licoup/src/application/controller/functional_status_runtime.dart';
import 'package:licoup/src/application/controller/locale_preference_owner.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/projections/shell/shell_projection_producer.dart';
import 'package:licoup/src/projections/environment/environment_projection_source.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';

import '../layout/layout_host_test_fixtures.dart';

void main() {
  test('shell state planes publish independently', () async {
    final appearanceOwner = AppearancePreferenceOwner();
    final localeOwner = LocalePreferenceOwner();
    final statusRuntime = FunctionalStatusRuntime();
    final navigation = ClientNavigationController(isMobileRuntime: () => true);
    final runtime = buildFixtureLayoutRuntime();
    final manager = LayoutManager(
      catalog: runtime.catalog,
      preferencesRepository: _MemoryPreferencesRepository(),
      canonicalFallback: _preferences(),
    );
    final environmentSource = EnvironmentProjectionSource(
      EnvironmentState(
        environment: _environment(width: 390),
        runtimeSurface: LayoutRuntimeSurface.mobile,
      ),
    );
    final producer = ShellProjectionProducer(
      appearance: appearanceOwner,
      locale: localeOwner,
      status: statusRuntime,
      navigation: navigation,
      layoutManager: manager,
      environment: environmentSource,
    );
    final appearance = <ProjectionUpdate<Object?>>[];
    final locale = <ProjectionUpdate<Object?>>[];
    final layout = <ProjectionUpdate<Object?>>[];
    final environment = <ProjectionUpdate<Object?>>[];
    final destinations = <ProjectionUpdate<Object?>>[];
    final status = <ProjectionUpdate<Object?>>[];
    final subscriptions = [
      producer.appearance.changes.listen(appearance.add),
      producer.locale.changes.listen(locale.add),
      producer.layout.changes.listen(layout.add),
      producer.environment.changes.listen(environment.add),
      producer.navigation.changes.listen(destinations.add),
      producer.status.changes.listen(status.add),
    ];

    expect(producer.navigation.current.destinations, const [
      ClientSection.agents,
      ClientSection.mobileRelay,
      ClientSection.settings,
    ]);
    expect(
      producer.environment.current.runtimeSurface,
      LayoutRuntimeSurface.mobile,
    );

    statusRuntime.replaceMessage('Focused status');
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [0, 0, 0, 0, 0, 1],
    );

    localeOwner.replace(LocalePreference.chinese);
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [0, 1, 0, 0, 0, 1],
    );

    appearanceOwner.replacePreset(AppearancePresetIds.licoSodaLight);
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [1, 1, 0, 0, 0, 1],
    );

    navigation.select(ClientSection.settings);
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [1, 1, 0, 0, 1, 1],
    );

    environmentSource.replace(
      EnvironmentState(
        environment: _environment(width: 900),
        runtimeSurface: LayoutRuntimeSurface.mobile,
      ),
      trace: const TraceContext(traceId: 'environment-trace'),
    );
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [1, 1, 1, 1, 1, 1],
    );
    expect(
      environment.single.trace,
      const TraceContext(traceId: 'environment-trace'),
    );

    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await producer.dispose();
    await producer.dispose();
    await environmentSource.dispose();
    manager.dispose();
    navigation.dispose();
    statusRuntime.dispose();
    localeOwner.dispose();
    appearanceOwner.dispose();
  });
}

List<int> _counts(
  List<Object?> appearance,
  List<Object?> locale,
  List<Object?> layout,
  List<Object?> environment,
  List<Object?> navigation,
  List<Object?> status,
) => [
  appearance.length,
  locale.length,
  layout.length,
  environment.length,
  navigation.length,
  status.length,
];

LayoutEnvironment _environment({required double width}) =>
    LayoutEnvironment.fromConstraints(
      surface: LayoutRuntimeSurface.mobile,
      width: width,
      height: 844,
      textScale: 1,
      hasTouch: true,
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
