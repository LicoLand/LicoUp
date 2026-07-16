import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/application/composition/built_in_layout_composition.dart';
import 'package:flutter_client/src/frontend/layout/layout_definition.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_host_test_fixtures.dart';

void main() {
  test('registered definitions derive one exact immutable N x M product', () {
    final composition = BuiltInLayoutComposition();
    final definitions = composition.definitions;
    final surfaces = LayoutRuntimeSurface.values;
    final bundles = [
      for (final definition in definitions)
        for (final surface in surfaces) definition.bundles[surface]!,
    ];
    final expectedVariantCount = bundles.fold<int>(
      0,
      (count, bundle) => count + bundle.variants.length,
    );
    final expectedNamespaces = {
      for (final bundle in bundles) ...bundle.stateNamespaces,
    };

    expect(bundles, hasLength(definitions.length * surfaces.length));
    for (final definition in definitions) {
      expect(definition.bundles.keys.toSet(), surfaces.toSet());
      for (final surface in surfaces) {
        final bundle = definition.bundles[surface]!;
        expect(bundle.profile, definition.profile);
        expect(bundle.surface, surface);
      }
    }
    expect(composition.catalog.profiles, hasLength(definitions.length));
    expect(composition.registry.definitions, hasLength(definitions.length));
    expect(composition.catalog.variantByKey, hasLength(expectedVariantCount));
    expect(composition.registry.variants, hasLength(expectedVariantCount));
    expect(composition.catalog.stateNamespaces, expectedNamespaces);
    expect(
      identical(composition.registry.catalog, composition.catalog),
      isTrue,
    );
    expect(
      identical(composition.stateStore.catalog, composition.catalog),
      isTrue,
    );
    expect(
      identical(composition.settingsProfiles, composition.catalog.profiles),
      isTrue,
    );

    expect(() => definitions.clear(), throwsUnsupportedError);
    expect(() => definitions.first.bundles.clear(), throwsUnsupportedError);
    expect(
      () => composition.registry.definitions.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => composition.catalog.profileById.clear(),
      throwsUnsupportedError,
    );
  });

  test('composition accepts an extra synthetic typed definition unchanged', () {
    final destinationCatalog = SemanticDestinationCatalog.current();
    final synthetic = LayoutProfileDescriptor(
      id: LayoutProfileId.parse('synthetic-grid'),
      label: LayoutProfileCopy(english: 'Synthetic Grid', chinese: '合成网格'),
      description: LayoutProfileCopy(
        english: 'Synthetic fixture',
        chinese: '合成夹具',
      ),
      styleIdentity: 'synthetic-grid-style',
      isDefault: false,
    );
    final source = [
      for (final descriptor in [...fixtureLayoutDescriptors(), synthetic])
        _fixtureDefinition(descriptor, destinationCatalog),
    ];
    final registeredCount = source.length;

    final composition = BuiltInLayoutComposition.fromDefinitions(source);
    source.removeLast();

    expect(composition.definitions, hasLength(registeredCount));
    expect(
      composition.definitions.expand((definition) => definition.bundles.values),
      hasLength(registeredCount * LayoutRuntimeSurface.values.length),
    );
    expect(composition.registry.definition(synthetic.id).profile, synthetic);
    for (final surface in LayoutRuntimeSurface.values) {
      expect(composition.previewBundle(synthetic.id, surface).surface, surface);
    }
  });

  test('composition rejects empty and duplicate inputs', () {
    expect(
      () => BuiltInLayoutComposition.fromDefinitions(const []),
      _throwsFormat('layout_composition_definition_missing'),
    );

    final destinationCatalog = SemanticDestinationCatalog.current();
    final base = _fixtureDefinition(
      fixtureLayoutDescriptors().first,
      destinationCatalog,
    );
    expect(
      () => BuiltInLayoutComposition.fromDefinitions([base, base]),
      _throwsFormat('layout_composition_profile_duplicate'),
    );

    final nextRevision = LayoutProfileDescriptor(
      id: LayoutProfileId.parse('next-revision'),
      label: LayoutProfileCopy(english: 'Next Revision', chinese: '下一修订'),
      description: LayoutProfileCopy(
        english: 'Revision fixture',
        chinese: '修订夹具',
      ),
      styleIdentity: 'next-revision-style',
      isDefault: false,
      revision: base.profile.revision + 1,
    );
    final mixedRevision = BuiltInLayoutComposition.fromDefinitions([
      base,
      _fixtureDefinition(nextRevision, destinationCatalog),
    ]);
    expect(
      mixedRevision.catalog.profile(nextRevision.id)?.revision,
      nextRevision.revision,
    );
    expect(
      mixedRevision.catalog.revision,
      BuiltInLayoutComposition.catalogSchemaRevision,
    );
  });

  test(
    'typed definitions reject incomplete and duplicate surface products',
    () {
      final destinationCatalog = SemanticDestinationCatalog.current();
      final descriptor = fixtureLayoutDescriptors().first;
      final desktop = buildFixtureSurfaceBundle(
        descriptor: descriptor,
        surface: LayoutRuntimeSurface.desktop,
        destinationCatalog: destinationCatalog,
      );
      final mobile = buildFixtureSurfaceBundle(
        descriptor: descriptor,
        surface: LayoutRuntimeSurface.mobile,
        destinationCatalog: destinationCatalog,
      );

      expect(
        () => LayoutDefinition([desktop]),
        _throwsFormat('layout_definition_surface_product_invalid'),
      );
      expect(
        () => LayoutDefinition([desktop, mobile, desktop]),
        _throwsFormat('layout_definition_surface_duplicate'),
      );
    },
  );

  test('registered metadata flows without a second profile list', () {
    final composition = BuiltInLayoutComposition();
    final registeredProfiles = composition.definitions
        .map((definition) => definition.profile)
        .toList(growable: false);

    expect(composition.settingsProfiles, registeredProfiles);
    expect(
      registeredProfiles.where((profile) => profile.isDefault),
      hasLength(1),
    );
    expect(
      registeredProfiles.map((profile) => profile.styleIdentity).toSet(),
      hasLength(registeredProfiles.length),
    );
    for (final profile in registeredProfiles) {
      expect(profile.styleIdentity, isNotEmpty);
      for (final surface in LayoutRuntimeSurface.values) {
        expect(composition.previewBundle(profile.id, surface).profile, profile);
      }
    }
  });
}

LayoutDefinition _fixtureDefinition(
  LayoutProfileDescriptor descriptor,
  SemanticDestinationCatalog destinationCatalog,
) => LayoutDefinition([
  for (final surface in LayoutRuntimeSurface.values)
    buildFixtureSurfaceBundle(
      descriptor: descriptor,
      surface: surface,
      destinationCatalog: destinationCatalog,
    ),
]);

Matcher _throwsFormat(String message) => throwsA(
  isA<FormatException>().having((error) => error.message, 'message', message),
);
