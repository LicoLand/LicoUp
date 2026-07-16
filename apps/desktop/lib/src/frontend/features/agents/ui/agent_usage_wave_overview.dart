import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_chart_controls.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_chart_geometry.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_wave_chart_painter.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

final class AgentUsageWaveOverview extends StatefulWidget {
  const AgentUsageWaveOverview({
    super.key,
    required this.grouping,
    required this.timeline,
    required this.onGroupingChanged,
  });

  final AgentUsageChartGrouping grouping;
  final AgentUsageTimelineData timeline;
  final ValueChanged<AgentUsageChartGrouping> onGroupingChanged;

  @override
  State<AgentUsageWaveOverview> createState() => _AgentUsageWaveOverviewState();
}

final class _AgentUsageWaveOverviewState extends State<AgentUsageWaveOverview> {
  int? _hoveredSnapshotIndex;
  Offset? _hoverGlobalPosition;
  OverlayEntry? _tooltipOverlay;

  @override
  void didUpdateWidget(covariant AgentUsageWaveOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.grouping != widget.grouping ||
        oldWidget.timeline != widget.timeline) {
      _clearHover(rebuild: false);
    }
  }

  @override
  void dispose() {
    _removeTooltipOverlay();
    super.dispose();
  }

  void _handleHover(PointerHoverEvent event, Size size) {
    final index = agentUsageSnapshotIndexAt(
      position: event.localPosition,
      size: size,
      snapshotCount: widget.timeline.snapshots.length,
    );
    if (index == null) {
      _clearHover();
      return;
    }
    final indexChanged = _hoveredSnapshotIndex != index;
    _hoverGlobalPosition = event.position;
    if (indexChanged) setState(() => _hoveredSnapshotIndex = index);
    _showOrUpdateTooltipOverlay();
  }

  void _showOrUpdateTooltipOverlay() {
    if (_hoveredSnapshotIndex == null || _hoverGlobalPosition == null) return;
    if (_tooltipOverlay == null) {
      final overlay = Overlay.of(context);
      _tooltipOverlay = OverlayEntry(builder: _buildTooltipOverlay);
      overlay.insert(_tooltipOverlay!);
    } else {
      _tooltipOverlay!.markNeedsBuild();
    }
  }

  Widget _buildTooltipOverlay(BuildContext context) {
    final index = _hoveredSnapshotIndex;
    final pointer = _hoverGlobalPosition;
    if (index == null ||
        pointer == null ||
        index < 0 ||
        index >= widget.timeline.snapshots.length) {
      return const SizedBox.shrink();
    }
    final screenSize = MediaQuery.sizeOf(context);
    final tooltipWidth = math.min(
      340.0,
      math.max(240.0, screenSize.width - 16),
    );
    final visibleSeriesCount = widget.timeline.series.where((series) {
      return (widget.timeline.snapshots[index].values[series.label] ?? 0) > 0;
    }).length;
    final estimatedHeight = 58.0 + visibleSeriesCount * 26.0;
    final origin = agentUsageTooltipOrigin(
      pointer: pointer,
      screenSize: screenSize,
      tooltipWidth: tooltipWidth,
      estimatedHeight: estimatedHeight,
    );
    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: tooltipWidth,
      child: IgnorePointer(
        child: AgentUsageChartTooltip(
          timeline: widget.timeline,
          snapshot: widget.timeline.snapshots[index],
        ),
      ),
    );
  }

  void _clearHover({bool rebuild = true}) {
    final hadHover = _hoveredSnapshotIndex != null;
    _hoveredSnapshotIndex = null;
    _hoverGlobalPosition = null;
    _removeTooltipOverlay();
    if (rebuild && hadHover && mounted) setState(() {});
  }

  void _removeTooltipOverlay() {
    _tooltipOverlay?.remove();
    _tooltipOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final emptyLabel = !widget.timeline.hasDailyBreakdown
        ? strings.dailyUsageBreakdownUnavailable
        : widget.grouping == AgentUsageChartGrouping.model
        ? strings.noModelUsageInLatestDailyBreakdown
        : strings.noAgentUsageInLatestDailyBreakdown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      strings.usageOverTime,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    strings.lastDays(agentUsageTimelineDayCount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            AgentUsageGroupingSwitch(
              grouping: widget.grouping,
              onChanged: widget.onGroupingChanged,
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (widget.timeline.isEmpty)
          SizedBox(
            height: agentUsageChartHeight,
            child: Center(
              child: Text(
                emptyLabel,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          )
        else ...[
          SizedBox(
            height: agentUsageChartHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return MouseRegion(
                  key: const ValueKey('usage-wave-chart-interaction'),
                  cursor: SystemMouseCursors.precise,
                  onHover: (event) => _handleHover(event, size),
                  onExit: (_) => _clearHover(),
                  child: CustomPaint(
                    size: size,
                    painter: AgentUsageWaveChartPainter(
                      timeline: widget.timeline,
                      colors: colors,
                      hoveredSnapshotIndex: _hoveredSnapshotIndex,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          AgentUsageChartLegend(timeline: widget.timeline),
        ],
      ],
    );
  }
}
