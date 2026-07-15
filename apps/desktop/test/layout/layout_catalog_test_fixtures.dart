import 'package:flutter_client/src/application/features/layout/layout_catalog.dart';
import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/layout_variant.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

const fixtureCatalogRevision = 1;

List<LayoutProfileDescriptor> fixtureProfiles({
  bool workbenchDefault = true,
  bool studioDefault = false,
  int workbenchRevision = fixtureCatalogRevision,
  int studioRevision = fixtureCatalogRevision,
}) => [
  LayoutProfileDescriptor(
    id: LayoutProfileId.parse('workbench'),
    label: LayoutProfileCopy(english: 'Workbench', chinese: '工作台'),
    description: LayoutProfileCopy(
      english: 'Workbench fixture',
      chinese: '工作台夹具',
    ),
    styleIdentity: 'spacious-card-workbench',
    isDefault: workbenchDefault,
    revision: workbenchRevision,
  ),
  LayoutProfileDescriptor(
    id: LayoutProfileId.parse('studio'),
    label: LayoutProfileCopy(english: 'Studio', chinese: '原生'),
    description: LayoutProfileCopy(english: 'Studio fixture', chinese: '原生夹具'),
    styleIdentity: 'dense-docked-studio',
    isDefault: studioDefault,
    revision: studioRevision,
  ),
];

List<LayoutVariantCoverage> fixtureVariants({
  Iterable<LayoutProfileDescriptor>? profiles,
  SemanticDestinationCatalog? destinationCatalog,
}) {
  final catalog = destinationCatalog ?? SemanticDestinationCatalog.current();
  final result = <LayoutVariantCoverage>[];
  for (final profile in profiles ?? fixtureProfiles()) {
    for (final surface in LayoutRuntimeSurface.values) {
      for (final viewport in LayoutViewportPolicy.supportedFor(surface)) {
        result.add(
          LayoutVariantCoverage(
            key: LayoutVariantKey(
              profileId: profile.id,
              surface: surface,
              viewport: viewport,
            ),
            destinations: catalog.destinationsFor(surface),
          ),
        );
      }
    }
  }
  return result;
}

List<LayoutStateNamespace> fixtureStateNamespaces() => [
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('workbench'),
    surface: LayoutRuntimeSurface.desktop,
    destination: ClientSection.agents,
    channel: const LayoutStateChannel(
      'conversation-scroll',
      LayoutStateValueKind.scroll,
    ),
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('workbench'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: const LayoutStateChannel(
      'composer-focus',
      LayoutStateValueKind.expansion,
    ),
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('studio'),
    surface: LayoutRuntimeSurface.desktop,
    destination: ClientSection.agents,
    channel: const LayoutStateChannel(
      'conversation-scroll',
      LayoutStateValueKind.scroll,
    ),
  ),
];

LayoutCatalog fixtureLayoutCatalog({
  Iterable<LayoutProfileDescriptor>? profiles,
  Iterable<LayoutVariantCoverage>? variants,
  Iterable<LayoutStateNamespace>? stateNamespaces,
  SemanticDestinationCatalog? destinationCatalog,
  int revision = fixtureCatalogRevision,
}) {
  final semanticCatalog =
      destinationCatalog ?? SemanticDestinationCatalog.current();
  final profileList = (profiles ?? fixtureProfiles()).toList();
  return LayoutCatalog(
    revision: revision,
    profiles: profileList,
    variants:
        variants ??
        fixtureVariants(
          profiles: profileList,
          destinationCatalog: semanticCatalog,
        ),
    destinationCatalog: semanticCatalog,
    stateNamespaces: stateNamespaces ?? fixtureStateNamespaces(),
  );
}
