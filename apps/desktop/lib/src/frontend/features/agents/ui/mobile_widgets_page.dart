import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';

class MobileWidgetsPage extends StatefulWidget {
  const MobileWidgetsPage({super.key, required this.binding});

  final MonitoringBinding binding;

  @override
  State<MobileWidgetsPage> createState() => _MobileWidgetsPageState();
}

class _MobileWidgetsPageState extends State<MobileWidgetsPage> {
  @override
  void initState() {
    super.initState();
    _queueUsageRefresh();
  }

  @override
  void didUpdateWidget(covariant MobileWidgetsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) {
      _queueUsageRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<MonitoringProjection, MonitoringProjection>(
      source: widget.binding.projection,
      select: (projection) => projection,
      builder: (context, projection) {
        final colors = context.licoColors;
        final strings = LicoStrings.of(context);
        final report = projection.report;
        final busy = projection.refreshing;
        return RefreshIndicator(
          onRefresh: () async =>
              widget.binding.intents.send(const RefreshMonitoring()),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          strings.widgets,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('mobile-widgets-refresh-usage'),
                        tooltip: strings.refreshUsage,
                        onPressed: busy
                            ? null
                            : () => widget.binding.intents.send(
                                const RefreshMonitoring(),
                              ),
                        icon: busy
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colors.textMuted,
                                ),
                              )
                            : const Icon(Icons.sync_rounded),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                sliver: SliverList.list(
                  children: [
                    _TokenUsageOverviewCard(report: report, busy: busy),
                    const SizedBox(height: 10),
                    _TokenUsageAgentCard(report: report),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _queueUsageRefresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.binding.projection.current.refreshing) {
        return;
      }
      widget.binding.intents.send(const StartAutomaticMonitoring());
    });
  }
}

class _TokenUsageOverviewCard extends StatelessWidget {
  const _TokenUsageOverviewCard({required this.report, required this.busy});

  final AgentUsageReport? report;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final totalTokens = report?.totalTokens ?? 0;
    final agentCount = report?.agentCount ?? 0;
    final generatedAt = _compactGeneratedAt(report?.generatedAt ?? '');
    return _WidgetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.query_stats_rounded,
                color: colors.textSecondary,
                size: 21,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.tokenUsage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (busy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.accent,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            totalTokens > 0 ? _formatNumber(totalTokens) : '0',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.text,
              fontSize: 34,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            totalTokens > 0
                ? strings.totalTokens
                : busy
                ? strings.loading
                : strings.noUsageReportYet,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _MetricPill(
                  label: strings.agent,
                  value: agentCount.toString(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricPill(
                  label: strings.confidence,
                  value: _confidenceLabel(strings, report?.confidence ?? ''),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MetricPill(
                  label: strings.generated,
                  value: generatedAt.isEmpty ? '-' : generatedAt,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TokenUsageAgentCard extends StatelessWidget {
  const _TokenUsageAgentCard({required this.report});

  final AgentUsageReport? report;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final agents = [
      for (final agent in report?.agents ?? const <AgentUsageAgentSummary>[])
        if (agent.totalTokens > 0) agent,
    ]..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    final maxTokens = agents.isEmpty
        ? 1
        : agents
              .map((agent) => agent.totalTokens)
              .reduce(math.max)
              .clamp(1, 1 << 62);
    return _WidgetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.tokenConsumption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          if (agents.isEmpty)
            Text(
              strings.noUsageReportYet,
              style: TextStyle(color: colors.textMuted, fontSize: 13),
            )
          else
            for (final agent in agents.take(5)) ...[
              _AgentUsageRow(
                label: agent.label.trim().isEmpty
                    ? agent.agentId
                    : agent.label.trim(),
                value: agent.totalTokens,
                fraction: agent.totalTokens / maxTokens,
              ),
              if (agent != agents.take(5).last) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _AgentUsageRow extends StatelessWidget {
  const _AgentUsageRow({
    required this.label,
    required this.value,
    required this.fraction,
  });

  final String label;
  final int value;
  final num fraction;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final fill = fraction.clamp(0, 1).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatNumber(value),
              style: TextStyle(color: colors.textMuted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: fill,
            minHeight: 5,
            color: colors.accent,
            backgroundColor: colors.surfaceLow,
          ),
        ),
      ],
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        border: Border.all(color: colors.line.withAlpha(150)),
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
              color: colors.text,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _WidgetCard extends StatelessWidget {
  const _WidgetCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        side: BorderSide(color: colors.line.withAlpha(150)),
      ),
      child: Padding(padding: const EdgeInsets.all(14), child: child),
    );
  }
}

String _formatNumber(int value) {
  final raw = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final indexFromEnd = raw.length - i;
    buffer.write(raw[i]);
    if (indexFromEnd > 1 && indexFromEnd % 3 == 1) {
      buffer.write(',');
    }
  }
  return buffer.toString();
}

String _compactGeneratedAt(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return value.trim();
  }
  final local = parsed.toLocal();
  String two(int item) => item.toString().padLeft(2, '0');
  return '${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

String _confidenceLabel(LicoStrings strings, String value) {
  return switch (value.trim().toLowerCase()) {
    'high' => strings.high,
    'medium' => strings.medium,
    'low' => strings.low,
    _ => '-',
  };
}
