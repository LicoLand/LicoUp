import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/frontend/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/shell/projected_layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:licoup/src/frontend/layout/layout_host.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
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

  test('projected chrome selects focused status updates only', () async {
    final actions = _RecordingChromePort();
    final source = _ProjectionSource(
      const StatusProjection(
        messageChinese: '就绪',
        messageEnglish: 'Ready',
        caption: 'Client',
        errorCode: '',
      ),
    );
    final locale = _ProjectionSource(const LocaleProjection('en'));
    final adapter = ProjectedLayoutChromePort(
      actions: actions,
      status: source,
      locale: locale,
    );
    var notifications = 0;
    adapter.addListener(() => notifications += 1);

    expect(adapter.value.status.displayText, 'Ready');
    source.publish(
      const StatusProjection(
        messageChinese: '就绪',
        messageEnglish: 'Ready',
        caption: 'Client',
        errorCode: '',
      ),
    );
    expect(notifications, 0);

    source.publish(
      const StatusProjection(
        messageChinese: '聚焦状态',
        messageEnglish: 'Focused status',
        caption: 'Client',
        errorCode: '',
      ),
    );
    expect(adapter.value.status.displayText, 'Focused status');
    expect(notifications, 1);

    source.publish(
      const StatusProjection(
        messageChinese: '聚焦状态',
        messageEnglish: 'Focused status',
        caption: 'Client',
        errorCode: 'focused_error',
      ),
    );
    expect(adapter.value.status.errorCode, 'focused_error');
    expect(notifications, 2);

    await adapter.dispose();
    await source.dispose();
    await locale.dispose();
    actions.dispose();
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
          selection: _selection(manager, _desktopEnvironment()),
          registry: runtime.registry,
          stateStore: LayoutStateStore(runtime.catalog),
          environment: _desktopEnvironment(),
          destination: ClientSection.agents,
          availableDestinations: ClientSection.values,
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

LayoutSelectionState _selection(
  LayoutManager manager,
  LayoutEnvironment environment,
) {
  final state = manager.state;
  return LayoutSelectionState(
    committedId: state.committedId,
    effectiveId: state.effectiveId,
    status: state.status,
    surface: environment.surface,
    viewport: environment.viewport,
    operationEpoch: state.operationEpoch,
    errorCode: state.errorCode,
  );
}

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

final class _ProjectionSource<T> implements ProjectionSource<T> {
  _ProjectionSource(this._current);

  final StreamController<ProjectionUpdate<T>> _changes =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  T _current;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _changes.stream;

  void publish(T value) {
    _current = value;
    _changes.add(ProjectionUpdate(value));
  }

  Future<void> dispose() => _changes.close();
}
