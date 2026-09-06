import 'package:licoup/src/presentation/layout/layout_catalog.dart';
import 'package:licoup/src/presentation/layout/semantic_destination_catalog.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/layout_variant.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

const fixtureCatalogRevision = 1;

List<LayoutProfileDescriptor> fixtureProfiles({
  bool dashboardDefault = true,
  bool nativeDefault = false,
  int dashboardRevision = fixtureCatalogRevision,
  int nativeRevision = fixtureCatalogRevision,
}) => [
  LayoutProfileDescriptor(
    id: LayoutProfileId.parse('dashboard'),
    label: LayoutProfileCopy(english: 'Dashboard', chinese: '工作台'),
    description: LayoutProfileCopy(
      english: 'Dashboard fixture',
      chinese: '工作台夹具',
    ),
    styleIdentity: 'spacious-card-dashboard',
    isDefault: dashboardDefault,
    revision: dashboardRevision,
  ),
  LayoutProfileDescriptor(
    id: LayoutProfileId.parse('atlas'),
    label: LayoutProfileCopy(english: 'Atlas', chinese: '图集'),
    description: LayoutProfileCopy(english: 'Atlas fixture', chinese: '图集夹具'),
    styleIdentity: 'glassy-rail-atlas',
    isDefault: nativeDefault,
    revision: nativeRevision,
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
    profileId: LayoutProfileId.parse('dashboard'),
    surface: LayoutRuntimeSurface.desktop,
    destination: ClientSection.agents,
    channel: const LayoutStateChannel(
      'conversation-scroll',
      LayoutStateValueKind.scroll,
    ),
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('dashboard'),
    surface: LayoutRuntimeSurface.mobile,
    destination: ClientSection.agents,
    channel: const LayoutStateChannel(
      'composer-focus',
      LayoutStateValueKind.expansion,
    ),
  ),
  LayoutStateNamespace(
    profileId: LayoutProfileId.parse('atlas'),
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
