import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/layout/layout_catalog.dart';
import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_component_kit.dart';
import 'package:flutter_client/src/frontend/layout/layout_definition.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
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

const fixtureLayoutPalette = LayoutPalette(
  background: Color(0xFFF8FAFC),
  surface: Color(0xFFFFFFFF),
  surfaceLow: Color(0xFFF1F5F9),
  surfaceHigh: Color(0xFFDBEAFE),
  surfaceHighest: Color(0xFFBFDBFE),
  line: Color(0xFFCBD5E1),
  text: Color(0xFF0F172A),
  textMuted: Color(0xFF475569),
  primary: Color(0xFF2563EB),
  primaryStrong: Color(0xFF1D4ED8),
  primaryFixed: Color(0xFFDBEAFE),
  textOnPrimary: Color(0xFFFFFFFF),
  info: Color(0xFF0E7490),
  infoMuted: Color(0xFFCFFAFE),
  success: Color(0xFF15803D),
  warning: Color(0xFFB45309),
  error: Color(0xFFB91C1C),
);

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

FixtureLayoutRuntime buildFixtureLayoutRuntime({
  FixtureBuildTracker? tracker,
  ValueChanged<LayoutShellBuildContext>? onShellBuild,
  Iterable<LayoutProfileDescriptor>? profiles,
}) {
  final destinationCatalog = SemanticDestinationCatalog.current();
  final descriptors = (profiles ?? fixtureLayoutDescriptors()).toList(
    growable: false,
  );
  final bundles = [
    for (final descriptor in descriptors)
      for (final surface in LayoutRuntimeSurface.values)
        buildFixtureSurfaceBundle(
          descriptor: descriptor,
          surface: surface,
          destinationCatalog: destinationCatalog,
          tracker: tracker,
          onShellBuild: onShellBuild,
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
    id: LayoutProfileId.parse('workbench'),
    label: LayoutProfileCopy(english: 'Workbench', chinese: '工作台'),
    description: LayoutProfileCopy(
      english: 'Workbench fixture',
      chinese: '工作台夹具',
    ),
    styleIdentity: 'spacious-card-workbench',
    isDefault: true,
  ),
  LayoutProfileDescriptor(
    id: LayoutProfileId.parse('native'),
    label: LayoutProfileCopy(english: 'Native', chinese: '原生'),
    description: LayoutProfileCopy(english: 'Native fixture', chinese: '原生夹具'),
    styleIdentity: 'glassy-rail-native',
    isDefault: false,
  ),
];

LayoutSurfaceBundle buildFixtureSurfaceBundle({
  required LayoutProfileDescriptor descriptor,
  required LayoutRuntimeSurface surface,
  required SemanticDestinationCatalog destinationCatalog,
  FixtureBuildTracker? tracker,
  ValueChanged<LayoutShellBuildContext>? onShellBuild,
  Set<ClientSection>? destinationOverride,
}) {
  final destinations =
      destinationOverride ?? destinationCatalog.destinationsFor(surface);
  final stateNamespace = LayoutStateNamespace(
    profileId: descriptor.id,
    surface: surface,
    destination: ClientSection.agents,
    channel: const LayoutStateChannel(
      'fixture-scroll',
      LayoutStateValueKind.scroll,
    ),
  );
  final tokens = descriptor.id == LayoutProfileId.parse('workbench')
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
            onShellBuild?.call(data);
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
