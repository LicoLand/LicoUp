import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/projects/projects_layout.dart';

/// Owns the local arrangement of the project surfaces.
///
/// This owner holds no gateway, no plan document and no command: the only state
/// it can change is where this client draws a card and in which order it lists
/// one. That is the class-level half of the boundary — a drag reaches this
/// owner and stops here, and durable state has no method on it.
class ProjectLayoutController extends ApplicationStateOwner
    implements ProjectLayoutMutations {
  ProjectsLayoutState _layout = ProjectsLayoutState();

  /// The current local arrangement.
  ProjectsLayoutState get layout => _layout;

  @override
  void moveCard({
    required String projectId,
    required String workItemId,
    required double x,
    required double y,
  }) {
    if (applicationStateDisposed) return;
    final next = _layout.moved(
      projectId: projectId,
      workItemId: workItemId,
      x: x,
      y: y,
    );
    if (next == _layout) return;
    _layout = next;
    publishChange();
  }

  @override
  void reorder(Iterable<String> keys) {
    if (applicationStateDisposed) return;
    final next = _layout.reordered(keys);
    if (next == _layout) return;
    _layout = next;
    publishChange();
  }

  @override
  void dispose() {
    if (applicationStateDisposed) return;
    _layout = ProjectsLayoutState();
    super.dispose();
  }
}
