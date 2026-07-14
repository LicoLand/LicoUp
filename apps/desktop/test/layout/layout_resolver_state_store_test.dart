import 'package:flutter_client/src/application/features/layout/layout_resolver.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_selection.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_catalog_test_fixtures.dart';

void main() {
  test('resolver retains selected identity across surface-local resize', () {
    final resolver = LayoutResolver(fixtureLayoutCatalog());
    final medium = resolver.resolve(
      selectedProfileId: LayoutProfileId.studio,
      environment: desktopEnvironment(width: 800),
    );
    final expanded = resolver.resolve(
      selectedProfileId: LayoutProfileId.studio,
      environment: desktopEnvironment(width: 1400),
    );

    expect(medium.profile.id, LayoutProfileId.studio);
    expect(expanded.profile.id, LayoutProfileId.studio);
    expect(medium.variant.key.viewport, LayoutViewportClass.medium);
    expect(expanded.variant.key.viewport, LayoutViewportClass.expanded);
    expect(resolver.cachedResolutionCount, 1);
  });

  test('resolver uses O(1) active cache and deterministic recovery', () {
    final resolver = LayoutResolver(fixtureLayoutCatalog());
    final environment = mobileEnvironment(width: 390);
    final first = resolver.resolve(
      selectedProfileId: LayoutProfileId.workbench,
      environment: environment,
    );
    final cached = resolver.resolve(
      selectedProfileId: LayoutProfileId.workbench,
      environment: environment,
    );
    final unavailable = resolver.resolve(
      selectedProfileId: LayoutProfileId.parse('focus'),
      environment: environment,
    );
    final invalid = resolver.resolveStoredProfile(
      storedProfileId: 'layout-2',
      environment: environment,
    );

    expect(identical(first, cached), isTrue);
    expect(resolver.cachedResolutionCount, 1);
    expect(unavailable.profile.id, LayoutProfileId.workbench);
    expect(
      unavailable.recoveryError,
      LayoutSelectionErrorCode.unavailableProfile,
    );
    expect(invalid.requestedProfileId, isNull);
    expect(
      invalid.recoveryError,
      LayoutSelectionErrorCode.invalidStoredPreference,
    );
    expect(invalid.profile.id, LayoutProfileId.workbench);
  });

  test('resolver never falls back across surface or viewport', () {
    final resolver = LayoutResolver(fixtureLayoutCatalog());

    final narrowDesktop = resolver.resolve(
      selectedProfileId: LayoutProfileId.workbench,
      environment: desktopEnvironment(width: 320),
    );
    final largeMobile = resolver.resolve(
      selectedProfileId: LayoutProfileId.workbench,
      environment: mobileEnvironment(width: 1400),
    );

    expect(narrowDesktop.variant.key.surface, LayoutRuntimeSurface.desktop);
    expect(narrowDesktop.variant.key.viewport, LayoutViewportClass.medium);
    expect(largeMobile.variant.key.surface, LayoutRuntimeSurface.mobile);
    expect(largeMobile.variant.key.viewport, LayoutViewportClass.medium);
  });

  test('state store accepts only declared bounded presentation values', () {
    final catalog = fixtureLayoutCatalog();
    final store = LayoutStateStore(catalog);
    final workbench = fixtureStateNamespaces().first;
    final studio = fixtureStateNamespaces().last;

    store.write(workbench, LayoutScrollState(128));
    store.write(studio, LayoutScrollState(64));
    expect((store.read(workbench) as LayoutScrollState).offset, 128);
    expect((store.read(studio) as LayoutScrollState).offset, 64);
    expect(store.length, 2);

    store.resetProfile(LayoutProfileId.workbench);
    expect(store.read(workbench), isNull);
    expect((store.read(studio) as LayoutScrollState).offset, 64);
    expect(store.length, 1);
    store.resetAll();
    expect(store.length, 0);
  });

  test('state store rejects undeclared keys and unsafe value shapes', () {
    final store = LayoutStateStore(fixtureLayoutCatalog());
    final unregistered = LayoutStateNamespace(
      profileId: LayoutProfileId.workbench,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      surfaceId: 'private-path',
    );

    expect(
      () => store.write(unregistered, const LayoutExpansionState(true)),
      throwsA(isA<FormatException>()),
    );
    expect(() => LayoutScrollState(double.infinity), throwsFormatException);
    expect(() => LayoutPaneExtentState(-1), throwsFormatException);
    expect(() => LayoutTabState(-1), throwsFormatException);
    expect(() => LayoutFocusState('user/content/value'), throwsFormatException);
  });
}

LayoutEnvironment desktopEnvironment({required double width}) =>
    LayoutEnvironment.fromConstraints(
      surface: LayoutRuntimeSurface.desktop,
      width: width,
      height: 800,
      textScale: 1,
      hasPointer: true,
      hasKeyboard: true,
    );

LayoutEnvironment mobileEnvironment({required double width}) =>
    LayoutEnvironment.fromConstraints(
      surface: LayoutRuntimeSurface.mobile,
      width: width,
      height: 900,
      textScale: 1,
      hasTouch: true,
    );
