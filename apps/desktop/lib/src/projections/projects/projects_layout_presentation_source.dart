import 'package:licoup/src/frontend/binding/projected_presentation_source.dart';
import 'package:licoup/src/presentation/projects/projects_layout.dart';
import 'package:licoup/src/presentation/projects/projects_resources.dart';

/// The local arrangement resource adapter over the layout owner.
///
/// The arrangement is a resource in its own right: it has its own identity,
/// epoch and consistency group, so a drag publishes a change that affects
/// [projectsLayoutFields] only. The durable facts resource is not rewritten by
/// one, and no group in this source can name a durable entry.
final class ProjectsLayoutPresentationSource
    extends
        ProjectedPresentationSource<ProjectsLayoutState, ProjectsLayoutState> {
  ProjectsLayoutPresentationSource({required super.projection})
    : super(fieldGroup: projectsLayoutFields, epochKey: 'projects-arrangement');
}
