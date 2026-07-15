import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_catalog_test_fixtures.dart';

void main() {
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

    store.resetProfile(LayoutProfileId.parse('workbench'));
    expect(store.read(workbench), isNull);
    expect((store.read(studio) as LayoutScrollState).offset, 64);
    expect(store.length, 1);
    store.resetAll();
    expect(store.length, 0);
  });

  test('state store rejects undeclared keys and mismatched value kinds', () {
    final store = LayoutStateStore(fixtureLayoutCatalog());
    final unregistered = LayoutStateNamespace(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: const LayoutStateChannel(
        'private-path',
        LayoutStateValueKind.expansion,
      ),
    );

    expect(
      () => store.write(unregistered, const LayoutExpansionState(true)),
      throwsFormatException,
    );
    expect(() => LayoutScrollState(double.infinity), throwsFormatException);
    expect(() => LayoutPaneExtentState(-1), throwsFormatException);
    expect(() => LayoutTabState(-1), throwsFormatException);
    expect(
      () => store.write(
        fixtureStateNamespaces().first,
        const LayoutExpansionState(true),
      ),
      throwsFormatException,
    );
  });
}
