import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';

/// Number of columns the default canvas arrangement uses.
const projectsCanvasColumns = 3;

/// Horizontal step between two default canvas columns.
const projectsCanvasColumnStep = 260.0;

/// Vertical step between two default canvas rows.
const projectsCanvasRowStep = 168.0;

/// One local canvas position of one work item.
///
/// The value belongs to the local arrangement only. It is never sent to a
/// command, and no durable value in this feature carries a coordinate.
final class ProjectCanvasPlacement {
  const ProjectCanvasPlacement({
    required this.projectId,
    required this.workItemId,
    required this.x,
    required this.y,
    this.movedByUser = false,
  });

  /// The deterministic default position of the [index]-th work item.
  factory ProjectCanvasPlacement.defaultAt({
    required String projectId,
    required String workItemId,
    required int index,
  }) => ProjectCanvasPlacement(
    projectId: projectId,
    workItemId: workItemId,
    x: (index % projectsCanvasColumns) * projectsCanvasColumnStep,
    y: (index ~/ projectsCanvasColumns) * projectsCanvasRowStep,
  );

  final String projectId;
  final String workItemId;
  final double x;
  final double y;

  /// True when a person moved this card, false for a derived default.
  final bool movedByUser;

  String get key => projectWorkItemKey(projectId, workItemId);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectCanvasPlacement &&
          other.projectId == projectId &&
          other.workItemId == workItemId &&
          other.x == x &&
          other.y == y &&
          other.movedByUser == movedByUser;

  @override
  int get hashCode => Object.hash(projectId, workItemId, x, y, movedByUser);
}

/// The local arrangement of the project surfaces.
///
/// A canvas position and a list order are view state: they say where this
/// client draws a card and in which order it lists one, and nothing about the
/// work. The value deliberately holds no gateway, no plan document and no
/// command: a drag applied here cannot reach durable state, and a durable
/// refresh cannot change it.
final class ProjectsLayoutState {
  ProjectsLayoutState({
    Iterable<String> listOrder = const <String>[],
    Iterable<ProjectCanvasPlacement> canvasPlacements =
        const <ProjectCanvasPlacement>[],
  }) : listOrder = List<String>.unmodifiable(listOrder),
       canvasPlacements = List<ProjectCanvasPlacement>.unmodifiable(
         canvasPlacements,
       );

  /// The work-item keys a person ordered, most significant first.
  final List<String> listOrder;

  /// The canvas positions a person set, in the order they were set.
  final List<ProjectCanvasPlacement> canvasPlacements;

  ProjectCanvasPlacement? placementOf(String key) {
    for (final placement in canvasPlacements) {
      if (placement.key == key) return placement;
    }
    return null;
  }

  /// This arrangement with one card moved to a new local position.
  ProjectsLayoutState moved({
    required String projectId,
    required String workItemId,
    required double x,
    required double y,
  }) {
    final moved = ProjectCanvasPlacement(
      projectId: projectId,
      workItemId: workItemId,
      x: x,
      y: y,
      movedByUser: true,
    );
    return ProjectsLayoutState(
      listOrder: listOrder,
      canvasPlacements: <ProjectCanvasPlacement>[
        for (final placement in canvasPlacements)
          if (placement.key != moved.key) placement,
        moved,
      ],
    );
  }

  /// This arrangement with the given order applied to the keys it names.
  ///
  /// Keys the caller does not name keep their relative order after the named
  /// ones, so a key observed after the reorder still lands somewhere defined.
  ProjectsLayoutState reordered(Iterable<String> keys) {
    final named = <String>[];
    final seen = <String>{};
    for (final key in keys) {
      final normalized = key.trim();
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      named.add(normalized);
    }
    return ProjectsLayoutState(
      listOrder: <String>[
        ...named,
        for (final key in listOrder)
          if (!seen.contains(key)) key,
      ],
      canvasPlacements: canvasPlacements,
    );
  }

  /// [canonicalKeys] in the local order: the keys a person ordered first, then
  /// the rest in the canonical order the durable facts were read in.
  List<String> orderedKeys(Iterable<String> canonicalKeys) {
    final available = <String>{...canonicalKeys};
    final ordered = <String>[];
    for (final key in listOrder) {
      if (available.remove(key)) ordered.add(key);
    }
    for (final key in canonicalKeys) {
      if (available.remove(key)) ordered.add(key);
    }
    return List<String>.unmodifiable(ordered);
  }

  /// The canvas position of every work item in [canonicalKeys]: the position a
  /// person set where one exists, the deterministic default otherwise.
  ///
  /// The default is derived from the canonical index, so an observed work item
  /// always has a defined place without this state having to be seeded.
  List<ProjectCanvasPlacement> placementsFor({
    required String projectId,
    required Iterable<String> canonicalKeys,
  }) {
    final placements = <ProjectCanvasPlacement>[];
    var index = 0;
    for (final key in canonicalKeys) {
      final moved = placementOf(key);
      placements.add(
        moved != null && moved.projectId == projectId
            ? moved
            : ProjectCanvasPlacement.defaultAt(
                projectId: projectId,
                workItemId: _workItemIdOf(key),
                index: index,
              ),
      );
      index += 1;
    }
    return List<ProjectCanvasPlacement>.unmodifiable(placements);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectsLayoutState &&
          samePresentationList(other.listOrder, listOrder) &&
          samePresentationList(other.canvasPlacements, canvasPlacements);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(listOrder), Object.hashAll(canvasPlacements));
}

/// One local arrangement request, as a renderer issues it.
///
/// This hierarchy is deliberately not `ProjectsIntent`: a drag expresses a
/// local position, and the two hierarchies have no member in common. The only
/// implementation a renderer receives is a [ProjectLayoutMutations].
sealed class ProjectLayoutAction {
  const ProjectLayoutAction();
}

final class MoveProjectCard extends ProjectLayoutAction {
  const MoveProjectCard({
    required this.projectId,
    required this.workItemId,
    required this.x,
    required this.y,
  });

  final String projectId;
  final String workItemId;
  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MoveProjectCard &&
          other.projectId == projectId &&
          other.workItemId == workItemId &&
          other.x == x &&
          other.y == y;

  @override
  int get hashCode => Object.hash(projectId, workItemId, x, y);
}

final class ReorderProjectList extends ProjectLayoutAction {
  ReorderProjectList(Iterable<String> keys)
    : keys = List<String>.unmodifiable(keys);

  final List<String> keys;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReorderProjectList && samePresentationList(other.keys, keys);

  @override
  int get hashCode => Object.hashAll(keys);
}

/// The local arrangement verbs a drag or a view switch may reach.
///
/// The interface is the boundary proof: its verbs take coordinates and keys and
/// nothing else, and it cannot name a plan document, a gateway or an intent. An
/// implementation has no durable surface to reach even if a renderer misuses it.
abstract interface class ProjectLayoutMutations {
  /// Places one card at a local position. Returns nothing: the arrangement is
  /// local state, not a durable effect.
  void moveCard({
    required String projectId,
    required String workItemId,
    required double x,
    required double y,
  });

  /// Applies a local list order to the keys it names.
  void reorder(Iterable<String> keys);
}

String _workItemIdOf(String key) {
  final separator = key.indexOf('/');
  return separator < 0 ? key : key.substring(separator + 1);
}
