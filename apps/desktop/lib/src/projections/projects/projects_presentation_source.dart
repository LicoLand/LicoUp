import 'package:licoup/src/frontend/binding/projected_presentation_source.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';
import 'package:licoup/src/presentation/projects/projects_resources.dart';

/// The project facts resource adapter over the project projection owner.
///
/// The source/subscription lifecycle — epoch identity, monotonic versions, one
/// consistency group per accepted change, subscribe-before-read opening and the
/// observer ref count — belongs to [ProjectedPresentationSource]. This type
/// declares only the resource identity this feature owns, so a drag on the
/// separate arrangement resource can never publish through this one.
final class ProjectsPresentationSource
    extends
        ProjectedPresentationSource<ProjectsProjection, ProjectsProjection> {
  ProjectsPresentationSource({required super.projection})
    : super(fieldGroup: projectsCatalogFields, epochKey: 'projects-catalog');
}
