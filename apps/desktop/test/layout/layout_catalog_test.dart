import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/layout_variant.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_catalog_test_fixtures.dart';

void main() {
  test('catalog materializes one deterministic exact product', () {
    final catalog = fixtureLayoutCatalog();

    expect(catalog.defaultProfile.id, LayoutProfileId.parse('workbench'));
    expect(catalog.profiles.map((profile) => profile.id), [
      LayoutProfileId.parse('workbench'),
      LayoutProfileId.parse('studio'),
    ]);
    final expectedVariantsPerProfile = LayoutRuntimeSurface.values.fold<int>(
      0,
      (total, surface) =>
          total + LayoutViewportPolicy.supportedFor(surface).length,
    );
    expect(
      catalog.variantByKey,
      hasLength(catalog.profiles.length * expectedVariantsPerProfile),
    );
    for (final surface in LayoutRuntimeSurface.values) {
      expect(
        catalog.variantByKey.keys.where((key) => key.surface == surface),
        hasLength(
          catalog.profiles.length *
              LayoutViewportPolicy.supportedFor(surface).length,
        ),
      );
    }

    for (final entry in catalog.variantByKey.entries) {
      expect(
        entry.value.destinations,
        catalog.destinationCatalog.destinationsFor(entry.key.surface),
      );
    }
  });

  test('desktop and mobile medium keys cannot collide', () {
    final catalog = fixtureLayoutCatalog();
    final desktopMedium = LayoutVariantKey(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.desktop,
      viewport: LayoutViewportClass.medium,
    );
    final mobileMedium = LayoutVariantKey(
      profileId: LayoutProfileId.parse('workbench'),
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
      () => LayoutProfileId.parse('numeric-2'),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'catalog permits profile-local revisions and rejects incomplete variants',
    () {
      final mixedRevision = fixtureLayoutCatalog(
        profiles: fixtureProfiles(studioRevision: 2),
      );
      expect(
        mixedRevision.profile(LayoutProfileId.parse('studio'))?.revision,
        2,
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
    },
  );

  test('catalog rejects unsupported and wrong-surface coverage', () {
    final variants = fixtureVariants();
    final unsupported = LayoutVariantCoverage(
      key: LayoutVariantKey(
        profileId: LayoutProfileId.parse('workbench'),
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

    final first = variants.firstWhere(
      (variant) => variant.key.surface == LayoutRuntimeSurface.mobile,
    );
    final wrongDestinations = LayoutVariantCoverage(
      key: first.key,
      destinations: {...first.destinations, ClientSection.monitoring},
    );
    expect(
      () => fixtureLayoutCatalog(
        variants: [
          for (final variant in variants)
            if (variant.key == first.key) wrongDestinations else variant,
        ],
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
            channel: const LayoutStateChannel(
              'pane',
              LayoutStateValueKind.paneExtent,
            ),
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
            profileId: LayoutProfileId.parse('workbench'),
            surface: LayoutRuntimeSurface.mobile,
            destination: ClientSection.skillHub,
            channel: const LayoutStateChannel(
              'pane',
              LayoutStateValueKind.paneExtent,
            ),
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
