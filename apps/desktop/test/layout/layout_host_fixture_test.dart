import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/layout/layout_manager.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_definition.dart';
import 'package:flutter_client/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:flutter_client/src/frontend/layout/layout_host.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_registry.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/layout_chrome_fixture.dart';
import 'layout_host_test_fixtures.dart';

void main() {
  test('fixture registry exactly matches catalog products and namespaces', () {
    final runtime = buildFixtureLayoutRuntime();

    expect(runtime.registry.definitions, hasLength(runtime.definitions.length));
    final expectedVariantCount = runtime.definitions.fold<int>(
      0,
      (total, definition) =>
          total +
          definition.bundles.values.fold<int>(
            0,
            (bundleTotal, bundle) => bundleTotal + bundle.variants.length,
          ),
    );
    expect(runtime.registry.variants, hasLength(expectedVariantCount));
    final expectedNamespaceCount = runtime.definitions.fold<int>(
      0,
      (total, definition) =>
          total +
          definition.bundles.values.fold<int>(
            0,
            (bundleTotal, bundle) =>
                bundleTotal + bundle.stateNamespaces.length,
          ),
    );
    expect(runtime.catalog.stateNamespaces, hasLength(expectedNamespaceCount));
    expect(
      runtime.registry
          .definition(LayoutProfileId.parse('workbench'))
          .bundles
          .keys
          .toSet(),
      LayoutRuntimeSurface.values.toSet(),
    );
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
          validRuntime.registry.definition(LayoutProfileId.parse('studio')),
        ],
      ),
      throwsFormatException,
    );
  });

  test('tokens interpolate deterministically and validate bounds', () {
    final runtime = buildFixtureLayoutRuntime();
    final workbench = runtime.registry
        .definition(LayoutProfileId.parse('workbench'))
        .bundles[LayoutRuntimeSurface.desktop]!
        .tokens;
    final studio = runtime.registry
        .definition(LayoutProfileId.parse('studio'))
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

  testWidgets('semantic focus restores a real node or primary landmark', (
    tester,
  ) async {
    final coordinator = LayoutFocusCoordinator();
    final originalComposer = FocusNode();
    final replacementComposer = FocusNode();
    final primary = FocusNode();
    addTearDown(originalComposer.dispose);
    addTearDown(replacementComposer.dispose);
    addTearDown(primary.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutFocusScope(
          coordinator: coordinator,
          child: LayoutFocusNodeRegistration(
            semanticTarget: LayoutFocusTargets.composerField,
            focusNode: originalComposer,
            child: Focus(focusNode: originalComposer, child: const SizedBox()),
          ),
        ),
      ),
    );
    originalComposer.requestFocus();
    await tester.pump();
    expect(coordinator.captureActiveTarget(), LayoutFocusTargets.composerField);

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutFocusScope(
          coordinator: coordinator,
          child: LayoutFocusNodeRegistration(
            semanticTarget: LayoutFocusTargets.composerField,
            focusNode: replacementComposer,
            child: Focus(
              focusNode: replacementComposer,
              child: const SizedBox(),
            ),
          ),
        ),
      ),
    );
    expect(
      coordinator.restore(primaryTarget: LayoutFocusTargets.primaryLandmark),
      isTrue,
    );
    await tester.pump();
    expect(replacementComposer.hasPrimaryFocus, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutFocusScope(
          coordinator: coordinator,
          child: LayoutFocusNodeRegistration(
            semanticTarget: LayoutFocusTargets.primaryLandmark,
            focusNode: primary,
            child: Focus(focusNode: primary, child: const SizedBox()),
          ),
        ),
      ),
    );
    expect(
      coordinator.restore(primaryTarget: LayoutFocusTargets.primaryLandmark),
      isTrue,
    );
    await tester.pump();
    expect(primary.hasPrimaryFocus, isTrue);
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
      canonicalFallback: fixturePreferences(),
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
            primaryFocusTarget: 'primary-landmark',
            loadingBuilder: (_) => const SizedBox(key: Key('loading')),
            palette: fixtureLayoutPalette,
            chrome: const FixtureLayoutChromePort(),
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
    expect(tracker.shellBuilds[LayoutProfileId.parse('workbench')], 1);
    expect(tracker.shellBuilds[LayoutProfileId.parse('studio')] ?? 0, 0);

    manager.beginPreview(LayoutProfileId.parse('studio'));
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
    expect(tracker.shellBuilds[LayoutProfileId.parse('studio')], 1);
    manager.dispose();
  });

  testWidgets('scope exposes only active declared presentation namespaces', (
    tester,
  ) async {
    final runtime = buildFixtureLayoutRuntime();
    final manager = LayoutManager(
      catalog: runtime.catalog,
      preferencesRepository: MemoryPreferencesRepository(),
      canonicalFallback: fixturePreferences(),
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
          primaryFocusTarget: 'primary-landmark',
          loadingBuilder: (_) => const SizedBox(),
          palette: fixtureLayoutPalette,
          chrome: const FixtureLayoutChromePort(),
        ),
      ),
    );

    final context = tester.element(
      find.byKey(const Key('fixture-content-agents')),
    );
    final scope = LayoutScope.of(context);
    const fixtureScroll = LayoutStateChannel(
      'fixture-scroll',
      LayoutStateValueKind.scroll,
    );
    scope.state.write(fixtureScroll, LayoutScrollState(42));
    expect((scope.state.read(fixtureScroll) as LayoutScrollState).offset, 42);
    expect(
      () => scope.state.write(
        const LayoutStateChannel(
          'undeclared-value',
          LayoutStateValueKind.expansion,
        ),
        const LayoutExpansionState(true),
      ),
      throwsFormatException,
    );
    manager.dispose();
  });

  testWidgets('host exposes the required neutral palette to active content', (
    tester,
  ) async {
    final runtime = buildFixtureLayoutRuntime();
    final manager = LayoutManager(
      catalog: runtime.catalog,
      preferencesRepository: MemoryPreferencesRepository(),
      canonicalFallback: fixturePreferences(),
      initialEnvironment: desktopEnvironment(800),
    );
    await manager.initialize();
    LayoutPalette? observed;

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutHost(
          manager: manager,
          registry: runtime.registry,
          stateStore: LayoutStateStore(runtime.catalog),
          environment: desktopEnvironment(800),
          destination: ClientSection.agents,
          onSelectDestination: (_) {},
          destinationLabel: (destination) => destination.name,
          content: _PaletteRecordingContent((value) => observed = value),
          focusCoordinator: LayoutFocusCoordinator(),
          primaryFocusTarget: 'primary-landmark',
          loadingBuilder: (_) => const SizedBox(),
          palette: fixtureLayoutPalette,
          chrome: const FixtureLayoutChromePort(),
        ),
      ),
    );

    expect(observed, same(fixtureLayoutPalette));
    manager.dispose();
  });

  testWidgets('host synchronizes first-frame environment before hydration', (
    tester,
  ) async {
    final runtime = buildFixtureLayoutRuntime();
    final manager = LayoutManager(
      catalog: runtime.catalog,
      preferencesRepository: MemoryPreferencesRepository(),
      canonicalFallback: fixturePreferences(),
      initialEnvironment: desktopEnvironment(800),
    );
    final expanded = desktopEnvironment(1400);

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutHost(
          manager: manager,
          registry: runtime.registry,
          stateStore: LayoutStateStore(runtime.catalog),
          environment: expanded,
          destination: ClientSection.agents,
          onSelectDestination: (_) {},
          destinationLabel: (destination) => destination.name,
          content: const FixtureDestinationContent(),
          focusCoordinator: LayoutFocusCoordinator(),
          primaryFocusTarget: 'primary-landmark',
          loadingBuilder: (_) => const SizedBox(key: Key('loading')),
          palette: fixtureLayoutPalette,
          chrome: const FixtureLayoutChromePort(),
        ),
      ),
    );

    expect(manager.state.viewport, LayoutViewportClass.expanded);
    expect(find.byKey(const Key('loading')), findsOneWidget);
    await manager.initialize();
    await tester.pump();
    expect(
      find.byKey(const Key('layout-host-workbench/desktop/expanded')),
      findsOneWidget,
    );
    manager.dispose();
  });

  testWidgets('host rejects a manager from a different catalog instance', (
    tester,
  ) async {
    final hostRuntime = buildFixtureLayoutRuntime();
    final managerRuntime = buildFixtureLayoutRuntime();
    final manager = LayoutManager(
      catalog: managerRuntime.catalog,
      preferencesRepository: MemoryPreferencesRepository(),
      canonicalFallback: fixturePreferences(),
      initialEnvironment: desktopEnvironment(800),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutHost(
          manager: manager,
          registry: hostRuntime.registry,
          stateStore: LayoutStateStore(hostRuntime.catalog),
          environment: desktopEnvironment(800),
          destination: ClientSection.agents,
          onSelectDestination: (_) {},
          destinationLabel: (destination) => destination.name,
          content: const FixtureDestinationContent(),
          focusCoordinator: LayoutFocusCoordinator(),
          primaryFocusTarget: 'primary-landmark',
          loadingBuilder: (_) => const SizedBox(),
          palette: fixtureLayoutPalette,
          chrome: const FixtureLayoutChromePort(),
        ),
      ),
    );

    expect(tester.takeException(), isA<FormatException>());
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

PresentationPreferences fixturePreferences() => PresentationPreferences(
  layoutProfileId: LayoutProfileId.parse('workbench'),
  appearancePresetId: 'default-system',
  localePreference: 'system',
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

final class _PaletteRecordingContent implements LayoutDestinationContentPort {
  const _PaletteRecordingContent(this.onBuild);

  final ValueChanged<LayoutPalette> onBuild;

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    onBuild(context.layoutPalette);
    return const SizedBox(key: Key('palette-recording-content'));
  }
}

final class MemoryPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences value = fixturePreferences();

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
