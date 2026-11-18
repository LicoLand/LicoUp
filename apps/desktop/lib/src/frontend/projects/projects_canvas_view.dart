import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/projects/project_work_item_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/projects/projects_view.dart';

/// Width of one canvas node.
const double projectsCanvasNodeWidth = 232;

/// Height of one canvas node.
const double projectsCanvasNodeHeight = 168;

/// Places one card at a local canvas position.
typedef ProjectCardMover =
    void Function({
      required String projectId,
      required String workItemId,
      required double x,
      required double y,
    });

/// The graph view of one project's work items.
///
/// The view renders [ProjectsCanvasViewInputs] and receives one way to move a
/// card: [onMoveCard], which the surface wires to the local arrangement alone.
/// The widget holds no gateway, no controller and no intent sink, so a drag
/// here cannot name a command. Every fact it draws comes from
/// [ProjectsCanvasViewInputs.facts], the identical list the list view reads.
final class ProjectsCanvasView extends StatelessWidget {
  const ProjectsCanvasView({
    super.key,
    required this.inputs,
    required this.selectedKey,
    required this.onSelect,
    required this.onMoveCard,
  });

  final ProjectsCanvasViewInputs inputs;
  final String selectedKey;
  final ValueChanged<String> onSelect;
  final ProjectCardMover onMoveCard;

  @override
  Widget build(BuildContext context) {
    final nodes = inputs.nodes;
    if (nodes.isEmpty) {
      return const LicoEmptyState(
        icon: Icons.account_tree_outlined,
        title: 'No declared work',
        message:
            'This project holds no work item this client read. Declared work '
            'arrives only through a caller-converted plan document.',
      );
    }
    final width = nodes.fold<double>(0, (extent, node) {
      final right = node.placement.x + projectsCanvasNodeWidth;
      return right > extent ? right : extent;
    });
    final height = nodes.fold<double>(0, (extent, node) {
      final bottom = node.placement.y + projectsCanvasNodeHeight;
      return bottom > extent ? bottom : extent;
    });
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width + 24,
          height: height + 24,
          child: Stack(
            key: const Key('projects-canvas'),
            children: <Widget>[
              for (final node in nodes)
                Positioned(
                  left: node.placement.x,
                  top: node.placement.y,
                  width: projectsCanvasNodeWidth,
                  height: projectsCanvasNodeHeight,
                  child: _CanvasNode(
                    node: node,
                    selected: node.key == selectedKey,
                    onSelect: () => onSelect(node.key),
                    onMove: onMoveCard,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _CanvasNode extends StatelessWidget {
  const _CanvasNode({
    required this.node,
    required this.selected,
    required this.onSelect,
    required this.onMove,
  });

  final ProjectCanvasNodeInputs node;
  final bool selected;
  final VoidCallback onSelect;
  final ProjectCardMover onMove;

  @override
  Widget build(BuildContext context) {
    final facts = node.facts;
    final placement = node.placement;
    return RawGestureDetector(
      key: Key('project-canvas-node-${facts.workItemId}'),
      // A card is dragged with an immediate multi-drag recognizer, so the
      // gesture is claimed as soon as the pointer leaves the slop: a pan that
      // waited for the larger pan slop would lose the arena to the canvas
      // scroll view, and scrolling a canvas would move the arrangement's
      // viewport instead of a card.
      //
      // Nothing durable is reachable from here: the callback this recognizer
      // reaches takes a coordinate and writes the local arrangement, and the
      // surface it belongs to holds no intent sink.
      gestures: <Type, GestureRecognizerFactory<GestureRecognizer>>{
        ImmediateMultiDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              ImmediateMultiDragGestureRecognizer
            >(ImmediateMultiDragGestureRecognizer.new, (recognizer) {
              recognizer.onStart = (position) {
                var x = placement.x;
                var y = placement.y;
                return _CardDrag((delta) {
                  x += delta.dx;
                  y += delta.dy;
                  onMove(
                    projectId: facts.projectId,
                    workItemId: facts.workItemId,
                    x: x,
                    y: y,
                  );
                });
              };
            }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onSelect,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: _EdgeFact(
                    key: Key('project-canvas-incoming-${facts.workItemId}'),
                    label: 'waits on ${node.incoming.length}',
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _EdgeFact(
                    key: Key('project-canvas-outgoing-${facts.workItemId}'),
                    label: 'blocks ${node.outgoing.length}',
                  ),
                ),
                if (placement.movedByUser) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    'moved',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.licoColors.textMuted,
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Expanded(
              child: ProjectWorkItemCard(
                facts: facts,
                selected: selected,
                onTap: onSelect,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _EdgeFact extends StatelessWidget {
  const _EdgeFact({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: context.licoColors.textMuted,
      fontSize: 10,
      height: 1.2,
    ),
  );
}

/// One card drag: every pointer delta accumulates onto the position the drag
/// started from, so a card follows the pointer even when several moves arrive
/// before the projection republishes.
final class _CardDrag extends Drag {
  _CardDrag(this.onDelta);

  final void Function(Offset delta) onDelta;

  @override
  void update(DragUpdateDetails details) => onDelta(details.delta);
}
