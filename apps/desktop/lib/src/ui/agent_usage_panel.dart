import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/future_client_controller.dart';
import '../services/agent_service.dart';
import '../services/agent_usage_service.dart';
import 'panel_frame.dart';
import 'theme.dart';

class AgentUsagePanel extends StatelessWidget {
  const AgentUsagePanel({
    super.key,
    required this.controller,
    required this.selectedTarget,
  });

  final FutureClientController controller;
  final TargetCandidate selectedTarget;

  @override
  Widget build(BuildContext context) {
    final report = controller.agentUsageReport;
    final selectedUsage = controller.selectedAgentUsage;
    final busy =
        controller.isScanningAgentUsage || controller.isObservingAgentNetwork;
    return PanelFrame(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;
            final header = _UsageHeader(
              busy: busy,
              observing: controller.isObservingAgentNetwork,
              generatedAt: report?.generatedAt ?? '',
              onScan: () => unawaited(controller.scanAgentUsage()),
              onObserve: () =>
                  unawaited(controller.scanAgentUsage(observeNetwork: true)),
            );
            final stats = _UsageStats(
              report: report,
              selectedUsage: selectedUsage,
              selectedLabel: selectedTarget.label,
            );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [header, const SizedBox(height: 10), stats],
              );
            }
            return Row(
              children: [
                Expanded(child: header),
                const SizedBox(width: 14),
                Expanded(flex: 2, child: stats),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _UsageHeader extends StatelessWidget {
  const _UsageHeader({
    required this.busy,
    required this.observing,
    required this.generatedAt,
    required this.onScan,
    required this.onObserve,
  });

  final bool busy;
  final bool observing;
  final String generatedAt;
  final VoidCallback onScan;
  final VoidCallback onObserve;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final subtitle = generatedAt.isEmpty ? 'No usage report yet' : generatedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.query_stats, color: colors.primary, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Agent usage',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: colors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: busy ? null : onScan,
              icon: busy && !observing
                  ? const _SmallSpinner()
                  : const Icon(Icons.search, size: 18),
              label: const Text('Scan usage'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : onObserve,
              icon: busy && observing
                  ? const _SmallSpinner()
                  : const Icon(Icons.network_check, size: 18),
              label: const Text('Observe network'),
            ),
          ],
        ),
      ],
    );
  }
}

class _UsageStats extends StatelessWidget {
  const _UsageStats({
    required this.report,
    required this.selectedUsage,
    required this.selectedLabel,
  });

  final AgentUsageReport? report;
  final AgentUsageAgentSummary? selectedUsage;
  final String selectedLabel;

  @override
  Widget build(BuildContext context) {
    final report = this.report;
    final selectedUsage = this.selectedUsage;
    final items = [
      _StatItem('Agents', report?.agentCount.toString() ?? '-'),
      _StatItem('Total tokens', _number(report?.totalTokens)),
      _StatItem('Metered traffic', _bytes(report?.meteredTotalBytes)),
      _StatItem('Estimated history', _bytes(report?.estimatedHistoricalBytes)),
      _StatItem(
        selectedLabel,
        selectedUsage == null
            ? 'No selected report'
            : '${_number(selectedUsage.totalTokens)} tokens',
      ),
      _StatItem(
        'Attribution',
        selectedUsage?.attribution.isNotEmpty == true
            ? selectedUsage!.attribution
            : report?.attribution ?? '-',
      ),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [for (final item in items) _UsageStatTile(item: item)],
    );
  }
}

class _UsageStatTile extends StatelessWidget {
  const _UsageStatTile({required this.item});

  final _StatItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 3),
            Text(
              item.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.text, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallSpinner extends StatelessWidget {
  const _SmallSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

class _StatItem {
  const _StatItem(this.label, this.value);

  final String label;
  final String value;
}

String _number(int? value) {
  if (value == null) {
    return '-';
  }
  return value.toString();
}

String _bytes(int? value) {
  final bytes = value ?? 0;
  if (bytes <= 0) {
    return '-';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
