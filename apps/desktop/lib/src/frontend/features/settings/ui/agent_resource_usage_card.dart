import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/settings/controller/agent_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/contracts/agent_resource_usage_gateway.dart';
import 'package:licoup/src/frontend/features/settings/ui/resource_usage_shared.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class AgentResourceUsageCard extends StatefulWidget {
  const AgentResourceUsageCard({
    super.key,
    required this.gateway,
    this.controller,
  });

  final AgentResourceUsageGateway gateway;

  /// Injectable for tests; when null the card owns its controller.
  final AgentResourceUsageController? controller;

  @override
  State<AgentResourceUsageCard> createState() => _AgentResourceUsageCardState();
}

class _AgentResourceUsageCardState extends State<AgentResourceUsageCard> {
  AgentResourceUsageController? _ownedController;

  AgentResourceUsageController get _controller =>
      widget.controller ??
      (_ownedController ??= AgentResourceUsageController(
        gateway: widget.gateway,
      ));

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final controller = _controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final latest = controller.latestByAgent;
        final targets = latest.keys.toList()..sort();
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            LicoContentSpacing.item,
            LicoContentSpacing.compact,
            LicoContentSpacing.item,
            LicoContentSpacing.item,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.memory_outlined,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: LicoContentSpacing.compact),
                  Expanded(
                    child: Text(
                      strings.agentResources,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                    ),
                  ),
                  if (controller.lastError != null)
                    Icon(Icons.error_outline, size: 14, color: colors.error),
                ],
              ),
              const SizedBox(height: LicoContentSpacing.compact),
              Text(
                targets.isEmpty
                    ? strings.agentResourcesIdle
                    : strings.agentResourcesHint(latest.length),
                style: TextStyle(fontSize: 11.5, color: colors.textMuted),
              ),
              const SizedBox(height: LicoContentSpacing.compact),
              if (targets.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: LicoContentSpacing.compact,
                  ),
                  child: Text(
                    strings.agentResourcesIdleDetail,
                    style: TextStyle(fontSize: 12, color: colors.textMuted),
                  ),
                )
              else
                for (final target in targets) ...[
                  _AgentRow(
                    target: target,
                    sample: latest[target]!,
                    history: controller.samplesFor(target),
                    colors: colors,
                  ),
                  const SizedBox(height: LicoContentSpacing.compact),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({
    required this.target,
    required this.sample,
    required this.history,
    required this.colors,
  });

  final String target;
  final AgentResourceUsageSample sample;
  final List<AgentResourceUsageSample> history;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final label = _displayLabel(target);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 108,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: colors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: LicoContentSpacing.compact),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.text,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: LicoContentSpacing.inline),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      formatRssBytes(sample.rssBytes),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: colors.text,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: LicoContentSpacing.inline),
                  Text(
                    'MB',
                    style: TextStyle(fontSize: 10, color: colors.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: LicoContentSpacing.compact),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _RateChip(
                    icon: Icons.download_outlined,
                    label: formatRateKbPerSec(
                      _rateKbPerSec(sample, read: true),
                    ),
                    colors: colors,
                  ),
                  const SizedBox(width: LicoContentSpacing.compact),
                  _RateChip(
                    icon: Icons.upload_outlined,
                    label: formatRateKbPerSec(
                      _rateKbPerSec(sample, read: false),
                    ),
                    colors: colors,
                  ),
                ],
              ),
              const SizedBox(height: LicoContentSpacing.compact),
              SizedBox(
                height: 30,
                child: CustomPaint(
                  painter: ResourceUsageSparklinePainter(
                    values: [
                      for (final entry in history) entry.rssBytes.toDouble(),
                    ],
                    color: colors.accent,
                    colors: colors,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  double _rateKbPerSec(AgentResourceUsageSample sample, {required bool read}) {
    final intervalMs = sample.interval.inMilliseconds;
    if (intervalMs <= 0) {
      return 0;
    }
    final deltaBytes = read ? sample.deltaReadBytes : sample.deltaWriteBytes;
    return deltaBytes * 1000 / intervalMs / 1024;
  }
}

class _RateChip extends StatelessWidget {
  const _RateChip({
    required this.icon,
    required this.label,
    required this.colors,
  });

  final IconData icon;
  final String label;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: colors.textMuted),
        const SizedBox(width: LicoContentSpacing.inline),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: colors.text,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: LicoContentSpacing.inline / 2),
        Text('KB/s', style: TextStyle(fontSize: 9.5, color: colors.textMuted)),
      ],
    );
  }
}

String _displayLabel(String target) {
  return switch (target) {
    'claude-code' => 'Claude Code',
    'kimi-code' => 'Kimi Code',
    'kilo-code' => 'Kilo Code',
    _ => target,
  };
}
