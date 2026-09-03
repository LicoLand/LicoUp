import 'package:flutter/material.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:licoup/src/frontend/layout/layout_host.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_host_test_fixtures.dart';

void main() {
  test(
    'semantic status snapshots are value-equal and use captions as fallback',
    () {
      const first = LayoutChromeSnapshot(
        status: LayoutChromeStatusSnapshot(
          message: 'Ready',
          caption: 'Client',
          errorCode: '',
        ),
      );
      const second = LayoutChromeSnapshot(
        status: LayoutChromeStatusSnapshot(
          message: 'Ready',
          caption: 'Client',
          errorCode: '',
        ),
      );

      expect(first, second);
      expect(
        const LayoutChromeStatusSnapshot(
          message: '',
          caption: 'Fallback',
          errorCode: '',
        ).displayText,
        'Fallback',
      );
    },
  );

  test('composition chrome selects focused status updates only', () async {
    final controller = ClientController(
      mobileClientRuntimePlatformOverride: true,
    );
    final composition = ClientAppComposition(controller: controller);
    addTearDown(composition.dispose);
    final adapter = composition.renderer.chrome;
    var notifications = 0;
    adapter.addListener(() => notifications += 1);

    expect(adapter.value.status.displayText, isNotEmpty);
    controller.selectSection(ClientSection.settings);
    expect(notifications, 0);

    controller.statusMessage = 'Focused status';
    expect(adapter.value.status.displayText, 'Focused status');
    expect(notifications, 1);

    controller.lastError = 'focused_error';
    expect(adapter.value.status.errorCode, 'focused_error');
    expect(notifications, 2);
  });

  testWidgets('layout host passes the exact chrome port to the active shell', (
    tester,
  ) async {
    LayoutShellBuildContext? observed;
    final runtime = buildFixtureLayoutRuntime(
      onShellBuild: (data) => observed = data,
    );
    final manager = LayoutManager(
      catalog: runtime.catalog,
      preferencesRepository: _MemoryPreferencesRepository(),
      canonicalFallback: _preferences(),
      initialEnvironment: _desktopEnvironment(),
    );
    await manager.initialize();
    final chrome = _RecordingChromePort();
    addTearDown(() {
      manager.dispose();
      chrome.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutHost(
          selection: manager.state,
          registry: runtime.registry,
          stateStore: LayoutStateStore(runtime.catalog),
          environment: _desktopEnvironment(),
          onUpdateEnvironment: (value) =>
              manager.updateEnvironment(value, notify: false),
          destination: ClientSection.agents,
          onSelectDestination: (_) {},
          destinationLabel: (destination) => destination.name,
          content: const FixtureDestinationContent(),
          focusCoordinator: LayoutFocusCoordinator(),
          primaryFocusTarget: 'primary-landmark',
          loadingBuilder: (_) => const SizedBox(),
          palette: fixtureLayoutPalette,
          chrome: chrome,
        ),
      ),
    );

    expect(observed, isNotNull);
    expect(identical(observed!.chrome, chrome), isTrue);
  });
}

LayoutEnvironment _desktopEnvironment() => LayoutEnvironment.fromConstraints(
  surface: LayoutRuntimeSurface.desktop,
  width: 800,
  height: 600,
  textScale: 1,
  hasPointer: true,
  hasKeyboard: true,
);

PresentationPreferences _preferences() => PresentationPreferences(
  layoutProfileId: LayoutProfileId.parse('dashboard'),
  appearancePresetId: 'default-system',
  localePreference: 'system',
);

final class _MemoryPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences value = _preferences();

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: value);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async {
    value = value.copyWith(appearancePresetId: id);
    return value;
  }

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async {
    value = value.copyWith(layoutProfileId: id);
    return value;
  }

  @override
  Future<PresentationPreferences> setLocalePreference(String value) async {
    this.value = this.value.copyWith(localePreference: value);
    return this.value;
  }
}

final class _RecordingChromePort extends ValueNotifier<LayoutChromeSnapshot>
    implements LayoutChromePort {
  _RecordingChromePort() : super(const LayoutChromeSnapshot.empty());

  @override
  Future<void> openPairing(BuildContext context) async {}

  @override
  Future<void> openGlobalSearch(BuildContext context) async {}
}
