import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_summary_widgets.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_wave_overview.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export 'package:licoup/src/frontend/features/agents/ui/agent_usage_wave_overview.dart';

class AgentUsageCharts extends StatefulWidget {
  const AgentUsageCharts({
    super.key,
    required this.report,
    required this.detectedAgentIds,
    required this.windowDays,
    required this.windowBusy,
    required this.onWindowChanged,
  });

  final AgentUsageReport? report;
  final Set<String> detectedAgentIds;
  final int windowDays;
  final bool windowBusy;
  final ValueChanged<int> onWindowChanged;

  @override
  State<AgentUsageCharts> createState() => _AgentUsageChartsState();
}

final class _AgentUsageChartsState extends State<AgentUsageCharts> {
  AgentUsageChartGrouping _grouping = AgentUsageChartGrouping.agent;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final report = widget.report;
    if (report == null) return const AgentUsageEmptyState();

    final agents = [
      for (final agent in report.agents)
        if (shouldShowAgentUsage(agent, widget.detectedAgentIds)) agent,
    ]..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    final totalTokens = agents.fold<int>(
      0,
      (total, agent) => total + agent.totalTokens,
    );
    final sourceTotals = _aggregateSourceTotals(agents);
    final timeline = buildAgentUsageTimelineData(
      report,
      _grouping,
      widget.detectedAgentIds,
      displayDayCount: widget.windowDays,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AgentUsageWaveOverview(
          grouping: _grouping,
          timeline: timeline,
          onGroupingChanged: (grouping) {
            setState(() => _grouping = grouping);
          },
          windowDays: widget.windowDays,
          windowBusy: widget.windowBusy,
          onWindowChanged: widget.onWindowChanged,
        ),
        const SizedBox(height: 16),
        Builder(
          builder: (context) => _buildShareSection(
            context,
            sourceTotals: sourceTotals,
            totalTokens: totalTokens,
            timeline: timeline,
          ),
        ),
        if (report.warnings.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            report.warnings
                .map((warning) => agentUsageWarningLabel(warning, strings))
                .toSet()
                .join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.licoColors.textMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildShareSection(
    BuildContext context, {
    required List<_UsageSourceTotal> sourceTotals,
    required int totalTokens,
    required AgentUsageTimelineData timeline,
  }) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final sectionTotal = switch (_grouping) {
      AgentUsageChartGrouping.agent => totalTokens.toDouble(),
      AgentUsageChartGrouping.model => timeline.groupTotal,
    };
    final detailRows = switch (_grouping) {
      AgentUsageChartGrouping.agent => [
        for (final source in sourceTotals)
          AgentUsageBarData(
            label: source.label,
            value: source.hasUsage
                ? formatAgentUsageNumber(source.totalTokens)
                : strings.unavailable,
            trailing: source.hasUsage
                ? formatAgentUsagePercent(source.totalTokens, totalTokens)
                : '—',
            fraction: agentUsageShareFraction(source.totalTokens, totalTokens),
            accent: agentUsageSeriesColor(colors, source.label),
          ),
      ],
      AgentUsageChartGrouping.model => [
        for (final series in timeline.series)
          AgentUsageBarData(
            label: series.label,
            value: formatAgentUsageNumber(timeline.totalFor(series.label)),
            trailing: formatAgentUsagePercent(
              timeline.totalFor(series.label),
              timeline.groupTotal,
            ),
            fraction: agentUsageShareFraction(
              timeline.totalFor(series.label),
              timeline.groupTotal,
            ),
            accent: agentUsageSeriesColor(colors, series.label),
          ),
      ],
    };
    return AgentUsageBarSection(
      key: const ValueKey('agent-usage-token-share'),
      valueHeader: strings.tokenConsumption,
      rows: [
        if (detailRows.isNotEmpty && sectionTotal > 0)
          AgentUsageBarData(
            label: strings.totalTokens,
            value: formatAgentUsageNumber(sectionTotal),
            trailing: '100%',
            fraction: sectionTotal > 0 ? 1 : 0,
            accent: colors.primary,
          ),
        ...detailRows,
      ],
      emptyLabel: switch (_grouping) {
        AgentUsageChartGrouping.agent => strings.noAgentUsageInLatestReport,
        AgentUsageChartGrouping.model => strings.noModelUsageInLatestReport,
      },
    );
  }
}

List<_UsageSourceTotal> _aggregateSourceTotals(
  List<AgentUsageAgentSummary> agents,
) {
  final totals = <String, _UsageSourceTotal>{};
  for (final agent in agents) {
    final source = agentUsageAgentDisplayName(agent);
    totals
        .putIfAbsent(source, () => _UsageSourceTotal(label: source))
        .add(agent);
  }
  return totals.values.toList()..sort((a, b) {
    final byTokens = b.totalTokens.compareTo(a.totalTokens);
    if (byTokens != 0) return byTokens;
    final byAvailability = b.hasUsage ? 1 : 0;
    final availability = byAvailability.compareTo(a.hasUsage ? 1 : 0);
    return availability != 0 ? availability : a.label.compareTo(b.label);
  });
}

final class _UsageSourceTotal {
  _UsageSourceTotal({required this.label});

  final String label;
  int totalTokens = 0;
  bool hasUsage = false;

  void add(AgentUsageAgentSummary agent) {
    totalTokens += agent.totalTokens;
    hasUsage = hasUsage || agent.totalTokens > 0 || agent.confidence == 'high';
  }
}
