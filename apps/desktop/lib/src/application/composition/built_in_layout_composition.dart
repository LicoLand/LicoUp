import 'dart:collection';

import 'package:flutter_client/src/application/features/layout/layout_catalog.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/frontend/layout/layout_definition.dart';
import 'package:flutter_client/src/frontend/layout/layout_registry.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/bubble_desktop.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/desktop/classic_desktop.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/studio_desktop.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/workbench_desktop.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_bundle.dart';

/// Application composition root for the immutable built-in layout product.
///
/// This is the only application file allowed to assemble renderer-owned
/// surface bundles. This is the only production composition root allowed to
/// import those bundle entry points.
final class BuiltInLayoutComposition {
  static const int catalogSchemaRevision = 1;

  factory BuiltInLayoutComposition() =>
      BuiltInLayoutComposition.fromDefinitions(<LayoutDefinition>[
        LayoutDefinition([studioDesktopBundle, studioMobileBundle]),
        LayoutDefinition([bubbleDesktopBundle, bubbleMobileBundle]),
        LayoutDefinition([classicDesktopBundle, classicMobileBundle]),
        LayoutDefinition([workbenchDesktopBundle, workbenchMobileBundle]),
      ]);

  /// Builds the immutable layout product from the registered definitions.
  ///
  /// The production constructor above remains the only import join point for
  /// renderer bundles. This named constructor keeps the composition algorithm
  /// independent of the number of registered profiles: [definitions] supplies
  /// `N`, while [LayoutRuntimeSurface.values] supplies `M`.
  factory BuiltInLayoutComposition.fromDefinitions(
    Iterable<LayoutDefinition> definitions,
  ) {
    final definitionList = List<LayoutDefinition>.unmodifiable(definitions);
    if (definitionList.isEmpty) {
      throw const FormatException('layout_composition_definition_missing');
    }

    final profileIds = <LayoutProfileId>{};
    for (final definition in definitionList) {
      if (!profileIds.add(definition.profile.id)) {
        throw const FormatException('layout_composition_profile_duplicate');
      }
    }

    final surfaces = LayoutRuntimeSurface.values;
    final bundles = <LayoutSurfaceBundle>[];
    for (final definition in definitionList) {
      if (definition.bundles.length != surfaces.length) {
        throw const FormatException(
          'layout_composition_surface_product_invalid',
        );
      }
      for (final surface in surfaces) {
        final bundle = definition.bundles[surface];
        if (bundle == null ||
            bundle.surface != surface ||
            bundle.profile != definition.profile) {
          throw const FormatException(
            'layout_composition_surface_product_invalid',
          );
        }
        bundles.add(bundle);
      }
    }
    if (bundles.length != definitionList.length * surfaces.length) {
      throw const FormatException('layout_composition_bundle_product_invalid');
    }

    final catalog = LayoutCatalog(
      revision: catalogSchemaRevision,
      profiles: definitionList.map((definition) => definition.profile),
      variants: bundles.expand((bundle) => bundle.coverage),
      destinationCatalog: SemanticDestinationCatalog.current(),
      stateNamespaces: bundles.expand((bundle) => bundle.stateNamespaces),
    );
    final registry = LayoutRegistry(
      catalog: catalog,
      definitions: definitionList,
    );
    return BuiltInLayoutComposition._(
      definitions: UnmodifiableListView(definitionList),
      catalog: catalog,
      registry: registry,
      stateStore: LayoutStateStore(catalog),
    );
  }

  const BuiltInLayoutComposition._({
    required this.definitions,
    required this.catalog,
    required this.registry,
    required this.stateStore,
  });

  final List<LayoutDefinition> definitions;
  final LayoutCatalog catalog;
  final LayoutRegistry registry;
  final LayoutStateStore stateStore;

  /// Settings consumes this catalog-owned ordering directly; there is no
  /// second profile list or profile-specific branch outside registration.
  List<LayoutProfileDescriptor> get settingsProfiles => catalog.profiles;

  LayoutSurfaceBundle previewBundle(
    LayoutProfileId profileId,
    LayoutRuntimeSurface surface,
  ) => registry.definition(profileId).bundles[surface]!;
}
