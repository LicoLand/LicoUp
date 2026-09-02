import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_chart_controls.dart';
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
    this.onExit,
  });

  final AgentUsageReport? report;
  final Set<String> detectedAgentIds;
  final int windowDays;
  final bool windowBusy;
  final ValueChanged<int> onWindowChanged;
  final VoidCallback? onExit;

  @override
  State<AgentUsageCharts> createState() => _AgentUsageChartsState();
}

final class _AgentUsageChartsState extends State<AgentUsageCharts> {
  AgentUsageChartGrouping _grouping = AgentUsageChartGrouping.agent;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final report = widget.report;
    if (report == null) return AgentUsageEmptyState(onExit: widget.onExit);

    final agents = [
      for (final agent in report.agents)
        if (shouldShowAgentUsage(agent, widget.detectedAgentIds)) agent,
    ]..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    final totalTokens = agents.fold<int>(
      0,
      (total, agent) => total + agent.totalTokens,
    );
    final sourceTotals = _aggregateSourceTotals(agents);
    final timelineGrouping = _grouping == AgentUsageChartGrouping.workflow
        ? AgentUsageChartGrouping.agent
        : _grouping;
    final timeline = buildAgentUsageTimelineData(
      report,
      timelineGrouping,
      widget.detectedAgentIds,
      displayDayCount: widget.windowDays,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_grouping == AgentUsageChartGrouping.workflow)
          AgentUsageWorkflowSection(
            workflows: report.workflows,
            summary: report.workflowSummary,
            onGroupingChanged: (grouping) {
              setState(() => _grouping = grouping);
            },
            onExit: widget.onExit,
          )
        else ...[
          AgentUsageWaveOverview(
            grouping: _grouping,
            timeline: timeline,
            onGroupingChanged: (grouping) {
              setState(() => _grouping = grouping);
            },
            windowDays: widget.windowDays,
            windowBusy: widget.windowBusy,
            onWindowChanged: widget.onWindowChanged,
            onExit: widget.onExit,
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
        ],
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
      AgentUsageChartGrouping.workflow => 0,
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
      AgentUsageChartGrouping.workflow => const <AgentUsageBarData>[],
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
        AgentUsageChartGrouping.workflow => strings.noWorkflowUsage,
      },
    );
  }
}

/// The workflow view is deliberately a projection-only peer of the existing
/// Agent and Model timeline. It renders native numeric facts and hierarchy,
/// while every role, state, empty, and disclosure label comes from l10n.
class AgentUsageWorkflowSection extends StatefulWidget {
  const AgentUsageWorkflowSection({
    super.key,
    required this.workflows,
    required this.summary,
    required this.onGroupingChanged,
    this.onExit,
  });

  final List<AgentUsageWorkflow> workflows;
  final AgentUsageTokenTotals summary;
  final ValueChanged<AgentUsageChartGrouping> onGroupingChanged;
  final VoidCallback? onExit;

  @override
  State<AgentUsageWorkflowSection> createState() =>
      _AgentUsageWorkflowSectionState();
}

final class _AgentUsageWorkflowSectionState
    extends State<AgentUsageWorkflowSection> {
  final Set<int> _expandedPlans = <int>{};
  final Set<String> _expandedTasks = <String>{};

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final workflows = [...widget.workflows]
      ..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    final summary = _summaryFor(workflows, widget.summary);
    return Column(
      key: const ValueKey('agent-usage-workflow-view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AgentUsagePanelHeader(
          title: strings.workflowUsage,
          onExit: widget.onExit,
          trailing: [
            AgentUsageGroupingSwitch(
              grouping: AgentUsageChartGrouping.workflow,
              onChanged: widget.onGroupingChanged,
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (workflows.isEmpty)
          Text(
            strings.noWorkflowUsage,
            key: const ValueKey('agent-usage-workflow-empty'),
            style: TextStyle(
              color: context.licoColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          )
        else ...[
          _WorkflowTotalsHeader(
            totals: summary,
            mainTokens: _mainWorkflowTokens(workflows),
            subordinateTokens: _subordinateWorkflowTokens(workflows),
          ),
          const SizedBox(height: 16),
          for (var index = 0; index < workflows.length; index += 1) ...[
            _WorkflowPlanCard(
              key: ValueKey('agent-usage-workflow-plan-$index'),
              workflow: workflows[index],
              expansionPrefix: '$index',
              expanded: _expandedPlans.contains(index),
              expandedTasks: _expandedTasks,
              onPlanToggle: () => setState(() {
                if (!_expandedPlans.add(index)) {
                  _expandedPlans.remove(index);
                  _expandedTasks.removeWhere(
                    (key) => key.startsWith('$index:'),
                  );
                }
              }),
              onTaskToggle: (taskKey) => setState(() {
                final key = '$index:$taskKey';
                if (!_expandedTasks.add(key)) _expandedTasks.remove(key);
              }),
            ),
            if (index < workflows.length - 1) const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }

  AgentUsageTokenTotals _summaryFor(
    List<AgentUsageWorkflow> workflows,
    AgentUsageTokenTotals reported,
  ) {
    if (reported.totalTokens > 0 || reported.promptTokens > 0) {
      return reported;
    }
    return workflows.fold<AgentUsageTokenTotals>(
      const AgentUsageTokenTotals(),
      (total, workflow) => total + workflow.totals,
    );
  }
}

class _WorkflowTotalsHeader extends StatelessWidget {
  const _WorkflowTotalsHeader({
    required this.totals,
    required this.mainTokens,
    required this.subordinateTokens,
  });

  final AgentUsageTokenTotals totals;
  final int mainTokens;
  final int subordinateTokens;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final recordCount = totals.recordCount;
    final coveragePercent = (totals.exactCoverage * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _WorkflowMetric(
              label: strings.workflowTotal,
              value: formatAgentUsageNumber(totals.totalTokens),
              accent: colors.primary,
            ),
            _WorkflowMetric(
              label: strings.workflowCachedInput,
              value: formatAgentUsageNumber(totals.cachedInputTokens),
            ),
            _WorkflowMetric(
              label: strings.workflowExactCoverage,
              value: strings.workflowCoverage(
                totals.exactCount,
                recordCount,
                coveragePercent,
              ),
            ),
            _WorkflowMetric(
              label: strings.workflowMainShare,
              value: formatAgentUsageNumber(mainTokens),
            ),
            _WorkflowMetric(
              label: strings.workflowSubordinateShare,
              value: formatAgentUsageNumber(subordinateTokens),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _WorkflowComponentValue(
              label: strings.workflowPrompt,
              value: formatAgentUsageNumber(totals.promptTokens),
            ),
            const SizedBox(width: 16),
            _WorkflowComponentValue(
              label: strings.workflowCompletion,
              value: formatAgentUsageNumber(totals.completionTokens),
            ),
          ],
        ),
      ],
    );
  }
}

int _mainWorkflowTokens(List<AgentUsageWorkflow> workflows) {
  var total = 0;
  for (final workflow in workflows) {
    for (final root in workflow.roots) {
      if (root.isMain) total += root.usage.totalTokens;
    }
  }
  return total;
}

int _subordinateWorkflowTokens(List<AgentUsageWorkflow> workflows) {
  final all = workflows.fold<int>(
    0,
    (total, workflow) => total + workflow.totalTokens,
  );
  return (all - _mainWorkflowTokens(workflows)).clamp(0, 0x7fffffff);
}

class _WorkflowMetric extends StatelessWidget {
  const _WorkflowMetric({
    required this.label,
    required this.value,
    this.accent,
  });

  final String label;
  final String value;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      constraints: const BoxConstraints(minWidth: 122),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.line.withAlpha(80), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.textMuted, fontSize: 10),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: accent ?? colors.text,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkflowComponentValue extends StatelessWidget {
  const _WorkflowComponentValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: TextStyle(color: colors.textMuted, fontSize: 11),
        ),
        Text(
          value,
          style: TextStyle(
            color: colors.text,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _WorkflowPlanCard extends StatelessWidget {
  const _WorkflowPlanCard({
    super.key,
    required this.workflow,
    required this.expansionPrefix,
    required this.expanded,
    required this.expandedTasks,
    required this.onPlanToggle,
    required this.onTaskToggle,
  });

  final AgentUsageWorkflow workflow;
  final String expansionPrefix;
  final bool expanded;
  final Set<String> expandedTasks;
  final VoidCallback onPlanToggle;
  final ValueChanged<String> onTaskToggle;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final mainNodes = workflow.roots.where((node) => node.isMain).toList();
    final subordinateNodes = [
      for (final root in workflow.roots) ...[
        if (!root.isMain) root,
        ...root.children,
      ],
    ];
    final mainTotal = mainNodes.fold<int>(
      0,
      (total, node) => total + node.usage.totalTokens,
    );
    final subordinateTotal = (workflow.totalTokens - mainTotal).clamp(
      0,
      0x7fffffff,
    );
    final taskGroups = <String, List<AgentUsageWorkflowNode>>{};
    for (final node in subordinateNodes) {
      final task = node.taskLabel.trim().isEmpty
          ? strings.workflowTask
          : node.taskLabel;
      taskGroups.putIfAbsent(task, () => []).add(node);
    }
    final taskEntries = taskGroups.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceLow.withAlpha(colors.isDark ? 90 : 120),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line.withAlpha(80), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _WorkflowDisclosureRow(
            key: const ValueKey('agent-usage-workflow-plan-row'),
            expanded: expanded,
            onTap: onPlanToggle,
            title: strings.workflowPlanLabel(
              workflow.planCode,
              workflow.planRevision,
            ),
            trailing: formatAgentUsageNumber(workflow.totalTokens),
          ),
          if (expanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 11),
              child: Wrap(
                spacing: 12,
                runSpacing: 5,
                children: [
                  Text(
                    '${strings.workflowMainShare}: ${formatAgentUsageNumber(mainTotal)}',
                    style: TextStyle(color: colors.textMuted, fontSize: 11),
                  ),
                  Text(
                    '${strings.workflowSubordinateShare}: ${formatAgentUsageNumber(subordinateTotal)}',
                    style: TextStyle(color: colors.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
            for (final root in mainNodes) _WorkflowMainRow(node: root),
            for (var index = 0; index < taskEntries.length; index += 1)
              _WorkflowTaskGroup(
                taskCode: taskEntries[index].key,
                nodes: taskEntries[index].value,
                expanded: expandedTasks.contains(
                  '$expansionPrefix:${taskEntries[index].key}',
                ),
                onTap: () => onTaskToggle(taskEntries[index].key),
              ),
          ],
        ],
      ),
    );
  }
}

class _WorkflowDisclosureRow extends StatelessWidget {
  const _WorkflowDisclosureRow({
    super.key,
    required this.expanded,
    required this.onTap,
    required this.title,
    required this.trailing,
  });

  final bool expanded;
  final VoidCallback onTap;
  final String title;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return InkWell(
      key: const ValueKey('agent-usage-workflow-disclosure'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              size: 17,
              color: colors.textMuted,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              trailing,
              style: TextStyle(
                color: colors.text,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkflowMainRow extends StatelessWidget {
  const _WorkflowMainRow({required this.node});

  final AgentUsageWorkflowNode node;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(37, 0, 12, 10),
      child: _WorkflowFactRow(
        label: strings.workflowMainConversation,
        role: strings.workflowRoleLabel(node.role),
        agent: _workflowDisplayLabel(node.agentId, strings),
        model: _workflowDisplayLabel(node.model, strings),
        status: strings.workflowStatusLabel(node.state),
        totals: node.usage,
      ),
    );
  }
}

class _WorkflowTaskGroup extends StatelessWidget {
  const _WorkflowTaskGroup({
    required this.taskCode,
    required this.nodes,
    required this.expanded,
    required this.onTap,
  });

  final String taskCode;
  final List<AgentUsageWorkflowNode> nodes;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final total = nodes.fold<int>(
      0,
      (value, node) => value + node.usage.totalTokens,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WorkflowDisclosureRow(
          key: ValueKey('agent-usage-workflow-task-$taskCode'),
          expanded: expanded,
          onTap: onTap,
          title: strings.workflowTaskLabel(taskCode),
          trailing: formatAgentUsageNumber(total),
        ),
        if (expanded)
          for (var index = 0; index < nodes.length; index += 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(61, 0, 12, 9),
              child: _WorkflowFactRow(
                label: strings.workflowDispatchLabel(index + 1),
                role: strings.workflowRoleLabel(nodes[index].role),
                agent: _workflowDisplayLabel(nodes[index].agentId, strings),
                model: _workflowDisplayLabel(nodes[index].model, strings),
                status: strings.workflowStatusLabel(nodes[index].state),
                totals: nodes[index].usage,
              ),
            ),
      ],
    );
  }
}

class _WorkflowFactRow extends StatelessWidget {
  const _WorkflowFactRow({
    required this.label,
    required this.role,
    required this.agent,
    required this.model,
    required this.status,
    required this.totals,
  });

  final String label;
  final String role;
  final String agent;
  final String model;
  final String status;
  final AgentUsageTokenTotals totals;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: colors.line.withAlpha(65), width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  formatAgentUsageNumber(totals.totalTokens),
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 10,
              runSpacing: 3,
              children: [
                _WorkflowFactLabel(value: role),
                _WorkflowFactLabel(value: agent),
                _WorkflowFactLabel(value: model),
                _WorkflowFactLabel(value: status),
                _WorkflowFactLabel(
                  value:
                      '${formatAgentUsageNumber(totals.promptTokens)} / ${formatAgentUsageNumber(totals.cachedInputTokens)} / ${formatAgentUsageNumber(totals.completionTokens)}',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkflowFactLabel extends StatelessWidget {
  const _WorkflowFactLabel({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: context.licoColors.textMuted, fontSize: 10),
    );
  }
}

String _workflowDisplayLabel(String value, LicoStrings strings) {
  final normalized = value.trim();
  if (normalized.isEmpty) return strings.unknown;
  return normalized
      .replaceAll(RegExp(r'[-_]+'), ' ')
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map(
        (part) => '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}',
      )
      .join(' ');
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
