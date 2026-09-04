import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_workflow_layout.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/adaptive_flywheel_projection.dart';

Future<void> showAdaptiveFlywheelWorkflowDiagram(
  BuildContext context,
  AdaptiveFlywheelInspectionProjection inspection,
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

  final AdaptiveFlywheelInspectionProjection inspection;

  @override
  Widget build(BuildContext context) {
    final layout = AdaptiveFlywheelWorkflowLayout.build(
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
                    routes: layout.routes,
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
                    width: AdaptiveFlywheelWorkflowLayout.nodeWidth,
                    height: AdaptiveFlywheelWorkflowLayout.nodeHeight,
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

  final AdaptiveFlywheelGraphStateProjection state;
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

final class _WorkflowEdgePainter extends CustomPainter {
  const _WorkflowEdgePainter({
    required this.routes,
    required this.lineColor,
    required this.labelColor,
    required this.activeColor,
    required this.activeStates,
  });

  final List<AdaptiveFlywheelWorkflowRoute> routes;
  final Color lineColor;
  final Color labelColor;
  final Color activeColor;
  final Set<String> activeStates;

  @override
  void paint(Canvas canvas, Size size) {
    for (final route in routes) {
      if (route.points.length < 2) continue;
      final active = activeStates.contains(route.from);
      final paint = Paint()
        ..color = active ? activeColor : lineColor.withAlpha(150)
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 2.2 : 1.4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final path = Path()..moveTo(route.points.first.dx, route.points.first.dy);
      for (var i = 1; i < route.points.length; i++) {
        path.lineTo(route.points[i].dx, route.points[i].dy);
      }
      canvas.drawPath(path, paint);
      _drawArrow(
        canvas,
        route.points[route.points.length - 2],
        route.points.last,
        paint,
      );
      _drawEventLabel(canvas, route.label, route.labelAnchor);
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
    )..layout(maxWidth: 140);
    painter.paint(
      canvas,
      Offset(anchor.dx - painter.width / 2, anchor.dy - painter.height / 2),
    );
  }

  void _drawArrow(Canvas canvas, Offset from, Offset to, Paint paint) {
    final delta = to - from;
    final distance = delta.distance;
    if (distance < 0.5) return;
    final unit = delta / distance;
    final normal = Offset(-unit.dy, unit.dx);
    final path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(
        to.dx - unit.dx * 9 + normal.dx * 5,
        to.dy - unit.dy * 9 + normal.dy * 5,
      )
      ..moveTo(to.dx, to.dy)
      ..lineTo(
        to.dx - unit.dx * 9 - normal.dx * 5,
        to.dy - unit.dy * 9 - normal.dy * 5,
      );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WorkflowEdgePainter oldDelegate) {
    return oldDelegate.routes != routes ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.labelColor != labelColor ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.activeStates != activeStates;
  }
}
