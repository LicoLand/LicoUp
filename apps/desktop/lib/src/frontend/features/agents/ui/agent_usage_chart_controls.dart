import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_segmented_control.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'agent_usage_hover_card.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class AgentUsageChartTooltip extends AgentUsageHoverCard {
  const AgentUsageChartTooltip({
    super.key,
    required this.timeline,
    required this.snapshot,
    String? semanticLabel,
  }) : _semanticLabel = semanticLabel;

  final AgentUsageTimelineData timeline;
  final AgentUsageSnapshot snapshot;
  final String? _semanticLabel;

  @override
  String get tooltipKeyPrefix => 'usage-wave-tooltip';

  @override
  String headerLabel(BuildContext context) => agentUsageDateKey(snapshot.time);

  @override
  num get totalTokens => snapshot.total;

  @override
  String semanticLabel(BuildContext context) =>
      _semanticLabel ??
      LicoStrings.of(context).dailyTokenUsage(agentUsageDateKey(snapshot.time));

  @override
  List<AgentUsageHoverRow> buildRows(BuildContext context) => [
    for (final series in timeline.series)
      if ((snapshot.values[series.label] ?? 0) > 0)
        AgentUsageHoverRow(
          seriesKey: series.label,
          label: timeline.displayNameFor(series.label),
          totalTokens: snapshot.values[series.label]!,
          color: agentUsageSeriesColor(
            context.licoColors,
            series.label,
            grouping: timeline.grouping,
          ),
        ),
  ];
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
                  color: agentUsageSeriesColor(
                    colors,
                    series.label,
                    grouping: timeline.grouping,
                  ),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(
                  timeline.displayNameFor(series.label),
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
