import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/layout/layout_catalog.dart';
import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_component_kit.dart';
import 'package:flutter_client/src/frontend/layout/layout_definition.dart';
import 'package:flutter_client/src/frontend/layout/layout_registry.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';

final class FixtureBuildTracker {
  final Map<LayoutProfileId, int> shellBuilds = {};
  final Map<LayoutProfileId, int> destinationBuilds = {};

  void recordShell(LayoutProfileId id) {
    shellBuilds[id] = (shellBuilds[id] ?? 0) + 1;
  }

  void recordDestination(LayoutProfileId id) {
    destinationBuilds[id] = (destinationBuilds[id] ?? 0) + 1;
  }
}

final class FixtureLayoutRuntime {
  const FixtureLayoutRuntime({
    required this.catalog,
    required this.registry,
    required this.definitions,
  });

  final LayoutCatalog catalog;
  final LayoutRegistry registry;
  final List<LayoutDefinition> definitions;
}

FixtureLayoutRuntime buildFixtureLayoutRuntime({FixtureBuildTracker? tracker}) {
  final destinationCatalog = SemanticDestinationCatalog.current();
  final descriptors = fixtureLayoutDescriptors();
  final bundles = [
    for (final descriptor in descriptors)
      for (final surface in LayoutRuntimeSurface.values)
        buildFixtureSurfaceBundle(
          descriptor: descriptor,
          surface: surface,
          destinationCatalog: destinationCatalog,
          tracker: tracker,
        ),
  ];
  final definitions = [
    for (final descriptor in descriptors)
      LayoutDefinition(
        bundles.where((bundle) => bundle.profile.id == descriptor.id),
      ),
  ];
  final catalog = LayoutCatalog(
    revision: 1,
    profiles: descriptors,
    variants: bundles.expand((bundle) => bundle.coverage),
    destinationCatalog: destinationCatalog,
    stateNamespaces: bundles.expand((bundle) => bundle.stateNamespaces),
  );
  return FixtureLayoutRuntime(
    catalog: catalog,
    registry: LayoutRegistry(catalog: catalog, definitions: definitions),
    definitions: definitions,
  );
}

List<LayoutProfileDescriptor> fixtureLayoutDescriptors() => [
  LayoutProfileDescriptor(
    id: LayoutProfileId.workbench,
    labelKey: 'layout.profile.workbench.label',
    descriptionKey: 'layout.profile.workbench.description',
    styleIdentity: 'spacious-card-workbench',
    isDefault: true,
  ),
  LayoutProfileDescriptor(
    id: LayoutProfileId.studio,
    labelKey: 'layout.profile.studio.label',
    descriptionKey: 'layout.profile.studio.description',
    styleIdentity: 'dense-docked-studio',
    isDefault: false,
  ),
];

LayoutSurfaceBundle buildFixtureSurfaceBundle({
  required LayoutProfileDescriptor descriptor,
  required LayoutRuntimeSurface surface,
  required SemanticDestinationCatalog destinationCatalog,
  FixtureBuildTracker? tracker,
  Set<ClientSection>? destinationOverride,
}) {
  final destinations =
      destinationOverride ?? destinationCatalog.destinationsFor(surface);
  final stateNamespace = LayoutStateNamespace(
    profileId: descriptor.id,
    surface: surface,
    destination: ClientSection.agents,
    surfaceId: 'fixture-scroll',
  );
  final tokens = descriptor.id == LayoutProfileId.workbench
      ? LayoutVisualTokens(
          spacingUnit: 8,
          density: 1,
          cardRadius: 18,
          elevation: 2,
          navigationExtent: 72,
          contentMaxWidth: 1280,
          typographyScale: 1.08,
          motionDuration: const Duration(milliseconds: 180),
        )
      : LayoutVisualTokens(
          spacingUnit: 4,
          density: 0.78,
          cardRadius: 4,
          elevation: 0,
          navigationExtent: 52,
          contentMaxWidth: 1600,
          typographyScale: 0.96,
          motionDuration: const Duration(milliseconds: 90),
        );
  return LayoutSurfaceBundle(
    profile: descriptor,
    surface: surface,
    variants: {
      for (final viewport in LayoutViewportPolicy.supportedFor(surface))
        viewport: LayoutSurfaceVariant(
          viewport: viewport,
          shellBuilder: (context, data) {
            tracker?.recordShell(descriptor.id);
            final installed = context.layoutVisualTokens;
            return Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                key: Key(
                  'fixture-shell-${descriptor.id.value}-${surface.name}-${viewport.name}',
                ),
                children: [
                  Text(
                    '${descriptor.id.value}:${installed.spacingUnit}:${data.initialFocusTarget}',
                    key: Key('fixture-metadata-${descriptor.id.value}'),
                  ),
                  Expanded(child: data.destination),
                ],
              ),
            );
          },
          destinationBuilders: {
            for (final destination in destinations)
              destination: (context, data) {
                tracker?.recordDestination(descriptor.id);
                return KeyedSubtree(
                  key: Key(
                    'fixture-destination-${descriptor.id.value}-${destination.name}',
                  ),
                  child: data.content.buildDestination(context, destination),
                );
              },
          },
        ),
    },
    previewBuilder: (context) => SizedBox(
      key: Key('fixture-preview-${descriptor.id.value}-${surface.name}'),
    ),
    tokens: tokens,
    components: FixtureComponentKit(descriptor.styleIdentity),
    assetNamespace: 'layout-profiles/${descriptor.id.value}/${surface.name}',
    restorationNamespace: '${descriptor.id.value}.${surface.name}',
    stateNamespaces: {stateNamespace},
  );
}

final class FixtureComponentKit implements LayoutComponentKit {
  const FixtureComponentKit(this.styleIdentity);

  @override
  final String styleIdentity;

  @override
  Widget card(
    BuildContext context, {
    required Key key,
    required Widget child,
    VoidCallback? onPressed,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget dialogSurface(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget fieldFrame(
    BuildContext context, {
    required Key key,
    required Widget child,
    String? semanticLabel,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget navigationItem(
    BuildContext context, {
    required Key key,
    required Widget icon,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) => KeyedSubtree(key: key, child: icon);

  @override
  Widget panel(
    BuildContext context, {
    required Key key,
    required Widget child,
    bool emphasized = false,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget statusSurface(
    BuildContext context, {
    required Key key,
    required Widget child,
    required bool attention,
  }) => KeyedSubtree(key: key, child: child);
}

final class FixtureDestinationContent implements LayoutDestinationContentPort {
  const FixtureDestinationContent();

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) =>
      Center(
        child: Text(
          destination.name,
          key: Key('fixture-content-${destination.name}'),
        ),
      );
}
