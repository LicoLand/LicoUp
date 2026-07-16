import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_summary_widgets.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_wave_overview.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

export 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_wave_overview.dart';

class AgentUsageCharts extends StatefulWidget {
  const AgentUsageCharts({
    super.key,
    required this.report,
    required this.detectedAgentIds,
  });

  final AgentUsageReport? report;
  final Set<String> detectedAgentIds;

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
    final timeline = buildAgentUsageTimelineData(
      report,
      _grouping,
      widget.detectedAgentIds,
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
        ),
        const SizedBox(height: 16),
        Builder(
          builder: (context) => _buildShareSection(
            context,
            agents: agents,
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
    required List<AgentUsageAgentSummary> agents,
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
        for (final agent in agents.take(8))
          AgentUsageBarData(
            label: agentUsageAgentDisplayName(agent),
            value: formatAgentUsageNumber(agent.totalTokens),
            trailing: formatAgentUsagePercent(agent.totalTokens, totalTokens),
            fraction: agentUsageShareFraction(agent.totalTokens, totalTokens),
            accent: agentUsageSeriesColor(
              colors,
              agentUsageAgentDisplayName(agent),
            ),
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
      title: strings.tokenUsage,
      valueHeader: strings.tokenConsumption,
      rows: [
        if (detailRows.isNotEmpty)
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
