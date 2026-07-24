import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// The single segmented-control recipe for the Token usage surface: one
/// connected capsule of segments with hairline dividers, a quiet hover
/// lift, and the brand accent reserved for the active segment. The window
/// picker and the grouping switch share this so the page speaks one
/// control language.
final class AgentUsageSegmentedTrack extends StatelessWidget {
  const AgentUsageSegmentedTrack({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: colors.isDark
            ? Colors.white.withAlpha(8)
            : Colors.black.withAlpha(10),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: colors.line.withAlpha(70), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            children[index],
            if (index < children.length - 1)
              Container(
                width: 0.5,
                height: 16,
                color: colors.line.withAlpha(90),
              ),
          ],
        ],
      ),
    );
  }
}

/// One segment inside an [AgentUsageSegmentedTrack].
final class AgentUsageSegment extends StatefulWidget {
  const AgentUsageSegment({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<AgentUsageSegment> createState() => _AgentUsageSegmentState();
}

final class _AgentUsageSegmentState extends State<AgentUsageSegment> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.primary.withAlpha(colors.isDark ? 44 : 30)
                : _hovered && enabled
                ? (colors.isDark
                      ? Colors.white.withAlpha(8)
                      : Colors.black.withAlpha(8))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            style: TextStyle(
              color: widget.selected ? colors.primary : colors.textMuted,
              fontSize: 12.5,
              fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
