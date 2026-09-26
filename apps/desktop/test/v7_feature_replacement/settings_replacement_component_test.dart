import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/misc.dart' show Override, ProviderListenable;

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/composition/features/settings/settings_feature_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/settings/settings_inputs.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';

import '../fixtures/client_controller/support/fake_agent_service.dart';
import '../layout/fixtures/layout_destination_presentation_fixture.dart';
import '../layout/layout_host_test_fixtures.dart';

/// A14 @component-integration for the V7-F6 settings feature.
///
/// The view is driven by the production composition overrides. Replacing the
/// theme and the renderer must not open the region sources again, must not
/// re-dispatch a business command, and must keep the installed values; one
/// user action must persist exactly one command and refresh only the region it
/// changed.
void main() {
  testWidgets('theme and renderer replacement keep reads and commands flat', (
    tester,
  ) async {
    final harness = await _SettingsHarness.create();
    addTearDown(harness.dispose);
    final counting = _CountingSources(harness);

    Widget app({required bool alternate, required Brightness brightness}) {
      return ProviderScope(
        overrides: counting.overrides,
        child: MaterialApp(
          builder: (context, child) =>
              FixtureLayoutPresentationScope(child: child!),
          locale: const Locale('en'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: brightness,
          ).copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: SizedBox(
              width: 980,
              height: 900,
              child: alternate
                  ? const _AlternateSettingsSurface()
                  : SettingsPanel(
                      binding: harness.feature.binding,
                      layoutRegistry: buildFixtureLayoutRuntime().registry,
                    ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(app(alternate: false, brightness: Brightness.dark));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('settings-appearance-dropdown')), findsOne);
    expect(counting.general.opens, 1);
    expect(counting.appearance.opens, 1);
    final opensBefore = counting.totalOpens;
    final writesBefore = harness.preferences.appearanceWrites;
    final generalEventsBefore = counting.general.events;
    final appearanceEventsBefore = counting.appearance.events;
    final installedPreset = harness.controller.appearancePresetId;

    // Replacing the theme is a visual update only.
    await tester.pumpWidget(
      app(alternate: false, brightness: Brightness.light),
    );
    await tester.pump();

    expect(counting.totalOpens, opensBefore, reason: 'theme re-read a source');
    expect(
      harness.preferences.appearanceWrites,
      writesBefore,
      reason: 'theme dispatched a business command',
    );

    // Replacing the renderer keeps the same installed region values.
    await tester.pumpWidget(app(alternate: true, brightness: Brightness.light));
    await tester.pump();

    expect(
      find.text('alt-appearance:${harness.controller.appearancePresetId}'),
      findsOne,
    );
    expect(
      counting.totalOpens,
      opensBefore,
      reason: 'renderer re-read a source',
    );
    expect(counting.general.events, generalEventsBefore);
    expect(
      harness.preferences.appearanceWrites,
      writesBefore,
      reason: 'renderer replacement dispatched a business command',
    );

    // Returning to the production view renders the value that stayed
    // installed instead of collapsing into a loading gap.
    await tester.pumpWidget(app(alternate: false, brightness: Brightness.dark));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('settings-appearance-dropdown')), findsOne);
    expect(counting.totalOpens, opensBefore);
    expect(
      harness.controller.appearancePresetId,
      installedPreset,
      reason: 'replacing the surface must not change feature state',
    );

    // One user action: exactly one persistence command, and only the
    // appearance region refreshes.
    harness.feature.binding.intents.send(
      const SetAppearancePreference(AppearancePresetIds.licoSodaLight),
    );
    await _pumpUntil(
      tester,
      () => harness.preferences.appearanceWrites == writesBefore + 1,
    );
    await tester.pump();

    expect(harness.preferences.appearanceWrites, writesBefore + 1);
    expect(
      counting.general.events,
      generalEventsBefore,
      reason: 'the locale/general region must not refresh',
    );
    expect(
      counting.appearance.events,
      appearanceEventsBefore + 1,
      reason: 'the appearance region refreshes once',
    );
    expect(counting.totalOpens, opensBefore);
    expect(
      harness.preferences.value.appearancePresetId,
      AppearancePresetIds.licoSodaLight,
    );

    // An explicit runtime reload re-reads exactly the sources that are still
    // observed and installs their current values without dispatching a
    // business command.
    final observedBeforeReload = counting.observedOpens();
    final writesBeforeReload =
        harness.preferences.appearanceWrites + harness.preferences.localeWrites;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPanel)),
    );
    container.read(presentationRuntimeProvider).recompute();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    counting.expectReloaded(observedBeforeReload);
    expect(
      harness.preferences.appearanceWrites + harness.preferences.localeWrites,
      writesBeforeReload,
      reason: 'a reload must not dispatch a business command',
    );
    expect(find.byKey(const Key('settings-appearance-dropdown')), findsOne);

    // One real user action: pick a locale from the general region. It writes
    // exactly one persistence command and refreshes only that region.
    final generalEventsBeforeLocale = counting.general.events;
    final appearanceEventsBeforeLocale = counting.appearance.events;
    final localeWritesBefore = harness.preferences.localeWrites;
    await tester.tap(find.byKey(const Key('settings-locale-dropdown')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('settings-locale-zh')).last);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => harness.preferences.localeWrites == localeWritesBefore + 1,
    );
    await tester.pump();

    expect(harness.preferences.localeWrites, localeWritesBefore + 1);
    expect(harness.preferences.value.localePreference, 'zh');
    expect(
      counting.appearance.events,
      appearanceEventsBeforeLocale,
      reason: 'the appearance region must not refresh',
    );
    expect(
      counting.general.events,
      greaterThan(generalEventsBeforeLocale),
      reason: 'the general region refreshes for its own change',
    );
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(condition(), isTrue, reason: 'condition was not reached in time');
}

/// Renders the same installed region values with an unrelated view, so the
/// renderer can be replaced without touching the source or the state.
class _AlternateSettingsSurface extends ConsumerWidget {
  const _AlternateSettingsSurface();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(settingsAppearanceInputsProvider);
    final general = ref.watch(settingsGeneralInputsProvider);
    final appearanceValue = appearance.hasValue
        ? appearance.requireValue
        : null;
    final generalValue = general.hasValue ? general.requireValue : null;
    return Column(
      children: <Widget>[
        Text('alt-appearance:${appearanceValue?.appearancePresetId ?? ''}'),
        Text('alt-general:${generalValue?.localeChoices.length ?? -1}'),
      ],
    );
  }
}

final class _CountingSources {
  _CountingSources(_SettingsHarness harness)
    : general = _CountingSource(
        harness.readSource(settingsGeneralSourceProvider),
      ),
      appearance = _CountingSource(
        harness.readSource(settingsAppearanceSourceProvider),
      ),
      layout = _CountingSource(
        harness.readSource(settingsLayoutSourceProvider),
      ),
      storage = _CountingSource(
        harness.readSource(settingsStorageSourceProvider),
      ),
      update = _CountingSource(
        harness.readSource(settingsUpdateSourceProvider),
      ),
      archived = _CountingSource(
        harness.readSource(settingsArchivedSourceProvider),
      ),
      logExport = _CountingSource(
        harness.readSource(settingsLogExportSourceProvider),
      ),
      autostart = _CountingSource(
        harness.readSource(settingsAutostartSourceProvider),
      ),
      resourceUsage = _CountingSource(
        harness.readSource(settingsResourceUsageSourceProvider),
      );

  final _CountingSource<SettingsGeneralInputs> general;
  final _CountingSource<SettingsAppearanceInputs> appearance;
  final _CountingSource<SettingsLayoutInputs> layout;
  final _CountingSource<SettingsStorageInputs> storage;
  final _CountingSource<SettingsUpdateInputs> update;
  final _CountingSource<SettingsArchivedInputs> archived;
  final _CountingSource<SettingsLogExportInputs> logExport;
  final _CountingSource<SettingsAutostartProjection> autostart;
  final _CountingSource<SettingsResourceUsageProjection> resourceUsage;

  int get totalOpens =>
      general.opens +
      appearance.opens +
      layout.opens +
      storage.opens +
      update.opens +
      archived.opens +
      logExport.opens +
      autostart.opens +
      resourceUsage.opens;

  /// Regions with an open observation before an explicit reload.
  Map<String, int> observedOpens() => <String, int>{
    'general': general.opens,
    'appearance': appearance.opens,
    'layout': layout.opens,
    'storage': storage.opens,
    'update': update.opens,
    'archived': archived.opens,
    'logExport': logExport.opens,
    'autostart': autostart.opens,
    'resourceUsage': resourceUsage.opens,
  };

  /// Every observed region re-read exactly once; every unobserved region stays
  /// closed, so a reload follows the local subscriptions instead of the whole
  /// feature.
  void expectReloaded(Map<String, int> before) {
    final after = observedOpens();
    for (final entry in before.entries) {
      expect(
        after[entry.key],
        entry.value == 0 ? 0 : entry.value + 1,
        reason: 'region ${entry.key} reload behavior',
      );
    }
  }

  List<Override> get overrides => <Override>[
    settingsGeneralSourceProvider.overrideWithValue(general),
    settingsAppearanceSourceProvider.overrideWithValue(appearance),
    settingsLayoutSourceProvider.overrideWithValue(layout),
    settingsStorageSourceProvider.overrideWithValue(storage),
    settingsUpdateSourceProvider.overrideWithValue(update),
    settingsArchivedSourceProvider.overrideWithValue(archived),
    settingsLogExportSourceProvider.overrideWithValue(logExport),
    settingsAutostartSourceProvider.overrideWithValue(autostart),
    settingsResourceUsageSourceProvider.overrideWithValue(resourceUsage),
  ];
}

final class _CountingSource<T> implements PresentationSource<T> {
  _CountingSource(this._delegate);

  final PresentationSource<T> _delegate;
  int opens = 0;
  int events = 0;

  @override
  ResourceFieldGroup<T> get fieldGroup => _delegate.fieldGroup;

  @override
  Future<SourceObservation<T>> open() async {
    opens += 1;
    final observation = await _delegate.open();
    return SourceObservation<T>(
      initial: observation.initial,
      changes: observation.changes.map((change) {
        events += 1;
        return change;
      }),
    );
  }
}

final class _SettingsHarness {
  _SettingsHarness._(
    this.controller,
    this.feature,
    this.preferences,
    this._sources,
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
    return _SettingsHarness._(
      controller,
      feature,
      preferences,
      ProviderContainer(overrides: feature.providerOverrides),
    );
  }

  final ClientController controller;
  final SettingsFeatureComposition feature;
  final _HarnessPreferencesRepository preferences;
  final ProviderContainer _sources;

  S readSource<S>(ProviderListenable<S> provider) => _sources.read(provider);

  Future<void> dispose() async {
    _sources.dispose();
    await feature.dispose();
    controller.dispose();
  }
}

final class _HarnessPreferencesRepository
    implements PresentationPreferencesRepository {
  int appearanceWrites = 0;
  int localeWrites = 0;
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
  Future<PresentationPreferences> setLocalePreference(String preference) async {
    localeWrites += 1;
    return value = value.copyWith(localePreference: preference);
  }
}
