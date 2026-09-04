import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_shell_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/projections/shell/shell_projection_producer.dart';

import '../layout/layout_host_test_fixtures.dart';

void main() {
  test('shell state planes publish independently', () async {
    final shell = ClientShellController();
    final navigation = ClientNavigationController(isMobileRuntime: () => true);
    final runtime = buildFixtureLayoutRuntime();
    final manager = LayoutManager(
      catalog: runtime.catalog,
      preferencesRepository: _MemoryPreferencesRepository(),
      canonicalFallback: _preferences(),
      initialEnvironment: _environment(width: 390),
    );
    final producer = ShellProjectionProducer(
      shell: shell,
      navigation: navigation,
      layoutManager: manager,
      readRuntimeSurface: () => LayoutRuntimeSurface.mobile,
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

    shell.replaceStatusMessage('Focused status');
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [0, 0, 0, 0, 0, 1],
    );

    shell.replaceLocalePreference(LocalePreference.chinese);
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [0, 1, 0, 0, 0, 2],
    );

    shell.replaceAppearancePreset(AppearancePresetIds.licoSodaLight);
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [1, 1, 0, 0, 0, 2],
    );

    navigation.select(ClientSection.settings);
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [1, 1, 0, 0, 1, 2],
    );

    manager.updateEnvironment(
      _environment(width: 420),
      cause: const ApplicationCause(traceId: 'environment-trace'),
    );
    expect(
      _counts(appearance, locale, layout, environment, destinations, status),
      [1, 1, 0, 1, 1, 2],
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
    manager.dispose();
    navigation.dispose();
    shell.dispose();
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
