import 'package:riverpod/misc.dart' show Override;

import 'package:licoup/src/presentation/plugin_management/plugin_management_inputs.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_providers.dart';
import 'package:licoup/src/projections/plugin_management/plugin_management_presentation_sources.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

import 'presentation_source_fixture.dart';

/// Synthetic plugin management presentation sources wired as provider
/// overrides for feature widget tests. Region values derive from the existing
/// projection shape so test data setup stays unchanged.
final class PluginManagementPresentationFixture {
  factory PluginManagementPresentationFixture({
    PluginManagementProjection? projection,
  }) {
    return PluginManagementPresentationFixture._(
      projection ??
          PluginManagementProjection(
            plugins: const [],
            workflows: const [],
            phase: PresentationPhase.ready,
          ),
    );
  }

  PluginManagementPresentationFixture._(PluginManagementProjection projection)
    : catalog = PresentationSourceFixture<PluginCatalogInputs>(
        fieldGroup: pluginCatalogFieldGroup,
        initial: pluginCatalogSlice(projection),
      ),
      collaboration = PresentationSourceFixture<PluginCollaborationInputs>(
        fieldGroup: pluginCollaborationFieldGroup,
        initial: pluginCollaborationSlice(projection),
      );

  final PresentationSourceFixture<PluginCatalogInputs> catalog;
  final PresentationSourceFixture<PluginCollaborationInputs> collaboration;

  List<Override> get overrides => <Override>[
    pluginCatalogSourceProvider.overrideWithValue(catalog),
    pluginCollaborationSourceProvider.overrideWithValue(collaboration),
  ];

  void publishCatalog(PluginCatalogInputs inputs) => catalog.publish(inputs);

  void publishCollaboration(PluginCollaborationInputs inputs) =>
      collaboration.publish(inputs);

  /// Republishes the regions derived from one projection value.
  ///
  /// Mirrors the production sources: a region whose slice is unchanged keeps
  /// its installed snapshot, so subscribers of unrelated regions do not
  /// rebuild.
  void publishProjection(PluginManagementProjection projection) {
    final catalogInputs = pluginCatalogSlice(projection);
    if (catalog.value != catalogInputs) catalog.publish(catalogInputs);
    final collaborationInputs = pluginCollaborationSlice(projection);
    if (collaboration.value != collaborationInputs) {
      collaboration.publish(collaborationInputs);
    }
  }

  Future<void> dispose() async {
    await catalog.dispose();
    await collaboration.dispose();
  }
}
