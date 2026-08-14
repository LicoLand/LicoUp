import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

Future<void> showAdaptiveFlywheelWorkflowDiagram(
  BuildContext context,
  AdaptiveFlywheelInspection inspection,
) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: context.licoColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 660),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
              child: Row(
                children: [
                  const Icon(Icons.account_tree_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      zh ? '工作流程' : 'Workflow',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('adaptive-flywheel-workflow-close'),
                    tooltip: zh ? '关闭' : 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: context.licoColors.line),
            Expanded(
              child: AdaptiveFlywheelWorkflowDiagram(inspection: inspection),
            ),
          ],
        ),
      ),
    ),
  );
}

final class AdaptiveFlywheelWorkflowDiagram extends StatelessWidget {
  const AdaptiveFlywheelWorkflowDiagram({super.key, required this.inspection});

  final AdaptiveFlywheelInspection inspection;

  @override
  Widget build(BuildContext context) {
    final layout = _WorkflowLayout.build(
      states: inspection.states,
      edges: inspection.edges,
      initialState: inspection.initialState,
    );
    final colors = context.licoColors;
    return ColoredBox(
      color: colors.surfaceLow,
      child: InteractiveViewer(
        key: const Key('adaptive-flywheel-workflow-diagram'),
        constrained: false,
        boundaryMargin: const EdgeInsets.all(80),
        minScale: 0.45,
        maxScale: 2.2,
        child: SizedBox(
          width: layout.size.width,
          height: layout.size.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _WorkflowEdgePainter(
                    edges: inspection.edges,
                    positions: layout.positions,
                    lineColor: colors.textMuted,
                    labelColor: colors.textSecondary,
                    activeColor: colors.accent,
                    activeStates: inspection.currentStates.toSet(),
                  ),
                ),
              ),
              for (final state in inspection.states)
                if (layout.positions[state.id] case final position?)
                  Positioned(
                    key: ValueKey('workflow-node-${state.id}'),
                    left: position.dx,
                    top: position.dy,
                    width: _WorkflowLayout.nodeWidth,
                    height: _WorkflowLayout.nodeHeight,
                    child: _WorkflowNode(
                      state: state,
                      initial: state.id == inspection.initialState,
                      active: inspection.currentStates.contains(state.id),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _WorkflowNode extends StatelessWidget {
  const _WorkflowNode({
    required this.state,
    required this.initial,
    required this.active,
  });

  final AdaptiveFlywheelGraphState state;
  final bool initial;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? colors.accentSurface : colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? colors.accent : colors.line,
          width: active ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              state.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.text,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              initial ? '● ${state.kind}' : state.kind,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textMuted, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

final class _WorkflowLayout {
  const _WorkflowLayout({required this.positions, required this.size});

  static const double nodeWidth = 184;
  static const double nodeHeight = 78;
  static const double horizontalGap = 82;
  static const double verticalGap = 34;
  static const double margin = 42;

  final Map<String, Offset> positions;
  final Size size;

  static _WorkflowLayout build({
    required List<AdaptiveFlywheelGraphState> states,
    required List<AdaptiveFlywheelGraphEdge> edges,
    required String initialState,
  }) {
    if (states.isEmpty) {
      return const _WorkflowLayout(positions: {}, size: Size(480, 240));
    }
    final ids = states.map((state) => state.id).toSet();
    final outgoing = <String, List<String>>{
      for (final id in ids) id: <String>[],
    };
    for (final edge in edges) {
      if (ids.contains(edge.from) && ids.contains(edge.to)) {
        outgoing[edge.from]!.add(edge.to);
      }
    }
    final root = ids.contains(initialState) ? initialState : states.first.id;
    final ranks = <String, int>{root: 0};
    final queue = Queue<String>()..add(root);
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      final nextRank = ranks[current]! + 1;
      for (final next in outgoing[current]!) {
        if (ranks.containsKey(next)) continue;
        ranks[next] = nextRank;
        queue.add(next);
      }
    }
    var fallbackRank = ranks.values.fold(0, math.max) + 1;
    for (final state in states) {
      ranks.putIfAbsent(state.id, () => fallbackRank++);
    }
    final columns = SplayTreeMap<int, List<String>>();
    for (final state in states) {
      columns.putIfAbsent(ranks[state.id]!, () => []).add(state.id);
    }
    final maxRows = columns.values.fold<int>(
      1,
      (value, ids) => math.max(value, ids.length),
    );
    final contentHeight = maxRows * nodeHeight + (maxRows - 1) * verticalGap;
    final positions = <String, Offset>{};
    var columnIndex = 0;
    for (final ids in columns.values) {
      final columnHeight =
          ids.length * nodeHeight + (ids.length - 1) * verticalGap;
      final top = margin + (contentHeight - columnHeight) / 2;
      for (var row = 0; row < ids.length; row++) {
        positions[ids[row]] = Offset(
          margin + columnIndex * (nodeWidth + horizontalGap),
          top + row * (nodeHeight + verticalGap),
        );
      }
      columnIndex++;
    }
    return _WorkflowLayout(
      positions: Map.unmodifiable(positions),
      size: Size(
        margin * 2 +
            columns.length * nodeWidth +
            (columns.length - 1) * horizontalGap,
        margin * 2 + contentHeight,
      ),
    );
  }
}

final class _WorkflowEdgePainter extends CustomPainter {
  const _WorkflowEdgePainter({
    required this.edges,
    required this.positions,
    required this.lineColor,
    required this.labelColor,
    required this.activeColor,
    required this.activeStates,
  });

  final List<AdaptiveFlywheelGraphEdge> edges;
  final Map<String, Offset> positions;
  final Color lineColor;
  final Color labelColor;
  final Color activeColor;
  final Set<String> activeStates;

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in edges) {
      final from = positions[edge.from];
      final to = positions[edge.to];
      if (from == null || to == null) continue;
      final active = activeStates.contains(edge.from);
      final paint = Paint()
        ..color = active ? activeColor : lineColor.withAlpha(150)
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 2.2 : 1.4;
      final start = Offset(
        from.dx + _WorkflowLayout.nodeWidth,
        from.dy + _WorkflowLayout.nodeHeight / 2,
      );
      final end = Offset(to.dx, to.dy + _WorkflowLayout.nodeHeight / 2);
      final path = Path()..moveTo(start.dx, start.dy);
      late final Offset labelAnchor;
      if (edge.from == edge.to) {
        final loopTop = start.dy - _WorkflowLayout.nodeHeight;
        labelAnchor = Offset(from.dx + _WorkflowLayout.nodeWidth / 2, loopTop);
        path.cubicTo(
          start.dx + 54,
          start.dy,
          start.dx + 54,
          loopTop,
          start.dx - _WorkflowLayout.nodeWidth / 2,
          loopTop,
        );
        path.cubicTo(
          from.dx - 26,
          loopTop,
          from.dx - 26,
          end.dy,
          end.dx,
          end.dy,
        );
      } else if (end.dx > start.dx) {
        labelAnchor = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
        final bend = math.max(36, (end.dx - start.dx) * 0.46);
        path.cubicTo(
          start.dx + bend,
          start.dy,
          end.dx - bend,
          end.dy,
          end.dx,
          end.dy,
        );
      } else {
        final routeY = math.min(start.dy, end.dy) - 30;
        labelAnchor = Offset((start.dx + end.dx) / 2, routeY);
        path.cubicTo(
          start.dx + 38,
          start.dy,
          start.dx + 38,
          routeY,
          start.dx,
          routeY,
        );
        path.lineTo(end.dx - 38, routeY);
        path.cubicTo(end.dx - 14, routeY, end.dx - 14, end.dy, end.dx, end.dy);
      }
      canvas.drawPath(path, paint);
      _drawArrow(canvas, end, paint);
      _drawEventLabel(canvas, edge.event, labelAnchor);
    }
  }

  void _drawEventLabel(Canvas canvas, String event, Offset anchor) {
    if (event.trim().isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: event,
        style: TextStyle(
          color: labelColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 120);
    painter.paint(
      canvas,
      Offset(anchor.dx - painter.width / 2, anchor.dy - painter.height - 4),
    );
  }

  void _drawArrow(Canvas canvas, Offset end, Paint paint) {
    final arrow = Path()
      ..moveTo(end.dx, end.dy)
      ..lineTo(end.dx - 9, end.dy - 5)
      ..moveTo(end.dx, end.dy)
      ..lineTo(end.dx - 9, end.dy + 5);
    canvas.drawPath(arrow, paint);
  }

  @override
  bool shouldRepaint(covariant _WorkflowEdgePainter oldDelegate) {
    return oldDelegate.edges != edges ||
        oldDelegate.positions != positions ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.labelColor != labelColor ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.activeStates != activeStates;
  }
}
