import 'package:flutter_client/src/application/features/layout/layout_catalog.dart';
import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_variant.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_catalog_test_fixtures.dart';

void main() {
  test('catalog materializes one deterministic exact product', () {
    final catalog = fixtureLayoutCatalog();

    expect(catalog.defaultProfile.id, LayoutProfileId.workbench);
    expect(catalog.profiles.map((profile) => profile.id), [
      LayoutProfileId.workbench,
      LayoutProfileId.studio,
    ]);
    expect(catalog.variantByKey, hasLength(8));
    expect(
      catalog.variantByKey.keys.where(
        (key) => key.surface == LayoutRuntimeSurface.desktop,
      ),
      hasLength(4),
    );
    expect(
      catalog.variantByKey.keys.where(
        (key) => key.surface == LayoutRuntimeSurface.mobile,
      ),
      hasLength(4),
    );

    for (final entry in catalog.variantByKey.entries) {
      expect(
        entry.value.destinations,
        catalog.destinationCatalog.destinationsFor(entry.key.surface),
      );
    }
  });

  test('desktop and mobile medium keys cannot collide', () {
    final catalog = fixtureLayoutCatalog();
    const desktopMedium = LayoutVariantKey(
      profileId: LayoutProfileId.workbench,
      surface: LayoutRuntimeSurface.desktop,
      viewport: LayoutViewportClass.medium,
    );
    const mobileMedium = LayoutVariantKey(
      profileId: LayoutProfileId.workbench,
      surface: LayoutRuntimeSurface.mobile,
      viewport: LayoutViewportClass.medium,
    );

    expect(catalog.coverage(desktopMedium).key, desktopMedium);
    expect(catalog.coverage(mobileMedium).key, mobileMedium);
    expect(desktopMedium, isNot(mobileMedium));
  });

  test('catalog rejects duplicate profiles and invalid defaults', () {
    final profiles = fixtureProfiles();
    expect(
      () => fixtureLayoutCatalog(profiles: [...profiles, profiles.first]),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => fixtureLayoutCatalog(
        profiles: fixtureProfiles(
          workbenchDefault: false,
          studioDefault: false,
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => fixtureLayoutCatalog(
        profiles: fixtureProfiles(workbenchDefault: true, studioDefault: true),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LayoutProfileId.parse('layout-2'),
      throwsA(isA<FormatException>()),
    );
  });

  test('catalog rejects revision mismatch and incomplete variants', () {
    expect(
      () => fixtureLayoutCatalog(profiles: fixtureProfiles(studioRevision: 2)),
      throwsA(isA<FormatException>()),
    );
    final variants = fixtureVariants();
    expect(
      () => fixtureLayoutCatalog(variants: variants.sublist(1)),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => fixtureLayoutCatalog(variants: [...variants, variants.first]),
      throwsA(isA<FormatException>()),
    );
  });

  test('catalog rejects unsupported and wrong-surface coverage', () {
    final variants = fixtureVariants();
    final unsupported = LayoutVariantCoverage(
      key: const LayoutVariantKey(
        profileId: LayoutProfileId.workbench,
        surface: LayoutRuntimeSurface.desktop,
        viewport: LayoutViewportClass.compact,
      ),
      destinations: SemanticDestinationCatalog.current().destinationsFor(
        LayoutRuntimeSurface.desktop,
      ),
    );
    expect(
      () => fixtureLayoutCatalog(variants: [...variants, unsupported]),
      throwsA(isA<FormatException>()),
    );

    final first = variants.first;
    final wrongDestinations = LayoutVariantCoverage(
      key: first.key,
      destinations: {...first.destinations, ClientSection.feed},
    );
    expect(
      () => fixtureLayoutCatalog(
        variants: [wrongDestinations, ...variants.skip(1)],
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('catalog rejects unknown, alias, and duplicate state namespaces', () {
    final namespaces = fixtureStateNamespaces();
    expect(
      () => fixtureLayoutCatalog(
        stateNamespaces: [...namespaces, namespaces.first],
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => fixtureLayoutCatalog(
        stateNamespaces: [
          ...namespaces,
          LayoutStateNamespace(
            profileId: LayoutProfileId.parse('focus'),
            surface: LayoutRuntimeSurface.desktop,
            destination: ClientSection.agents,
            surfaceId: 'pane',
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => fixtureLayoutCatalog(
        stateNamespaces: [
          ...namespaces,
          LayoutStateNamespace(
            profileId: LayoutProfileId.workbench,
            surface: LayoutRuntimeSurface.desktop,
            destination: ClientSection.skillHub,
            surfaceId: 'pane',
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
