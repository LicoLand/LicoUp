import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/projects/projects_layout.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';

/// Stable ownership scope for the project feature presentation resources.
const projectsPresentationScope = ResourceScope('projects');

/// Identity of the durable project facts inside [projectsPresentationScope].
const projectsCatalogResource = ResourceKey(
  scope: projectsPresentationScope,
  stableKey: 'catalog',
);

/// Typed field group carrying the durable project facts snapshot.
const projectsCatalogFields = ResourceFieldGroup<ProjectsProjection>(
  resource: projectsCatalogResource,
  name: 'overview',
);

/// Identity of the local arrangement inside [projectsPresentationScope].
///
/// The arrangement is a second resource on purpose. It has its own consistency
/// group, so a drag publishes a change to the layout resource only: no facts
/// snapshot is rewritten by one, and no command can be reached from it.
const projectsLayoutResource = ResourceKey(
  scope: projectsPresentationScope,
  stableKey: 'arrangement',
);

/// Typed field group carrying the local arrangement snapshot.
const projectsLayoutFields = ResourceFieldGroup<ProjectsLayoutState>(
  resource: projectsLayoutResource,
  name: 'layout',
);
