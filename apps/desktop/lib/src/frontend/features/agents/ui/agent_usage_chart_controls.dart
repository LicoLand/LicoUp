import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_segmented_control.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class AgentUsageChartTooltip extends StatelessWidget {
  const AgentUsageChartTooltip({
    super.key,
    required this.timeline,
    required this.snapshot,
    this.semanticLabel,
  });

  final AgentUsageTimelineData timeline;
  final AgentUsageSnapshot snapshot;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final visibleSeries = [
      for (final series in timeline.series)
        if ((snapshot.values[series.label] ?? 0) > 0) series,
    ];
    final borderRadius = BorderRadius.circular(14);
    final neutralGlassTint = colors.isDark
        ? const Color(0xFF17191C)
        : const Color(0xFFE5E7EB);
    return Semantics(
      container: true,
      label:
          semanticLabel ??
          strings.dailyTokenUsage(agentUsageDateKey(snapshot.time)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: colors.isDark ? 0.42 : 0.18,
              ),
              blurRadius: 28,
              spreadRadius: -4,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: AppleGlassSurface(
          key: const ValueKey('usage-wave-tooltip'),
          borderRadius: borderRadius,
          blurSigma: 24,
          fillAlpha: colors.isDark ? 12 : 18,
          borderAlpha: colors.isDark ? 54 : 84,
          child: ColoredBox(
            key: const ValueKey('usage-wave-tooltip-glass-fill'),
            color: neutralGlassTint.withValues(
              alpha: colors.isDark ? 0.72 : 0.84,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          agentUsageDateKey(snapshot.time),
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        formatAgentUsageTooltipNumber(snapshot.total),
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  for (final series in visibleSeries) ...[
                    Row(
                      key: ValueKey('usage-wave-tooltip-row-${series.label}'),
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: agentUsageSeriesColor(colors, series.label),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            series.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          formatAgentUsageTooltipNumber(
                            snapshot.values[series.label] ?? 0,
                          ),
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    if (series != visibleSeries.last) const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class AgentUsageGroupingSwitch extends StatelessWidget {
  const AgentUsageGroupingSwitch({
    super.key,
    required this.grouping,
    required this.onChanged,
  });

  final AgentUsageChartGrouping grouping;
  final ValueChanged<AgentUsageChartGrouping> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return AgentUsageSegmentedTrack(
      children: [
        AgentUsageSegment(
          key: const Key('agent-usage-grouping-agent'),
          label: strings.byAgent,
          selected: grouping == AgentUsageChartGrouping.agent,
          onTap: grouping == AgentUsageChartGrouping.agent
              ? null
              : () => onChanged(AgentUsageChartGrouping.agent),
        ),
        AgentUsageSegment(
          key: const Key('agent-usage-grouping-model'),
          label: strings.byModel,
          selected: grouping == AgentUsageChartGrouping.model,
          onTap: grouping == AgentUsageChartGrouping.model
              ? null
              : () => onChanged(AgentUsageChartGrouping.model),
        ),
        AgentUsageSegment(
          key: const Key('agent-usage-grouping-workflow'),
          label: strings.byWorkflow,
          selected: grouping == AgentUsageChartGrouping.workflow,
          onTap: grouping == AgentUsageChartGrouping.workflow
              ? null
              : () => onChanged(AgentUsageChartGrouping.workflow),
        ),
      ],
    );
  }
}

final class AgentUsageChartLegend extends StatelessWidget {
  const AgentUsageChartLegend({super.key, required this.timeline});

  final AgentUsageTimelineData timeline;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final series in timeline.series)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: agentUsageSeriesColor(colors, series.label),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(
                  series.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                formatAgentUsageNumber(timeline.totalFor(series.label)),
                style: TextStyle(
                  color: colors.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
