import 'package:licoup/src/frontend/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_catalog_test_fixtures.dart';

void main() {
  test('state store accepts only declared bounded presentation values', () {
    final catalog = fixtureLayoutCatalog();
    final store = LayoutStateStore(catalog);
    final dashboard = fixtureStateNamespaces().first;
    final native = fixtureStateNamespaces().last;

    store.write(dashboard, LayoutScrollState(128));
    store.write(native, LayoutScrollState(64));
    expect((store.read(dashboard) as LayoutScrollState).offset, 128);
    expect((store.read(native) as LayoutScrollState).offset, 64);
    expect(store.length, 2);

    store.resetProfile(LayoutProfileId.parse('dashboard'));
    expect(store.read(dashboard), isNull);
    expect((store.read(native) as LayoutScrollState).offset, 64);
    expect(store.length, 1);
    store.resetAll();
    expect(store.length, 0);
  });

  test('state store rejects undeclared keys and mismatched value kinds', () {
    final store = LayoutStateStore(fixtureLayoutCatalog());
    final unregistered = LayoutStateNamespace(
      profileId: LayoutProfileId.parse('dashboard'),
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

  test('equal writes and empty resets publish no change', () {
    final store = LayoutStateStore(fixtureLayoutCatalog());
    addTearDown(store.dispose);
    var changes = 0;
    store.changes.listen((_) => changes += 1);
    final namespace = fixtureStateNamespaces().first;

    store.write(namespace, LayoutScrollState(8));
    store.write(namespace, LayoutScrollState(8));
    store.resetProfile(LayoutProfileId.parse('missing'));
    expect(changes, 1);

    store.resetAll();
    store.resetAll();
    expect(changes, 2);
  });
}
