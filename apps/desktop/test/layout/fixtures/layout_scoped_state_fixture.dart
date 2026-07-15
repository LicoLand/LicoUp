import 'package:flutter_client/src/application/features/layout/layout_catalog.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/application/features/navigation/semantic_destination_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/layout_variant.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';

/// Builds bounded presentation state for an isolated renderer test without
/// importing a built-in profile or production composition root.
LayoutScopedState buildLayoutScopedStateFixture({
  required LayoutProfileDescriptor profile,
  required LayoutRuntimeSurface surface,
  required Iterable<LayoutStateNamespace> stateNamespaces,
  ClientSection destination = ClientSection.agents,
}) {
  final destinationCatalog = SemanticDestinationCatalog.current();
  final fixtureProfile = LayoutProfileDescriptor(
    id: profile.id,
    label: profile.label,
    description: profile.description,
    styleIdentity: profile.styleIdentity,
    isDefault: true,
    revision: profile.revision,
  );
  final catalog = LayoutCatalog(
    revision: fixtureProfile.revision,
    profiles: [fixtureProfile],
    variants: [
      for (final runtimeSurface in LayoutRuntimeSurface.values)
        for (final viewport in LayoutViewportPolicy.supportedFor(
          runtimeSurface,
        ))
          LayoutVariantCoverage(
            key: LayoutVariantKey(
              profileId: fixtureProfile.id,
              surface: runtimeSurface,
              viewport: viewport,
            ),
            destinations: destinationCatalog.destinationsFor(runtimeSurface),
          ),
    ],
    destinationCatalog: destinationCatalog,
    stateNamespaces: stateNamespaces,
  );
  return LayoutScopedState(
    profileId: fixtureProfile.id,
    surface: surface,
    destination: destination,
    store: LayoutStateStore(catalog),
  );
}
