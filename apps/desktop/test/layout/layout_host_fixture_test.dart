import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/layout/layout_manager.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_definition.dart';
import 'package:flutter_client/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:flutter_client/src/frontend/layout/layout_host.dart';
import 'package:flutter_client/src/frontend/layout/layout_registry.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_host_test_fixtures.dart';

void main() {
  test('fixture registry exactly matches catalog products and namespaces', () {
    final runtime = buildFixtureLayoutRuntime();

    expect(runtime.registry.definitions, hasLength(2));
    expect(runtime.registry.variants, hasLength(8));
    expect(runtime.catalog.stateNamespaces, hasLength(4));
    expect(runtime.registry.definition(LayoutProfileId.workbench).bundles, {
      LayoutRuntimeSurface.desktop: isNotNull,
      LayoutRuntimeSurface.mobile: isNotNull,
    });
  });

  test('definition and registry reject incomplete surface or destinations', () {
    final semantic = SemanticDestinationCatalog.current();
    final descriptor = fixtureLayoutDescriptors().first;
    final desktop = buildFixtureSurfaceBundle(
      descriptor: descriptor,
      surface: LayoutRuntimeSurface.desktop,
      destinationCatalog: semantic,
    );
    expect(() => LayoutDefinition([desktop]), throwsFormatException);

    final validRuntime = buildFixtureLayoutRuntime();
    final badMobile = buildFixtureSurfaceBundle(
      descriptor: descriptor,
      surface: LayoutRuntimeSurface.mobile,
      destinationCatalog: semantic,
      destinationOverride: {
        ClientSection.agents,
        ClientSection.mobileRelay,
        ClientSection.settings,
      },
    );
    final badWorkbench = LayoutDefinition([desktop, badMobile]);
    expect(
      () => LayoutRegistry(
        catalog: validRuntime.catalog,
        definitions: [
          badWorkbench,
          validRuntime.registry.definition(LayoutProfileId.studio),
        ],
      ),
      throwsFormatException,
    );
  });

  test('tokens interpolate deterministically and validate bounds', () {
    final runtime = buildFixtureLayoutRuntime();
    final workbench = runtime.registry
        .definition(LayoutProfileId.workbench)
        .bundles[LayoutRuntimeSurface.desktop]!
        .tokens;
    final studio = runtime.registry
        .definition(LayoutProfileId.studio)
        .bundles[LayoutRuntimeSurface.desktop]!
        .tokens;
    final midpoint = workbench.lerp(studio, 0.5);

    expect(midpoint.spacingUnit, 6);
    expect(midpoint.cardRadius, 11);
    expect(midpoint.motionDuration, const Duration(milliseconds: 135));
    expect(
      () => LayoutVisualTokens(
        spacingUnit: -1,
        density: 1,
        cardRadius: 1,
        elevation: 0,
        navigationExtent: 1,
        contentMaxWidth: 1,
        typographyScale: 1,
        motionDuration: Duration.zero,
      ),
      throwsFormatException,
    );
  });

  test('semantic focus restores equivalent target or primary landmark', () {
    final coordinator = LayoutFocusCoordinator();
    coordinator.capture('composer-field');
    expect(
      coordinator.resolve(
        availableTargets: {'primary-landmark', 'composer-field'},
        primaryTarget: 'primary-landmark',
      ),
      'composer-field',
    );
    expect(
      coordinator.resolve(
        availableTargets: {'primary-landmark', 'navigation-item'},
        primaryTarget: 'primary-landmark',
      ),
      'primary-landmark',
    );
  });

  testWidgets('host mounts only the effective profile with scoped rebuilds', (
    tester,
  ) async {
    final tracker = FixtureBuildTracker();
    final runtime = buildFixtureLayoutRuntime(tracker: tracker);
    final repository = MemoryPreferencesRepository();
    final manager = LayoutManager(
      catalog: runtime.catalog,
      preferencesRepository: repository,
      initialEnvironment: desktopEnvironment(800),
    );
    await manager.initialize();
    final parentBuilds = ValueNotifier<int>(0);
    final stateStore = LayoutStateStore(runtime.catalog);

    await tester.pumpWidget(
      MaterialApp(
        home: FixtureParent(
          builds: parentBuilds,
          child: LayoutHost(
            manager: manager,
            registry: runtime.registry,
            stateStore: stateStore,
            environment: desktopEnvironment(800),
            destination: ClientSection.agents,
            onSelectDestination: (_) {},
            destinationLabel: (destination) => destination.name,
            content: const FixtureDestinationContent(),
            focusCoordinator: LayoutFocusCoordinator(),
            availableFocusTargets: const {'primary-landmark', 'composer-field'},
            primaryFocusTarget: 'primary-landmark',
            loadingBuilder: (_) => const SizedBox(key: Key('loading')),
          ),
        ),
      ),
    );

    expect(parentBuilds.value, 1);
    expect(
      find.byKey(const Key('layout-host-workbench/desktop/medium')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('layout-host-studio/desktop/medium')),
      findsNothing,
    );
    expect(tracker.shellBuilds[LayoutProfileId.workbench], 1);
    expect(tracker.shellBuilds[LayoutProfileId.studio] ?? 0, 0);

    manager.beginPreview(LayoutProfileId.studio);
    await tester.pump();
    expect(parentBuilds.value, 1);
    expect(
      find.byKey(const Key('layout-host-workbench/desktop/medium')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('layout-host-studio/desktop/medium')),
      findsOneWidget,
    );
    expect(tracker.shellBuilds[LayoutProfileId.studio], 1);
    manager.dispose();
  });

  testWidgets('scope exposes only active declared presentation namespaces', (
    tester,
  ) async {
    final runtime = buildFixtureLayoutRuntime();
    final manager = LayoutManager(
      catalog: runtime.catalog,
      preferencesRepository: MemoryPreferencesRepository(),
      initialEnvironment: desktopEnvironment(800),
    );
    await manager.initialize();
    final stateStore = LayoutStateStore(runtime.catalog);

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutHost(
          manager: manager,
          registry: runtime.registry,
          stateStore: stateStore,
          environment: desktopEnvironment(800),
          destination: ClientSection.agents,
          onSelectDestination: (_) {},
          destinationLabel: (destination) => destination.name,
          content: const FixtureDestinationContent(),
          focusCoordinator: LayoutFocusCoordinator(),
          availableFocusTargets: const {'primary-landmark'},
          primaryFocusTarget: 'primary-landmark',
          loadingBuilder: (_) => const SizedBox(),
        ),
      ),
    );

    final context = tester.element(
      find.byKey(const Key('fixture-content-agents')),
    );
    final scope = LayoutScope.of(context);
    scope.state.write(
      destination: ClientSection.agents,
      surfaceId: 'fixture-scroll',
      value: LayoutScrollState(42),
    );
    expect(
      (scope.state.read(
                destination: ClientSection.agents,
                surfaceId: 'fixture-scroll',
              )
              as LayoutScrollState)
          .offset,
      42,
    );
    expect(
      () => scope.state.write(
        destination: ClientSection.settings,
        surfaceId: 'undeclared-value',
        value: const LayoutExpansionState(true),
      ),
      throwsFormatException,
    );
    manager.dispose();
  });
}

LayoutEnvironment desktopEnvironment(double width) =>
    LayoutEnvironment.fromConstraints(
      surface: LayoutRuntimeSurface.desktop,
      width: width,
      height: 800,
      textScale: 1,
      hasKeyboard: true,
      hasPointer: true,
    );

final class FixtureParent extends StatelessWidget {
  const FixtureParent({super.key, required this.builds, required this.child});

  final ValueNotifier<int> builds;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    builds.value += 1;
    return child;
  }
}

final class MemoryPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences value = PresentationPreferences(
    layoutProfileId: LayoutProfileId.workbench,
    appearancePresetId: 'default-system',
    localePreference: 'system',
  );

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
  Future<PresentationPreferences> setLocalePreference(String preference) async {
    value = value.copyWith(localePreference: preference);
    return value;
  }
}
